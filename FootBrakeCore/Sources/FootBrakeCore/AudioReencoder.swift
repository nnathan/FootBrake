import AVFoundation

/// FootBrake's own lossless remux, behind the Copy preset when Apple's export
/// session won't do:
/// - an audio bitrate is chosen: the video is copied sample-for-sample (full
///   sharpness, HDR, rotation flag) and only the main audio track is
///   re-encoded to stereo AAC. Ideal for lectures and screen recordings.
/// - metadata is being removed (`audioBitRate` nil): video and every audio
///   track are copied, while lens details and timed camera tracks are left out.
public enum AudioReencoder {
    public static func export(
        source: URL,
        range: CMTimeRange,
        mode: CopyCutMode,
        audioBitRate: Int?,
        metadata edits: MetadataEdits = .none,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        var trimmed = range
        if mode == .keyframe {
            let start = try await KeyframeLocator.keyframe(atOrBefore: range.start, in: source)
            trimmed = CMTimeRange(start: start, end: range.end)
        }
        let job = try await AudioReencodeJob(source: source, range: trimmed, audioBitRate: audioBitRate,
                                             edits: edits, fileType: CopyExporter.fileType(for: source),
                                             output: output)
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
    private let audio: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)]
    private let range: CMTimeRange

    private let lock = NSLock()
    private var cancelled = false
    private var readerStarted = false

    init(source: URL, range: CMTimeRange, audioBitRate: Int?, edits: MetadataEdits,
         fileType: AVFileType, output: URL) async throws {
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
        writer.metadata = edits.apply(to: try await asset.load(.metadata))

        // Video: compressed samples straight through, rotation flag kept.
        videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        let (formats, transform) = try await videoTrack.load(.formatDescriptions, .preferredTransform)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let pairs = Array(zip(tracks, info.audio))
        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        if let audioBitRate {
            // The main stereo track (AAC rather than APAC) → stereo AAC.
            if let (track, info) = pairs.first(where: { $0.1.codecFourCC == "aac " })
                ?? pairs.first(where: { $0.1.codecFourCC != "apac" }) ?? pairs.first {
                let channels = min(2, max(1, info.channels))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVNumberOfChannelsKey: channels,
                ])
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: channels,
                    AVSampleRateKey: info.sampleRate > 0 ? min(info.sampleRate, 48_000) : 48_000,
                    AVEncoderBitRateKey: audioBitRate,
                ])
                audio.append((output, input))
            }
        } else {
            // Every audio track (including spatial audio) copied as-is.
            for track in tracks {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                let hint = try await track.load(.formatDescriptions).first
                audio.append((output, AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)))
            }
        }
        for (output, input) in audio {
            output.alwaysCopiesSampleData = false
            reader.add(output)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        self.audio = audio
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
        async let audio: Void = withTaskGroup(of: Void.self) { group in
            for (index, pair) in self.audio.enumerated() {
                nonisolated(unsafe) let pair = pair
                group.addTask { await self.pump(pair.input, pair.output, queue: "audio\(index)", onSample: nil) }
            }
        }
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
