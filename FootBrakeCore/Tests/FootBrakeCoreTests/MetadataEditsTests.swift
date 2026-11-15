import AVFoundation
import Foundation
import Testing
@testable import FootBrakeCore

struct MetadataEditsUnitTests {
    private func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value as NSString
        return item
    }

    private var iPhoneItems: [AVMetadataItem] {
        [item(.quickTimeMetadataLocationISO6709, "-35.4714+149.0955+609.389/"),
         item(AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.location.accuracy.horizontal"), "5.27"),
         item(.quickTimeMetadataMake, "Apple"), item(.quickTimeMetadataModel, "iPhone 17 Pro Max"),
         item(.quickTimeMetadataSoftware, "26.7.1"),
         item(.quickTimeMetadataCreationDate, "2026-11-15T18:17:09+1100"),
         item(AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.full-frame-rate-playback-intent"), "1")]
    }

    private func ids(_ items: [AVMetadataItem]) -> Set<String> {
        Set(items.compactMap { $0.identifier?.rawValue })
    }

    @Test func noEditsKeepsEverything() {
        #expect(ids(MetadataEdits.none.apply(to: iPhoneItems)) == ids(iPhoneItems))
        #expect(!MetadataEdits.none.dropsCameraData)
    }

    @Test func removesAllLocationKeys() {
        let kept = ids(MetadataEdits(removeLocation: true).apply(to: iPhoneItems))
        #expect(!kept.contains { $0.contains("location") })
        #expect(kept.contains("mdta/com.apple.quicktime.model"))
    }

    @Test func removesDeviceInfo() {
        let kept = ids(MetadataEdits(removeDeviceInfo: true).apply(to: iPhoneItems))
        #expect(!kept.contains("mdta/com.apple.quicktime.make"))
        #expect(!kept.contains("mdta/com.apple.quicktime.model"))
        #expect(!kept.contains("mdta/com.apple.quicktime.software"))
        #expect(kept.contains("mdta/com.apple.quicktime.location.ISO6709"))
        #expect(kept.contains("mdta/com.apple.quicktime.full-frame-rate-playback-intent"))
    }

    @Test func customDateReplacesTheOriginal() async throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        let items = MetadataEdits(date: .custom(date)).apply(to: iPhoneItems)
        let dates = items.filter { $0.identifier == .quickTimeMetadataCreationDate }
        #expect(dates.count == 1)
        let text = try await dates.first?.load(.stringValue)
        #expect(text.flatMap(MediaProbe.parseDate) == date)
    }

    @Test func removedDateLeavesNoDate() {
        let kept = ids(MetadataEdits(date: .remove).apply(to: iPhoneItems))
        #expect(!kept.contains { $0.contains("creationdate") })
    }

    @Test func photosCaptureFollowsEdits() throws {
        let capture = CaptureMetadata(creationDate: Date(), location: GeoLocation(latitude: 1, longitude: 2),
                                      make: "Apple", model: "iPhone", software: "26")
        let edited = MetadataEdits(removeLocation: true, removeDeviceInfo: true, date: .remove).apply(to: capture)
        #expect(edited == CaptureMetadata())
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct MetadataEditsExportTests {
    private let source = Fixtures.url("iphone_metadata.mov")
    private let range = CMTimeRange(start: .zero, end: CMTime(seconds: 2, preferredTimescale: 600))
    private let strip = MetadataEdits(removeLocation: true, removeDeviceInfo: true)

    private func output(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).\(ext)")
    }

    private func expectStripped(_ url: URL) async throws {
        let meta = try await MediaProbe.probe(url).metadata
        #expect(meta.location == nil)
        #expect(meta.make == nil && meta.model == nil && meta.software == nil)
        #expect(meta.creationDate != nil)
    }

    @Test func copyStrips() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await CopyExporter.export(source: source, range: range, mode: .keyframe, metadata: strip, to: out)
        try await expectStripped(out)
        #expect(try await MediaProbe.probe(out).audio.count == 1)
    }

    @Test func copyWithAudioBitRateStrips() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await AudioReencoder.export(source: source, range: range, mode: .keyframe, audioBitRate: 64_000,
                                        metadata: strip, to: out)
        try await expectStripped(out)
    }

    @Test func transcodeStripsAndChangesDate() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let date = try #require(ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        var settings = TranscodeSettings(maxShortSide: 480, container: .mov)
        settings.metadata = MetadataEdits(removeLocation: true, removeDeviceInfo: true, date: .custom(date))
        _ = try await Transcoder.transcode(source: source, settings: settings, to: out)
        let meta = try await MediaProbe.probe(out).metadata
        #expect(meta.location == nil && meta.model == nil)
        #expect(meta.creationDate == date)
    }

    @Test func copyRemovesDate() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await CopyExporter.export(source: source, range: range, mode: .keyframe,
                                      metadata: MetadataEdits(date: .remove), to: out)
        let meta = try await MediaProbe.probe(out).metadata
        #expect(meta.location != nil)
        #expect(meta.creationDate == nil)
    }
}
