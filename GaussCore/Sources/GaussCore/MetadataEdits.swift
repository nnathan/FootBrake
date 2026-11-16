import AVFoundation

/// What to do with the recording date on export.
public enum DateEdit: Sendable, Equatable, Codable {
    case original
    case custom(Date)
    /// No date in the file; Photos then treats the video as taken "now".
    case remove
}

/// The user's metadata choices for an export: remove location, remove device
/// info, and keep/change/remove the recording date. Applied to file-level
/// metadata on every export path, and to what Save to Photos writes.
public struct MetadataEdits: Sendable, Equatable, Codable {
    public var removeLocation: Bool
    public var removeDeviceInfo: Bool
    public var date: DateEdit

    public init(removeLocation: Bool = false, removeDeviceInfo: Bool = false, date: DateEdit = .original) {
        self.removeLocation = removeLocation
        self.removeDeviceInfo = removeDeviceInfo
        self.date = date
    }

    public static let none = MetadataEdits()

    /// iPhone footage also carries device and personal data in places a
    /// file-level edit can't reach: lens details in track metadata and timed
    /// camera tracks (detected faces, Live Photo info). Exports that remove
    /// anything leave those out.
    public var dropsCameraData: Bool { removeLocation || removeDeviceInfo }

    /// File-level metadata with the edits applied.
    public func apply(to items: [AVMetadataItem]) -> [AVMetadataItem] {
        var result = items.filter { item in
            guard let id = item.identifier?.rawValue.lowercased() else { return true }
            if removeLocation && Self.isLocation(id) { return false }
            if removeDeviceInfo && Self.isDevice(id) { return false }
            if date != .original && Self.isCreationDate(id) { return false }
            return true
        }
        if case .custom(let date) = date {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = Self.iPhoneDateString(date) as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            result.append(item)
        }
        return result
    }

    /// What Save to Photos should write for this export.
    public func apply(to capture: CaptureMetadata) -> CaptureMetadata {
        var edited = capture
        if removeLocation { edited.location = nil }
        if removeDeviceInfo {
            edited.make = nil
            edited.model = nil
            edited.software = nil
        }
        switch date {
        case .original: break
        case .custom(let date): edited.creationDate = date
        case .remove: edited.creationDate = nil
        }
        return edited
    }

    static func isLocation(_ id: String) -> Bool {
        id.contains("location") || id.hasSuffix("/©xyz") || id.hasSuffix("/%a9xyz")
    }

    static func isDevice(_ id: String) -> Bool {
        id.hasSuffix(".make") || id.hasSuffix(".model") || id.hasSuffix(".software")
            || id.hasSuffix("/make") || id.hasSuffix("/model") || id.hasSuffix("/software")
            || id.contains(".camera.") || id.contains("maker-note") || id.contains("lens")
    }

    static func isCreationDate(_ id: String) -> Bool {
        id.contains("creationdate") || id.hasSuffix("/©day") || id.hasSuffix("/%a9day")
    }

    /// The iPhone camera's format, e.g. `2026-11-15T18:17:09+1100`, in the
    /// phone's current time zone.
    static func iPhoneDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
