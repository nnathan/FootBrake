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
    case fitSize

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copy: "Copy (no re-encode)"
        case .original: "Original size"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        case .fitSize: "Fit in size"
        }
    }

    /// One-tap limits for "Fit in size", in decimal megabytes. 20 MB is the most
    /// widely accepted email size (Outlook.com and iCloud Mail; Gmail allows 25),
    /// though encoding adds ~37% in transit, so no email size is guaranteed.
    public static let fitSizeChoices: [Double] = [10, 20, 50, 100]

    /// Plain hints for the choices; deliberately not app names, whose limits change.
    public static func fitSizeHint(_ megabytes: Double) -> String {
        switch megabytes {
        case 10: "Chat apps"
        case 20: "Email"
        case 50: "Messaging uploads"
        case 100: "Larger uploads"
        default: "Any size"
        }
    }
    /// Bounds for a custom limit: below 1 MB even 240p is unwatchable for
    /// most clips; above 4 GB "fit" stops meaning anything.
    public static let fitSizeRange: ClosedRange<Double> = 1...4000

    public var maxShortSide: Int? {
        switch self {
        case .copy, .original, .fitSize: nil
        case .hd1080: 1080
        case .hd720: 720
        case .sd480: 480
        }
    }

    /// Small, shareable outputs favour H.264 (plays everywhere); the rest HEVC.
    public var defaultCodec: VideoCodec {
        switch self {
        case .sd480, .fitSize: .h264
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
        case .fitSize: 64
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
        case .fitSize: "fit"
        }
    }

    /// Whether this preset would shrink a source with the given short side.
    public func reducesSize(ofShortSide short: Double) -> Bool {
        maxShortSide.map { Double($0) < short } ?? true
    }

    /// `fitSizeMB` is the limit for "Fit in size" (ignored by other presets).
    public func settings(codec: VideoCodec, frameRateCap: Int, keepHDR: Bool, audioKbps: Int,
                         fitSizeMB: Double = 25) -> TranscodeSettings {
        var settings = TranscodeSettings(codec: codec, maxShortSide: maxShortSide, frameRateCap: frameRateCap,
                                         keepHDR: keepHDR, audio: AudioPlan(kbps: audioKbps), container: .mp4)
        if self == .fitSize {
            let mb = min(max(fitSizeMB, Self.fitSizeRange.lowerBound), Self.fitSizeRange.upperBound)
            settings.targetFileSize = Int64(mb * 1_000_000)
        }
        return settings
    }
}
