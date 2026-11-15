import CoreLocation
import FootBrakeCore
import Photos

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            "FootBrake doesn't have permission to add to your Photos library. You can allow it in Settings › Privacy & Security › Photos."
        }
    }

    /// Adds a video to Photos with the original recording date and location,
    /// so it sorts next to the source instead of appearing as "today". The
    /// file's name becomes the asset's original filename.
    static func save(_ url: URL, capture: CaptureMetadata) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let date = capture.creationDate { request.creationDate = date }
            if let location = capture.location {
                request.location = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                    altitude: location.altitude ?? 0,
                    horizontalAccuracy: 0, verticalAccuracy: location.altitude == nil ? -1 : 0,
                    timestamp: capture.creationDate ?? Date())
            }
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }
}
