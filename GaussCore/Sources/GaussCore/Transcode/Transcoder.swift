import AVFoundation
import VideoToolbox

public enum TranscodeError: Error, LocalizedError {
    case noVideoTrack
    case encoderUnavailable(OSStatus)
    /// The hardware encoder exists but is in use (camera, call, another app).
    case encoderBusy(OSStatus)
    case encoderProperty(String, OSStatus)
    case encodeFailed(OSStatus)
    case unsupportedRateControl(String)
    case writer(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This file has no video track."
        case .encoderUnavailable(let s): "The video encoder couldn't be started (\(s))."
        case .encoderBusy(let s): "The video encoder is busy (\(s))."
        case .encoderProperty(let key, let s): "The video encoder rejected \(key) (\(s))."
        case .encodeFailed(let s): "Encoding failed (\(s))."
        case .unsupportedRateControl(let mode): "\(mode) needs a newer iOS version."
        case .writer(let message): message
        }
    }
}

public struct TranscodeResult: Sendable {
    public var output: URL
    public var plan: TranscodePlan
    /// The rate control actually used (VBR falls back to ABR on older OSes).
    public var rateControl: RateControl
    /// Whether VideoToolbox picked a hardware encoder (nil if it couldn't be determined).
    public var usedHardwareEncoder: Bool?
    public var framesRead: Int
    public var framesEncoded: Int
    public var seconds: Double
    /// Encodes it took: 2 when a size-targeted first pass came out over.
    public var attempts: Int
    public var fileSize: Int64
    /// Size of the first attempt, when a second pass was needed to fit.
    public var firstAttemptSize: Int64?
}

/// Re-encodes a video with the hardware encoder:
///
///     AVAssetReader ─▶ GPU composition ─▶ frame-rate cap ─▶ VTCompressionSession ─▶ AVAssetWriter
///     (HW decode)     (rotate upright,                      (HW H.264/HEVC)        (MP4/MOV)
///                      scale, HDR/SDR)
///     AVAssetReader ─▶ LPCM ─▶ AAC (or AAC passthrough) ───────────────────────────▶
///
/// Rotation is baked into the pixels, so the output needs no display matrix.
public enum Transcoder {
    public static func transcode(
        source: URL,
        range: CMTimeRange? = nil,
        settings: TranscodeSettings,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        /// Called with the first attempt's size when a size-targeted export
        /// came out over its limit and is encoded a second time.
        secondPass: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> TranscodeResult {
        let info = try await MediaProbe.probe(source)
        let duration = range?.duration.seconds ?? info.duration
        var plan = TranscodePlan(source: info, settings: settings, duration: duration, device: Capabilities.probe())
        let began = Date()
        var firstAttemptSize: Int64?

        for attempt in 1... {
            let job = try await TranscodeJob(source: source, info: info, range: range, plan: plan, output: output)
            try await withTaskCancellationHandler {
                try await job.run(progress: progress)
            } onCancel: {
                job.cancel()
            }
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

            // Size-targeted: if the first pass overshot, take the excess out of
            // the video bitrate (plus a 3% margin) and encode once more.
            if let target = settings.targetFileSize, size > target, attempt == 1,
               case .averageBitRate(let bps) = plan.rateControl {
                let excess = Double(size) - Double(target) * 0.97
                plan.rateControl = .averageBitRate(max(Int(Double(bps) - excess * 8 / max(duration, 0.1)), 50_000))
                firstAttemptSize = size
                secondPass(size)
                continue
            }
            return TranscodeResult(output: output, plan: plan, rateControl: job.appliedRateControl,
                                   usedHardwareEncoder: job.usedHardwareEncoder,
                                   framesRead: job.framesRead, framesEncoded: job.framesEncoded,
                                   seconds: Date().timeIntervalSince(began), attempts: attempt, fileSize: size,
                                   firstAttemptSize: firstAttemptSize)
        }
        fatalError("unreachable")
    }
}

// MARK: - Job

/// One transcode. State is touched from the video and audio queues and the
/// encoder's callback thread; `lock` guards everything mutable.
final class TranscodeJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderTrackOutput?
    private let audioInput: AVAssetWriterInput?
    private let session: VTCompressionSession
    private let range: CMTimeRange
    private let minFrameInterval: Double

