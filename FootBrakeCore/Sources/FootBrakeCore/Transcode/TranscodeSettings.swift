import CoreGraphics
import Foundation

/// How the video encoder decides how many bits to spend.
/// See PLAN.md §3c for why these modes and in this order.
public enum RateControl: Sendable, Equatable, Codable {
    /// Soft average target plus a hard peak cap (2× over 1 s). Works everywhere;
    /// FootBrake's default.
    case averageBitRate(Int)
    /// True VBR with a VBV peak (2×). iOS/macOS 26+; falls back to average.
    /// The iPhone's HEVC encoder ignores its target, so it's for measurement only.
    case variableBitRate(Int)
    /// CRF-like constant quality factor, 0–1. iOS/macOS 27+.
    case constantQuality(Double)
    /// Fixed quantiser via `kVTCompressionPropertyKey_Quality`, 0–1. For measurement only.
    case fixedQuality(Double)

    public var label: String {
        switch self {
        case .averageBitRate(let bps): "ABR \(Format.bitRate(Double(bps)))"
        case .variableBitRate(let bps): "VBR \(Format.bitRate(Double(bps)))"
        case .constantQuality(let q): String(format: "CQ %.2f", q)
        case .fixedQuality(let q): String(format: "QP-quality %.2f", q)
        }
    }
}

public enum AudioPlan: Sendable, Equatable, Codable {
    /// Copy the main audio track as-is; falls back to 160 kbps AAC if the
    /// container can't hold it unchanged.
    case keep
    /// Re-encode the main audio track to stereo AAC at this bitrate, or copy it
    /// if it's already stereo AAC at or below that bitrate.
    case aac(bitRate: Int)
    case none

    /// The picker value: 0 means keep, otherwise kbps.
    public init(kbps: Int) {
        self = kbps > 0 ? .aac(bitRate: kbps * 1000) : .keep
    }
}

public enum OutputContainer: String, Sendable, Codable {
    case mp4, mov
}

/// What the user asked for. `TranscodePlan` turns it into concrete numbers
/// for a particular source.
public struct TranscodeSettings: Sendable, Equatable, Codable {
    public var codec: VideoCodec
    /// Short side of the output in pixels; nil keeps the source size. Never upscales.
    public var maxShortSide: Int?
    /// Frame-rate cap (30 or 60). Never raises the source rate.
    public var frameRateCap: Int
    /// nil chooses a bitrate from resolution and frame rate (see `TranscodePlan`).
    public var rateControl: RateControl?
    /// Keep HDR (10-bit HLG/PQ) when the codec and device allow it; otherwise tone-map to SDR.
    public var keepHDR: Bool
    public var audio: AudioPlan
    public var container: OutputContainer
    /// Remove location / device info, or change the recording date.
    public var metadata: MetadataEdits = .none
    /// Which audio track to encode, or none.
    public var audioTrack: AudioTrackChoice = .automatic
    /// Fit the output under this many bytes (decimal MB presets). Overrides
    /// `maxShortSide` and `rateControl`: both are derived from the budget.
    public var targetFileSize: Int64?
    /// Testing only: false forces Apple's software encoder (iOS 17.4+/macOS),
    /// to exercise the slow path on hardware that would never use it.
    public var forceSoftwareEncoder = false

    public init(codec: VideoCodec = .hevc, maxShortSide: Int? = nil, frameRateCap: Int = 30,
                rateControl: RateControl? = nil, keepHDR: Bool = true,
                audio: AudioPlan = .aac(bitRate: 160_000), container: OutputContainer = .mp4) {
        self.codec = codec
        self.maxShortSide = maxShortSide
        self.frameRateCap = frameRateCap
        self.rateControl = rateControl
        self.keepHDR = keepHDR
        self.audio = audio
        self.container = container
    }
}

/// Concrete encode parameters for one source + settings pair. Pure and
/// deterministic so it can be unit-tested without a device.
public struct TranscodePlan: Sendable, Equatable {
    /// Upright output size (rotation is baked into the pixels).
    public var outputSize: CGSize
    /// Expected output frame rate after the cap.
    public var frameRate: Double
    public var hdr: HDRFormat
    public var rateControl: RateControl
    public var settings: TranscodeSettings

    public var is10Bit: Bool { hdr.isHDR }
    /// For size-targeted plans: the video gets too few bits to look good even
    /// at the smallest size (suggest a bigger limit or a shorter selection).
    public var isStarved = false

    /// Bits per pixel per frame used to pick a default bitrate. Starting points
    /// to be tuned by measurement (PLAN.md §3c).
    static func bitsPerPixel(_ codec: VideoCodec) -> Double {
        switch codec {
        case .h264: 0.10
        case .hevc: 0.06
        }
    }

