import Foundation

/// The export choices shown in the app. Inspired by HandBrake's General
/// presets (`preset/preset_builtin.json`), reduced to what makes sense for
/// iPhone footage with a hardware encoder.
public enum OutputPreset: String, CaseIterable, Sendable, Codable, Identifiable {
    case copy
    case original
    case hd1080
    case hd720
    case sd480
    case fit25MB
    case fit10MB

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copy: "Copy (no re-encode)"
        case .original: "Original size"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        case .fit25MB: "Fit in 25 MB"
        case .fit10MB: "Fit in 10 MB"
        }
    }

    /// Size limit for the "Fit in" presets (decimal megabytes, the safer
    /// reading of messaging and email limits).
    public var targetFileSize: Int64? {
        switch self {
        case .fit25MB: 25_000_000
        case .fit10MB: 10_000_000
        default: nil
        }
    }

    public var maxShortSide: Int? {
        switch self {
        case .copy, .original, .fit25MB, .fit10MB: nil
        case .hd1080: 1080
        case .hd720: 720
        case .sd480: 480
        }
    }

    /// Small, shareable outputs favour H.264 (plays everywhere); the rest HEVC.
    public var defaultCodec: VideoCodec {
        switch self {
        case .sd480, .fit25MB, .fit10MB: .h264
        default: .hevc
        }
    }

    /// Default for the audio picker: 0 keeps the source audio, otherwise
    /// kbps. Audio is a small share of large outputs, so those keep it.
    public var defaultAudioKbps: Int {
        switch self {
        case .copy, .original, .hd1080: 0
        case .hd720: 128
        case .sd480: 96
        case .fit25MB, .fit10MB: 64
        }
    }

    /// File-name suffix for exports, e.g. `IMG_4446 720p.mp4`.
    public var fileSuffix: String {
        switch self {
        case .copy: "trimmed"
        case .original: "small"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        case .fit25MB: "25MB"
        case .fit10MB: "10MB"
        }
    }

    /// Whether this preset would shrink a source with the given short side.
    public func reducesSize(ofShortSide short: Double) -> Bool {
        maxShortSide.map { Double($0) < short } ?? true
    }

    public func settings(codec: VideoCodec, frameRateCap: Int, keepHDR: Bool, audioKbps: Int) -> TranscodeSettings {
        var settings = TranscodeSettings(codec: codec, maxShortSide: maxShortSide, frameRateCap: frameRateCap,
                                         keepHDR: keepHDR, audio: AudioPlan(kbps: audioKbps), container: .mp4)
        settings.targetFileSize = targetFileSize
        return settings
    }
}
