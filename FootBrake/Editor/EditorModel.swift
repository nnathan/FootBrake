import AVFoundation
import Combine
import FootBrakeCore
import UIKit

/// Playback and trim state for one source video.
@MainActor
final class EditorModel: ObservableObject {
    static let minimumSelection = 0.1

    let source: SourceVideo
    let player: AVPlayer
    let duration: Double

    @Published private(set) var start: Double = 0
    @Published private(set) var end: Double
    @Published private(set) var playhead: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [UIImage] = []
    @Published var cutMode: CopyCutMode = .keyframe {
        didSet { updateKeyframeStart() }
    }
    /// Where a keyframe-mode copy will actually start (at or before `start`).
    @Published private(set) var keyframeStart: Double?

    private var timeObserver: Any?
    private var statusObservation: AnyCancellable?
    private var isSeeking = false
    private var pendingSeek: Double?
    private var keyframeTask: Task<Void, Never>?

    init(source: SourceVideo) {
        self.source = source
        duration = source.info.duration
        end = source.info.duration
        player = AVPlayer(url: source.url)
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time.seconds) }
        }
        statusObservation = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = status != .paused }
        updateKeyframeStart()
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        keyframeTask?.cancel()
    }

    // MARK: - Selection

    var selectionDuration: Double { end - start }

    var effectiveStart: Double {
        cutMode == .keyframe ? (keyframeStart ?? start) : start
    }

    var selectionRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90_000),
                    end: CMTime(seconds: end, preferredTimescale: 90_000))
    }

    var isWholeFile: Bool { start <= 0.001 && end >= duration - 0.001 }

    /// Encoder support on this device, probed once. In debug builds the
    /// About screen can pretend there are only software encoders, and
    /// `-FBDemo` that they are all hardware.
    let capabilities: [EncoderCapability] = {
        let probed = Capabilities.probe()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: DebugSettings.simulateSoftwareEncoders) || DebugSettings.isDemo {
            return probed.map {
                EncoderCapability(codec: $0.codec, encoderID: $0.encoderID, isAvailable: $0.isAvailable,
                                  isHardwareAccelerated: DebugSettings.isDemo, supports10Bit: $0.supports10Bit,
                                  supportsConstantQuality: $0.supportsConstantQuality,
                                  supportsSpeedPriority: $0.supportsSpeedPriority)
            }
        }
        #endif
        return probed
    }()

    func isHardware(_ codec: VideoCodec) -> Bool {
        capabilities.first { $0.codec == codec }?.isHardwareAccelerated ?? false
    }

    func plan(for settings: TranscodeSettings) -> TranscodePlan {
        TranscodePlan(source: source.info, settings: settings, duration: selectionDuration, device: capabilities)
    }

    /// Bitrate budget × selection length. Encoders land near, not exactly on, the target.
    func estimatedSize(for plan: TranscodePlan) -> Int64 {
        let videoBps: Int = switch plan.rateControl {
        case .averageBitRate(let bps), .variableBitRate(let bps): bps
        case .constantQuality, .fixedQuality: Int(source.info.video?.bitRate ?? 0)
        }
        let audioBps = TranscodePlan.audioBitRate(plan.settings.audio, track: plan.settings.audioTrack,
                                                  source: source.info)
        return Int64(Double(videoBps + audioBps) * selectionDuration / 8)
    }

    /// Video copied as-is plus re-encoded audio at `audioBitRate`.
    func estimatedShrinkAudioSize(audioBitRate: Int) -> Int64 {
        let seconds = end - effectiveStart
        let video = source.info.video?.bitRate ?? 0
        return Int64((video + Double(audioBitRate)) * seconds / 8)
    }

    /// A lossless copy that keeps only some audio: the video plus the kept
    /// tracks' bitrates (`keptAudioBitRate`), over the selection.
    func estimatedRemuxSize(keptAudioBitRate: Double) -> Int64 {
        let seconds = end - effectiveStart
        return Int64(((source.info.video?.bitRate ?? 0) + keptAudioBitRate) * seconds / 8)
    }

    /// Copy size scales with duration, since every sample is kept as-is.
    var estimatedCopySize: Int64 {
        guard duration > 0 else { return 0 }
        return Int64(Double(source.info.fileSize) * (end - effectiveStart) / duration)
    }

    @discardableResult
    func setStart(_ time: Double) -> Double {
        start = min(max(0, time), end - Self.minimumSelection)
        scrub(to: start)
        updateKeyframeStart()
        return start
    }

    @discardableResult
    func setEnd(_ time: Double) -> Double {
        end = max(min(duration, time), start + Self.minimumSelection)
        scrub(to: end)
        return end
    }

    func setStartToPlayhead() { setStart(playhead) }
    func setEndToPlayhead() { setEnd(playhead) }

    /// One frame at the source's average rate (camera footage is slightly VFR,
    /// so this lands within a fraction of a frame of the true neighbour).
    var frameDuration: Double {
        let fps = source.info.video?.nominalFrameRate ?? 0
        return fps > 0 ? 1 / fps : 1.0 / 30
    }

    func nudgeStart(frames: Int) { setStart(start + Double(frames) * frameDuration) }
    func nudgeEnd(frames: Int) { setEnd(end + Double(frames) * frameDuration) }

    private func updateKeyframeStart() {
        keyframeTask?.cancel()
        guard cutMode == .keyframe else { return }
        let url = source.url, time = CMTime(seconds: start, preferredTimescale: 90_000)
        keyframeTask = Task {
            let keyframe = try? await KeyframeLocator.keyframe(atOrBefore: time, in: url)
            guard !Task.isCancelled else { return }
            keyframeStart = keyframe?.seconds
        }
    }

    // MARK: - Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
            return
        }
        if playhead < start || playhead >= end - 0.05 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 90_000),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            playhead = start
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player.play()
    }

    func step(frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    /// Seeks precisely, coalescing requests so dragging stays responsive.
    func scrub(to time: Double) {
        player.pause()
        playhead = min(max(0, time), duration)
        pendingSeek = playhead
        if !isSeeking { performPendingSeek() }
    }

    private func performPendingSeek() {
        guard let time = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: CMTime(seconds: time, preferredTimescale: 90_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.performPendingSeek()
            }
        }
    }

    private func playerTimeChanged(_ time: Double) {
        guard !isSeeking, pendingSeek == nil else { return }
        playhead = time
        if isPlaying && time >= end {
            player.pause()
        }
    }

    // MARK: - Filmstrip

    func loadThumbnails(count: Int) async {
        guard thumbnails.isEmpty, duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var images: [UIImage] = []
        for i in 0..<count {
            let time = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            images.append(UIImage(cgImage: image))
        }
        thumbnails = images
    }
}
