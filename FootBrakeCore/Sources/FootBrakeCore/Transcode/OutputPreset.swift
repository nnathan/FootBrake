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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copy: "Copy (no re-encode)"
        case .original: "Original size"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        }
    }

    public var maxShortSide: Int? {
        switch self {
        case .copy, .original: nil
        case .hd1080: 1080
        case .hd720: 720
        case .sd480: 480
        }
    }

    /// 480p is for small, compatible files; everything else favours HEVC.
    public var defaultCodec: VideoCodec {
        self == .sd480 ? .h264 : .hevc
    }

    /// Default for the audio picker: 0 keeps the source audio, otherwise
    /// kbps. Audio is a small share of large outputs, so those keep it.
    public var defaultAudioKbps: Int {
        switch self {
        case .copy, .original, .hd1080: 0
        case .hd720: 128
        case .sd480: 96
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
        }
    }

    /// Whether this preset would shrink a source with the given short side.
    public func reducesSize(ofShortSide short: Double) -> Bool {
        maxShortSide.map { Double($0) < short } ?? true
    }

    public func settings(codec: VideoCodec, frameRateCap: Int, keepHDR: Bool, audioKbps: Int) -> TranscodeSettings {
        TranscodeSettings(codec: codec, maxShortSide: maxShortSide, frameRateCap: frameRateCap,
                          keepHDR: keepHDR, audio: AudioPlan(kbps: audioKbps), container: .mp4)
    }
}
