import AVFoundation

/// Backs the Copy preset when an audio bitrate (rather than Keep) is chosen:
/// copies the video track sample-for-sample (full sharpness, HDR, rotation
/// flag) and re-encodes only the main audio track to stereo AAC. Ideal for
/// lectures and screen recordings, where the audio is often most of the file.
public enum AudioReencoder {
    public static func export(
        source: URL,
        range: CMTimeRange,
        mode: CopyCutMode,
        audioBitRate: Int,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        var trimmed = range
        if mode == .keyframe {
            let start = try await KeyframeLocator.keyframe(atOrBefore: range.start, in: source)
            trimmed = CMTimeRange(start: start, end: range.end)
        }
        let job = try await AudioReencodeJob(source: source, range: trimmed, audioBitRate: audioBitRate,
                                             fileType: CopyExporter.fileType(for: source), output: output)
        try await withTaskCancellationHandler {
            try await job.run(progress: progress)
        } onCancel: {
            job.cancel()
        }
    }
}

final class AudioReencodeJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderTrackOutput?
    private let audioInput: AVAssetWriterInput?
    private let range: CMTimeRange

    private let lock = NSLock()
    private var cancelled = false
    private var readerStarted = false

    init(source: URL, range: CMTimeRange, audioBitRate: Int, fileType: AVFileType, output: URL) async throws {
        self.range = range
        let asset = AVURLAsset(url: source)
        let info = try await MediaProbe.probe(source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }

        reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = try await asset.load(.metadata).filter {
            [.quickTimeMetadataCreationDate, .quickTimeMetadataLocationISO6709, .quickTimeMetadataMake,
             .quickTimeMetadataModel, .quickTimeMetadataSoftware].contains($0.identifier)
        }

        // Video: compressed samples straight through, rotation flag kept.
        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        let (formats, transform) = try await videoTrack.load(.formatDescriptions, .preferredTransform)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // Audio: the main stereo track (AAC rather than APAC) → stereo AAC.
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let pairs = Array(zip(tracks, info.audio))
        if let (track, audio) = pairs.first(where: { $0.1.codecFourCC == "aac " })
            ?? pairs.first(where: { $0.1.codecFourCC != "apac" }) ?? pairs.first {
            let channels = min(2, max(1, audio.channels))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channels,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: audio.sampleRate > 0 ? min(audio.sampleRate, 48_000) : 48_000,
                AVEncoderBitRateKey: audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioOutput = output
            audioInput = input
        } else {
            audioOutput = nil
            audioInput = nil
        }
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        let started: Bool = lock.withLock {
            guard !cancelled else { return false }
            readerStarted = reader.startReading()
            return true
        }
        guard started else { throw CancellationError() }
        guard readerStarted else { throw reader.error ?? TranscodeError.writer("Couldn't read the video.") }
        guard writer.startWriting() else { throw writer.error ?? TranscodeError.writer("Couldn't write the video.") }
        writer.startSession(atSourceTime: range.start)

        let total = range.duration.seconds
        async let video: Void = pump(videoInput, videoOutput, queue: "video") { [range] time in
            if total > 0 { progress(min(max((time - range.start).seconds / total, 0), 0.99)) }
        }
        async let audio: Void = pump(audioInput, audioOutput, queue: "audio", onSample: nil)
        _ = await (video, audio)

        if lock.withLock({ cancelled }) {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? TranscodeError.writer("Reading the video failed.")
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? TranscodeError.writer("Writing the video failed.")
        }
        progress(1)
    }

    func cancel() {
        let running = lock.withLock {
            cancelled = true
            return readerStarted
        }
        if running { reader.cancelReading() }
    }

    private func pump(_ input: AVAssetWriterInput?, _ output: AVAssetReaderTrackOutput?, queue label: String,
                      onSample: (@Sendable (CMTime) -> Void)?) async {
        guard let input, let output else { return }
        nonisolated(unsafe) let writerInput = input, readerOutput = output
        let queue = DispatchQueue(label: "footbrake.reencode.\(label)")
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) { [self] in
                while writerInput.isReadyForMoreMediaData {
                    guard !lock.withLock({ cancelled }), let sample = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        finished.resume()
                        return
                    }
                    onSample?(sample.presentationTimeStamp)
                    writerInput.append(sample)
                }
            }
        }
    }
}
