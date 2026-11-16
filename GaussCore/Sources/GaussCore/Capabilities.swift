import CoreMedia
import VideoToolbox

/// Video codecs Gauss can encode to.
public enum VideoCodec: String, CaseIterable, Sendable, Codable {
    case h264
    case hevc

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        }
    }
}

/// What this device's VideoToolbox encoder supports for one codec.
public struct EncoderCapability: Sendable, Equatable {
    public let codec: VideoCodec
    public let encoderID: String?
    public let isAvailable: Bool
    public let isHardwareAccelerated: Bool
    /// HEVC Main10 (10-bit), needed to keep HDR. Always false for H.264.
    public let supports10Bit: Bool
    /// Constant-quality rate control (`kVTCompressionPropertyKey_Quality`).
    public let supportsConstantQuality: Bool
    public let supportsSpeedPriority: Bool

    public init(codec: VideoCodec, encoderID: String?, isAvailable: Bool, isHardwareAccelerated: Bool,
                supports10Bit: Bool, supportsConstantQuality: Bool, supportsSpeedPriority: Bool) {
        self.codec = codec
        self.encoderID = encoderID
        self.isAvailable = isAvailable
        self.isHardwareAccelerated = isHardwareAccelerated
        self.supports10Bit = supports10Bit
        self.supportsConstantQuality = supportsConstantQuality
        self.supportsSpeedPriority = supportsSpeedPriority
    }
}

/// Probes VideoToolbox for encoder support, mirroring HandBrake's
/// `libhb/platform/macosx/vt_common.c`.
public enum Capabilities {
    public static func probe() -> [EncoderCapability] {
        VideoCodec.allCases.map(probe)
    }

    public static func probe(_ codec: VideoCodec) -> EncoderCapability {
        var encoderIDOut: CFString?
        var propertiesOut: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920, height: 1080,
            codecType: codec.codecType,
            encoderSpecification: hardwareSpecification(),
            encoderIDOut: &encoderIDOut,
            supportedPropertiesOut: &propertiesOut
        )
        guard status == noErr, let properties = propertiesOut as? [String: Any] else {
            return EncoderCapability(codec: codec, encoderID: nil, isAvailable: false,
                                     isHardwareAccelerated: false, supports10Bit: false,
                                     supportsConstantQuality: false, supportsSpeedPriority: false)
        }
        let encoderID = encoderIDOut as String?
        return EncoderCapability(
            codec: codec,
            encoderID: encoderID,
            isAvailable: true,
            isHardwareAccelerated: encoderID.map(isHardwareEncoder) ?? false,
            supports10Bit: codec == .hevc
                && supportedProfileLevels(properties).contains(kVTProfileLevel_HEVC_Main10_AutoLevel as String),
            supportsConstantQuality: properties[kVTCompressionPropertyKey_Quality as String] != nil,
            supportsSpeedPriority: properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] != nil
        )
    }

    /// On iOS 17.4+ (and macOS) we can insist on a hardware encoder; earlier iOS
    /// only ships hardware encoders for H.264/HEVC, so no specification is needed.
    private static func hardwareSpecification() -> CFDictionary? {
        #if os(macOS)
        return [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        #else
        if #available(iOS 17.4, *) {
            return [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        }
        return nil
        #endif
    }

    static func isHardwareEncoder(_ encoderID: String) -> Bool {
        var listOut: CFArray?
        guard VTCopyVideoEncoderList(nil, &listOut) == noErr,
              let list = listOut as? [[String: Any]] else { return false }
        let entry = list.first { ($0[kVTVideoEncoderList_EncoderID as String] as? String) == encoderID }
        return entry?[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false
    }

    private static func supportedProfileLevels(_ properties: [String: Any]) -> [String] {
        let profile = properties[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
        return profile?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
    }
}
