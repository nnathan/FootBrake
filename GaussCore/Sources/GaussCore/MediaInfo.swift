import CoreGraphics
import CoreMedia
import Foundation

/// Everything Gauss knows about a source file. Produced by `MediaProbe`.
public struct MediaInfo: Sendable, Equatable {
    public var fileName: String
    public var fileSize: Int64
    /// UTI of the container, e.g. `com.apple.quicktime-movie`.
    public var containerType: String?
    public var duration: Double
    public var video: VideoTrackInfo?
    public var audio: [AudioTrackInfo]
    public var metadata: CaptureMetadata
    /// Camera details beyond the file-level capture metadata.
    public var camera = CameraData()

    /// Overall bitrate of the file in bits per second.
    public var overallBitRate: Double {
        duration > 0 ? Double(fileSize) * 8 / duration : 0
    }
}

public struct VideoTrackInfo: Sendable, Equatable {
    /// Four-character codec code, e.g. `hvc1`, `avc1`, `dvh1`.
    public var codecFourCC: String
    public var profile: String?
    /// Dimensions as stored in the file (before rotation).
    public var codedSize: CGSize
    /// Clockwise rotation applied on playback, in degrees (0, 90, 180, 270).
    public var rotation: Int
    public var nominalFrameRate: Double
    /// Highest instantaneous frame rate, derived from the shortest frame duration.
    public var peakFrameRate: Double
    public var bitRate: Double
    public var bitDepth: Int
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var matrix: String?
    public var dolbyVisionProfile: Int?

    /// Dimensions as seen by the viewer (after rotation).
    public var displaySize: CGSize {
        rotation % 180 == 0 ? codedSize : CGSize(width: codedSize.height, height: codedSize.width)
    }

    public var isPortrait: Bool { displaySize.height > displaySize.width }

    public var hdrFormat: HDRFormat {
        if dolbyVisionProfile != nil { return .dolbyVision }
        switch transferFunction {
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG): return .hlg
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ): return .hdr10
        default: return .sdr
        }
    }

    /// Frame timing varies noticeably (iPhone camera footage usually does).
    public var isVariableFrameRate: Bool {
        nominalFrameRate > 0 && peakFrameRate > nominalFrameRate * 1.05
    }

    /// High-frame-rate capture such as iPhone Slo-mo (120/240 fps).
    public var isHighFrameRate: Bool { nominalFrameRate >= 100 }

    public var codecName: String {
        switch codecFourCC {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "HEVC (Dolby Vision)"
        case "dva1", "dvav": "H.264 (Dolby Vision)"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "ProRes"
        case "av01": "AV1"
        case "mp4v": "MPEG-4 Part 2"
        default: codecFourCC
        }
    }
}

public enum HDRFormat: String, Sendable {
    case sdr = "SDR"
    case hlg = "HDR (HLG)"
    case hdr10 = "HDR10 (PQ)"
    case dolbyVision = "Dolby Vision"

    public var isHDR: Bool { self != .sdr }
}

public struct AudioTrackInfo: Sendable, Equatable {
    public var codecFourCC: String
    public var channels: Int
    public var sampleRate: Double
    public var bitRate: Double
    public var languageCode: String?

    public var codecName: String {
        switch codecFourCC {
        case "aac ": "AAC"
        case "ac-3": "AC-3"
        case "ec-3": "E-AC-3"
        case "alac": "ALAC"
        case "lpcm": "PCM"
        case ".mp3": "MP3"
        case "opus": "Opus"
        case "fLaC": "FLAC"
        case "apac": "APAC"
        default: codecFourCC.trimmingCharacters(in: .whitespaces)
        }
    }

    public var channelLayoutName: String {
        if codecFourCC == "apac" { return "Spatial (\(channels)-channel ambisonic)" }
        return switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
    }
}

/// Capture details that should survive a transcode, so the output sorts and
/// maps correctly when saved back to Photos.
public struct CaptureMetadata: Sendable, Equatable {
    public var creationDate: Date?
    public var location: GeoLocation?
    public var make: String?
    public var model: String?
    public var software: String?

    public init(creationDate: Date? = nil, location: GeoLocation? = nil,
                make: String? = nil, model: String? = nil, software: String? = nil) {
        self.creationDate = creationDate
        self.location = location
        self.make = make
        self.model = model
        self.software = software
    }
}

public struct GeoLocation: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    /// Parses ISO 6709 strings as written by the iPhone camera, e.g.
    /// `+37.3349-122.0090+010.000/`.
    public init?(iso6709: String) {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: iso6709, range: NSRange(iso6709.startIndex..., in: iso6709))
        else { return nil }
        func group(_ i: Int) -> Double? {
            Range(match.range(at: i), in: iso6709).flatMap { Double(iso6709[$0]) }
        }
        guard let lat = group(1), let lon = group(2), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        latitude = lat
        longitude = lon
        altitude = group(3)
    }

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// Device data the iPhone camera stores outside the file-level metadata:
/// lens details on the video track, and timed metadata tracks.
public struct CameraData: Sendable, Equatable {
    /// e.g. "iPhone 17 Pro Max back camera 6.765mm f/1.78".
    public var lensModel: String?
    /// Other camera metadata on the video track (focal length, aperture, maker notes).
    public var trackMetadataCount = 0
    /// One plain description per timed metadata track, e.g. "detected faces".
    public var timedTracks: [String] = []

    public init(lensModel: String? = nil, trackMetadataCount: Int = 0, timedTracks: [String] = []) {
        self.lensModel = lensModel
        self.trackMetadataCount = trackMetadataCount
        self.timedTracks = timedTracks
    }

    public var isEmpty: Bool { lensModel == nil && trackMetadataCount == 0 && timedTracks.isEmpty }
}