    private let lock = NSLock()
    private var encoded: [CMSampleBuffer] = []
    private var encodeError: OSStatus?
    private var lastKeptTime: Double?
    private var cancelled = false
    private var readerStarted = false
    // Touched only on `videoQueue`.
    private var sourceDone = false
    private var flushed = false
    private var lastReported = -1.0
    private(set) var framesRead = 0
    private(set) var framesEncoded = 0
    private(set) var appliedRateControl: RateControl
    let usedHardwareEncoder: Bool?

    private let videoQueue = DispatchQueue(label: "gauss.transcode.video")
    private let audioQueue = DispatchQueue(label: "gauss.transcode.audio")

    init(source: URL, info: MediaInfo, range requested: CMTimeRange?, plan: TranscodePlan, output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        range = requested ?? CMTimeRange(start: .zero, duration: duration)
        // Keep frames at least 70% of the target interval apart: drops every
        // other frame for 60→30 but tolerates iPhone timestamp jitter.
        minFrameInterval = 0.7 / Double(plan.settings.frameRateCap)

        reader = try AVAssetReader(asset: asset)
        reader.timeRange = range

        // Video: decode + rotate + scale + colour conversion in one GPU pass.
        let composition = try await Self.composition(for: videoTrack, duration: duration, plan: plan)
        let pixelFormat = plan.is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        // Encoder.
        let (session, applied) = try Self.makeEncoder(plan: plan)
        self.session = session
        appliedRateControl = applied
        usedHardwareEncoder = Self.isUsingHardware(session)

        // Writer.
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: plan.settings.container == .mov ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = plan.settings.metadata.apply(to: Self.captureMetadata(try await asset.load(.metadata)))

        var hint: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: plan.settings.codec.codecType,
                                       width: Int32(plan.outputSize.width), height: Int32(plan.outputSize.height),
                                       extensions: nil, formatDescriptionOut: &hint)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // Audio: the main stereo track (iPhone's AAC rather than APAC spatial).
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if plan.settings.audio != .none,
           let index = plan.settings.audioTrack.singleTrack(in: info.audio), index < audioTracks.count {
            let track = audioTracks[index], audio = info.audio[index]
            let bitRate: Int
            let passthrough: Bool
            switch plan.settings.audio {
            case .aac(let target):
                bitRate = target
                passthrough = AudioPlan.keepsOriginal(audio, target: target)
            default:
                // Keep: AAC copies into MP4 and MOV as-is; anything else becomes AAC.
                bitRate = 160_000
                passthrough = audio.codecFourCC == "aac "
            }
            let readerSettings: [String: Any]? = passthrough ? nil : [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: min(2, max(1, audio.channels)),
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let formatHint = passthrough ? try await track.load(.formatDescriptions).first : nil
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: passthrough ? nil : [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: min(2, max(1, audio.channels)),
                AVSampleRateKey: audio.sampleRate > 0 ? min(audio.sampleRate, 48_000) : 48_000,
                AVEncoderBitRateKey: bitRate,
            ], sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioOutput = output
            audioInput = input
        } else {
            audioOutput = nil
            audioInput = nil
        }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Running

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Start reading under the lock so `cancel()` either sees a running
        // reader (and stops it) or marks us cancelled before we start.
        let started: Bool = lock.withLock {
            guard !cancelled else { return false }
            readerStarted = reader.startReading()
            return true
        }
        guard started else { throw CancellationError() }
        guard readerStarted else { throw reader.error ?? TranscodeError.writer("Couldn't read the video.") }
        guard writer.startWriting() else { throw writer.error ?? TranscodeError.writer("Couldn't write the video.") }
        writer.startSession(atSourceTime: range.start)

        async let video: Void = pumpVideo(progress: progress)
        async let audio: Void = pumpAudio()
        _ = await (video, audio)

        if isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if let status = lock.withLock({ encodeError }) {
            writer.cancelWriting()
            throw TranscodeError.encodeFailed(status)
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

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Pulls frames, encodes them, and appends encoded samples as the writer
    /// accepts them. Never returns while the input is ready and work remains,
    /// so `requestMediaDataWhenReady` always gets called back.
    private func pumpVideo(progress: @escaping @Sendable (Double) -> Void) async {
        let total = range.duration.seconds
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                while videoInput.isReadyForMoreMediaData {
                    if isCancelled || lock.withLock({ encodeError }) != nil {
                        videoInput.markAsFinished()
                        finished.resume()
                        return
                    }
                    if let sample = lock.withLock({ encoded.isEmpty ? nil : encoded.removeFirst() }) {
                        videoInput.append(sample)
                        continue
                    }
                    if sourceDone {
                        if flushed {
                            videoInput.markAsFinished()
                            finished.resume()
                            return
                        }
                        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                        flushed = true
                        continue
                    }
                    guard let frame = videoOutput.copyNextSampleBuffer() else {
                        sourceDone = true
                        continue
                    }
                    let time = frame.presentationTimeStamp
                    guard keep(time.seconds), let image = frame.imageBuffer else { continue }
                    encode(image, at: time)
                    let fraction = total > 0 ? (time - range.start).seconds / total : 0
                    if fraction.isFinite, fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(min(max(fraction, 0), 0.99))
                    }
                }
            }
        }
    }

    private func pumpAudio() async {
        guard audioInput != nil else { return }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            audioInput?.requestMediaDataWhenReady(on: audioQueue) { [self] in
                guard let audioInput, let audioOutput else { return }
                while audioInput.isReadyForMoreMediaData {
                    guard !isCancelled, let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        finished.resume()
                        return
                    }
                    audioInput.append(sample)
                }
            }
        }
    }

    /// Frame-rate cap by timestamp, so iPhone VFR timing is preserved.
    private func keep(_ time: Double) -> Bool {
        lock.withLock {
            framesRead += 1
            if let last = lastKeptTime, time - last < minFrameInterval { return false }
            lastKeptTime = time
            return true
        }
    }

    private func encode(_ image: CVImageBuffer, at time: CMTime) {
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [self] status, _, sample in
            lock.withLock {
                if status != noErr { encodeError = status; return }
                if let sample {
                    encoded.append(sample)
                    framesEncoded += 1
                }
            }
        }
        if status != noErr { lock.withLock { encodeError = status } }
    }

    // MARK: Setup helpers

    private static func composition(for track: AVAssetTrack, duration: CMTime,
                                    plan: TranscodePlan) async throws -> AVVideoComposition {
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let trackID = track.trackID
        let displayed = CGRect(origin: .zero, size: natural).applying(transform)
        let scale = plan.outputSize.width / abs(displayed.width)

        // Rotate upright (the track transform), then scale to the output size.
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = plan.outputSize
        composition.frameDuration = CMTime(value: 1, timescale: 240)
        composition.sourceTrackIDForFrameTiming = trackID   // keep the camera's real timestamps
        switch plan.hdr {
        case .hlg, .dolbyVision:
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        case .hdr10:
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            composition.colorTransferFunction = AVVideoTransferFunction_SMPTE_ST_2084_PQ
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        case .sdr:
            // HDR sources are tone-mapped to SDR by the compositor.
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        return composition
    }

    private static func makeEncoder(plan: TranscodePlan) throws -> (VTCompressionSession, RateControl) {
        var specification: CFDictionary?
        if #available(iOS 17.4, macOS 10.15, *) {
            specification = plan.settings.forceSoftwareEncoder
                ? [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false] as CFDictionary
                : [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        }

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(plan.outputSize.width), height: Int32(plan.outputSize.height),
            codecType: plan.settings.codec.codecType, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
        guard status == noErr, let session = sessionOut else {
            // Hardware exists on every supported iPhone, so "not found / not
            // available now" with hardware required means it's in use.
            if status == kVTCouldNotFindVideoEncoderErr || status == kVTVideoEncoderNotAvailableNowErr {
                throw TranscodeError.encoderBusy(status)
            }
            throw TranscodeError.encoderUnavailable(status)
        }

        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr { throw TranscodeError.encoderProperty(key as String, status) }
        }
        /// For hints and tags some encoders (e.g. Apple's software encoder) don't support.
        func setIfSupported(_ key: CFString, _ value: CFTypeRef) {
            _ = VTSessionSetProperty(session, key: key, value: value)
        }

        let profile: CFString = switch (plan.settings.codec, plan.is10Bit) {
        case (.h264, _): kVTProfileLevel_H264_High_AutoLevel
        case (.hevc, false): kVTProfileLevel_HEVC_Main_AutoLevel
        case (.hevc, true): kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        setIfSupported(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, profile)
        setIfSupported(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
        setIfSupported(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        setIfSupported(kVTCompressionPropertyKey_ExpectedFrameRate, plan.frameRate as CFNumber)

        let (primaries, transfer, matrix): (CFString, CFString, CFString) = switch plan.hdr {
        case .sdr: (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        case .hdr10: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                      kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case .hlg, .dolbyVision: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                  kCVImageBufferYCbCrMatrix_ITU_R_2020)
        }
        setIfSupported(kVTCompressionPropertyKey_ColorPrimaries, primaries)
        setIfSupported(kVTCompressionPropertyKey_TransferFunction, transfer)
        setIfSupported(kVTCompressionPropertyKey_YCbCrMatrix, matrix)

        let applied = try applyRateControl(plan.rateControl, set: set)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return (session, applied)
    }

    /// Which encoder the session picked, looked up in the system encoder list
    /// (works on every supported iOS; the software encoder can't answer
    /// `UsingHardwareAcceleratedVideoEncoder` itself).
    private static func isUsingHardware(_ session: VTCompressionSession) -> Bool? {
        // Copied properties come back retained ("Copy" rule), hence Unmanaged.
        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
                                           allocator: nil, valueOut: &value)
        guard status == noErr, let encoderID = value?.takeRetainedValue() as? String else { return nil }
        return Capabilities.isHardwareEncoder(encoderID)
    }

    private static func applyRateControl(_ mode: RateControl, set: (CFString, CFTypeRef) throws -> Void) throws -> RateControl {
        func average(_ bps: Int) throws -> RateControl {
            try set(kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
            // Hard cap: twice the average over any one-second window (bytes, seconds).
            // Best-effort: Apple's software encoder doesn't support it.
            do {
                try set(kVTCompressionPropertyKey_DataRateLimits, [bps * 2 / 8, 1] as CFArray)
            } catch TranscodeError.encoderProperty(_, kVTPropertyNotSupportedErr) {}
            return .averageBitRate(bps)
        }
        switch mode {
        case .averageBitRate(let bps):
            return try average(bps)
        case .variableBitRate(let bps):
            if #available(iOS 26, macOS 26, *) {
                // Not every encoder implements VBR (Apple's software one doesn't); fall back to ABR.
                do {
                    try set(kVTCompressionPropertyKey_VariableBitRate, bps as CFNumber)
                    try set(kVTCompressionPropertyKey_VBVMaxBitRate, bps * 2 as CFNumber)
                    return mode
                } catch TranscodeError.encoderProperty(_, kVTPropertyNotSupportedErr) {
                    return try average(bps)
                }
            }
            return try average(bps)
        case .constantQuality(let q):
            if #available(iOS 27, macOS 27, *) {
                try set(kVTCompressionPropertyKey_ConstantQualityFactor, q as CFNumber)
                return mode
            }
            throw TranscodeError.unsupportedRateControl("Constant quality")
        case .fixedQuality(let q):
            try set(kVTCompressionPropertyKey_Quality, q as CFNumber)
            return mode
        }
    }

    /// Creation date, location and device survive a transcode. AVAssetWriter
    /// maps these to MP4's own date/location boxes; make/model are MOV-only.
    private static func captureMetadata(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        let keep: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataCreationDate, .quickTimeMetadataLocationISO6709,
            .quickTimeMetadataMake, .quickTimeMetadataModel, .quickTimeMetadataSoftware,
        ]
        return items.filter { $0.identifier.map(keep.contains) ?? false }
    }
}