    /// `duration` is the length being exported (the trimmed selection);
    /// defaults to the whole source.
    public init(source: MediaInfo, settings: TranscodeSettings, duration: Double? = nil,
                device: [EncoderCapability] = []) {
        self.settings = settings
        let video = source.video
        let display = video?.displaySize ?? CGSize(width: 1920, height: 1080)
        outputSize = Self.outputSize(display: display, maxShortSide: settings.maxShortSide)

        let sourceRate = video?.nominalFrameRate ?? 30
        frameRate = min(sourceRate > 0 ? sourceRate : 30, Double(settings.frameRateCap))

        let deviceHas10Bit = device.first { $0.codec == .hevc }?.supports10Bit ?? true
        let sourceHDR = video?.hdrFormat ?? .sdr
        if settings.keepHDR, settings.codec == .hevc, deviceHas10Bit, sourceHDR.isHDR {
            // Dolby Vision 8.4 is HLG underneath; the RPU metadata can't be carried over.
            hdr = sourceHDR == .hdr10 ? .hdr10 : .hlg
        } else {
            hdr = .sdr
        }

        if let target = settings.targetFileSize {
            let fit = Self.fit(target: target, duration: duration ?? source.duration, display: display,
                               frameRate: frameRate, codec: settings.codec,
                               audioBitRate: Self.audioBitRate(settings.audio, track: settings.audioTrack,
                                                               source: source),
                               sourceBitRate: video?.bitRate ?? 0)
            outputSize = fit.size
            rateControl = .averageBitRate(fit.videoBitRate)
            isStarved = fit.starved
            return
        }

        // ABR by default: on iPhone (iOS 26) the HEVC encoder ignores the VBR
        // target, while ABR lands within ~5% and looked the same (PLAN.md §3c).
        rateControl = settings.rateControl ?? .averageBitRate(Self.defaultBitRate(
            codec: settings.codec, size: outputSize, frameRate: frameRate,
            sourceBitRate: video?.bitRate ?? 0))
    }

    /// Short sides tried for size-targeted output, largest first.
    static let fitSizes = [1080, 720, 540, 360, 240]

    /// Size-targeted output aims for at least this share of the normal
    /// presets' bits per pixel before dropping to a smaller size.
    static let fitMinimumDensity = 0.6

    /// Below this share even the smallest size looks poor.
    static let fitStarvedDensity = 0.25

    /// Budget → video bitrate, then the largest standard size that still gets
    /// enough bits per pixel. 5% of the budget covers container overhead.
    static func fit(target: Int64, duration: Double, display: CGSize, frameRate: Double, codec: VideoCodec,
                    audioBitRate: Int, sourceBitRate: Double) -> (size: CGSize, videoBitRate: Int, starved: Bool) {
        let total = Double(target) * 8 * 0.95 / max(duration, 0.1)
        var video = max(total - Double(audioBitRate), 50_000)
        if sourceBitRate > 0 { video = min(video, sourceBitRate * 0.9) }
        let effectiveFPS = frameRate <= 30 ? frameRate : 30 + (frameRate - 30) * 0.5
        func density(_ size: CGSize) -> Double {
            video / (Double(size.width * size.height) * effectiveFPS * bitsPerPixel(codec))
        }

        let sourceShort = Int(min(display.width, display.height))
        let candidates = ([sourceShort] + fitSizes.filter { $0 < sourceShort })
            .map { outputSize(display: display, maxShortSide: $0) }
        let size = candidates.first { density($0) >= fitMinimumDensity } ?? candidates.last ?? display
        return (size, Int(video), density(size) < fitStarvedDensity)
    }

    /// Audio bits per second this plan will spend (for size budgets and estimates).
    public static func audioBitRate(_ plan: AudioPlan, track: AudioTrackChoice = .automatic,
                                    source: MediaInfo) -> Int {
        guard let index = track.singleTrack(in: source.audio) else { return 0 }
        let main: AudioTrackInfo? = source.audio[index]
        switch plan {
        case .aac(let bps): return main.map { min(bps, Int($0.bitRate)) } ?? bps
        case .keep: return Int(main?.bitRate ?? 160_000)
        case .none: return 0
        }
    }

    /// Short side scaled down to `maxShortSide` (never up), aspect kept, even dimensions.
    static func outputSize(display: CGSize, maxShortSide: Int?) -> CGSize {
        let short = min(display.width, display.height)
        let scale = maxShortSide.map { short > CGFloat($0) ? CGFloat($0) / short : 1 } ?? 1
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(display.width), height: even(display.height))
    }

    /// `width × height × fps × bpp`, where 60 fps counts as ×1.5 of 30 (more
    /// frames, but more alike), capped below the source bitrate so a
    /// re-encode never grows the video.
    static func defaultBitRate(codec: VideoCodec, size: CGSize, frameRate: Double, sourceBitRate: Double) -> Int {
        let effectiveFPS = frameRate <= 30 ? frameRate : 30 + (frameRate - 30) * 0.5
        var bps = Double(size.width * size.height) * effectiveFPS * bitsPerPixel(codec)
        if sourceBitRate > 0 { bps = min(bps, sourceBitRate * 0.9) }
        return Int(max(bps, 200_000))
    }
}
