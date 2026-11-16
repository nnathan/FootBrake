import AVFoundation
import UniformTypeIdentifiers

public enum MediaProbeError: Error, LocalizedError {
    case unreadable
    case noVideoTrack

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file can't be read. Gauss supports MOV, MP4 and M4V videos."
        case .noVideoTrack: "This file has no video track."
        }
    }
}

/// Reads container, track and capture metadata from a video file using AVFoundation.
public enum MediaProbe {
    public static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { throw MediaProbeError.unreadable }

        let (duration, metadataItems) = try await asset.load(.duration, .metadata)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProbeError.noVideoTrack
        }
        var audio: [AudioTrackInfo] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            if let info = try await audioInfo(track) { audio.append(info) }
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var info = MediaInfo(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            containerType: UTType(filenameExtension: url.pathExtension)?.identifier,
            duration: duration.seconds,
            video: try await videoInfo(videoTrack),
            audio: audio,
            metadata: await captureMetadata(metadataItems)
        )
        info.camera = await cameraData(asset, videoTrack: videoTrack)
        return info
    }

    // MARK: - Camera data

    private static func cameraData(_ asset: AVAsset, videoTrack: AVAssetTrack) async -> CameraData {
        var data = CameraData()
        let trackItems = (try? await videoTrack.load(.metadata)) ?? []
        data.trackMetadataCount = trackItems.count
        if let lens = trackItems.first(where: { $0.identifier?.rawValue.hasSuffix("camera.lens_model") == true }) {
            data.lensModel = try? await lens.load(.stringValue)
        }
        for track in (try? await asset.loadTracks(withMediaType: .metadata)) ?? [] {
            let keys = (try? await track.load(.formatDescriptions))?.first
                .flatMap { CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] } ?? []
            data.timedTracks.append(describeTimedTrack(keys))
        }
        return data
    }

    /// A plain name for a timed metadata track from its keys.
    static func describeTimedTrack(_ keys: [String]) -> String {
        let names: [(String, String)] = [
            ("detected-face", "detected faces"), ("live-photo", "Live Photo info"),
            ("scene-illuminance", "scene brightness"), ("video-orientation", "orientation"),
            ("cinematic", "Cinematic data"), ("segment-identifier", "segment markers"),
            ("location", "location"),
        ]
        for (fragment, name) in names where keys.contains(where: { $0.contains(fragment) }) {
            return name
        }
        return keys.first.map { String($0.split(separator: ".").last ?? Substring($0)) } ?? "camera data"
    }

    // MARK: - Video

    private static func videoInfo(_ track: AVAssetTrack) async throws -> VideoTrackInfo? {
        let (formats, size, transform, fps, minFrameDuration, bitRate) = try await track.load(
            .formatDescriptions, .naturalSize, .preferredTransform, .nominalFrameRate,
            .minFrameDuration, .estimatedDataRate)
        guard let format = formats.first else { return nil }

        let fourCC = fourCCString(CMFormatDescriptionGetMediaSubType(format))
        let atoms = formatExtension(format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any] ?? [:]
        let (profile, bitDepth) = profileAndDepth(fourCC: fourCC, atoms: atoms)
        let dolbyVision = (atoms["dvcC"] ?? atoms["dvvC"] ?? atoms["dvwC"]) as? Data

        return VideoTrackInfo(
            codecFourCC: fourCC,
            profile: profile,
            codedSize: size,
            rotation: rotationDegrees(transform),
            nominalFrameRate: Double(fps),
            peakFrameRate: minFrameDuration.seconds > 0 ? 1 / minFrameDuration.seconds : Double(fps),
            bitRate: Double(bitRate),
            bitDepth: bitDepth,
            colorPrimaries: formatExtension(format, kCMFormatDescriptionExtension_ColorPrimaries) as? String,
            transferFunction: formatExtension(format, kCMFormatDescriptionExtension_TransferFunction) as? String,
            matrix: formatExtension(format, kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
            dolbyVisionProfile: dolbyVision.flatMap { $0.count > 2 ? Int($0[$0.startIndex + 2] >> 1) : nil }
        )
    }

    /// Reads the profile from the avcC/hvcC decoder configuration record.
    static func profileAndDepth(fourCC: String, atoms: [String: Any]) -> (String?, Int) {
        if let hvcC = atoms["hvcC"] as? Data, hvcC.count > 1 {
            switch hvcC[hvcC.startIndex + 1] & 0x1F {
            case 1: return ("Main", 8)
            case 2: return ("Main 10", 10)
            case 3: return ("Main Still Picture", 8)
            case 4: return ("Range Extensions", 10)
            case let idc: return ("Profile \(idc)", 8)
            }
        }
        if let avcC = atoms["avcC"] as? Data, avcC.count > 1 {
            switch avcC[avcC.startIndex + 1] {
            case 66: return ("Baseline", 8)
            case 77: return ("Main", 8)
            case 88: return ("Extended", 8)
            case 100: return ("High", 8)
            case 110: return ("High 10", 10)
            case 122: return ("High 4:2:2", 10)
            case 244: return ("High 4:4:4", 10)
            case let idc: return ("Profile \(idc)", 8)
            }
        }
        return (nil, fourCC.hasPrefix("ap4") ? 12 : 8)
    }

    /// Clockwise display rotation encoded in a track's transform, snapped to 90°.
    static func rotationDegrees(_ t: CGAffineTransform) -> Int {
        let degrees = atan2(t.b, t.a) * 180 / .pi
        let snapped = Int((degrees / 90).rounded()) * 90
        return (snapped % 360 + 360) % 360
    }

    // MARK: - Audio

    private static func audioInfo(_ track: AVAssetTrack) async throws -> AudioTrackInfo? {
        let (formats, bitRate, language) = try await track.load(
            .formatDescriptions, .estimatedDataRate, .languageCode)
        guard let format = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }
        return AudioTrackInfo(
            codecFourCC: fourCCString(asbd.mFormatID),
            channels: Int(asbd.mChannelsPerFrame),
            sampleRate: asbd.mSampleRate,
            bitRate: Double(bitRate),
            languageCode: language == "und" ? nil : language
        )
    }

    // MARK: - Capture metadata

    private static func captureMetadata(_ items: [AVMetadataItem]) async -> CaptureMetadata {
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first
            else { return nil }
            return try? await item.load(.stringValue)
        }
        func date(_ ids: AVMetadataIdentifier...) async -> Date? {
            for id in ids {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first
                else { continue }
                if let date = try? await item.load(.dateValue) { return date }
                if let text = try? await item.load(.stringValue), let date = parseDate(text) { return date }
            }
            return nil
        }

        var location = await string(.quickTimeMetadataLocationISO6709)
        if location == nil { location = await string(.commonIdentifierLocation) }
        return CaptureMetadata(
            creationDate: await date(.quickTimeMetadataCreationDate, .commonIdentifierCreationDate),
            location: location.flatMap(GeoLocation.init(iso6709:)),
            make: await string(.quickTimeMetadataMake),
            model: await string(.quickTimeMetadataModel),
            software: await string(.quickTimeMetadataSoftware)
        )
    }

    /// iPhone writes e.g. `2026-11-15T17:49:14+1100`; ISO8601DateFormatter needs the colon form.
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Helpers

    private static func formatExtension(_ format: CMFormatDescription, _ key: CFString) -> Any? {
        CMFormatDescriptionGetExtension(format, extensionKey: key)
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
