import CoreGraphics
import Foundation
import Testing
@testable import FootBrakeCore

/// Clips produced by `Fixtures/make-fixtures.sh`. Tests are skipped when they
/// haven't been generated.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../Fixtures/out")
        .standardized

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static var available: Bool {
        FileManager.default.fileExists(atPath: url("h264_1080p30_stereo.mp4").path)
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct MediaProbeFixtureTests {
    @Test func h264Stereo() async throws {
        let info = try await MediaProbe.probe(Fixtures.url("h264_1080p30_stereo.mp4"))
        let video = try #require(info.video)
        #expect(info.containerType == "public.mpeg-4")
        #expect(abs(info.duration - 10) < 0.1)
        #expect(video.codecName == "H.264")
        #expect(video.profile == "High")
        #expect(video.bitDepth == 8)
        #expect(video.codedSize == CGSize(width: 1920, height: 1080))
        #expect(video.rotation == 0)
        #expect(abs(video.nominalFrameRate - 30) < 0.1)
        #expect(!video.isVariableFrameRate)
        #expect(video.hdrFormat == .sdr)
        #expect(info.audio.count == 1)
        #expect(info.audio.first?.codecName == "AAC")
        #expect(info.audio.first?.channels == 2)
        #expect(info.audio.first?.sampleRate == 48000)
    }

    @Test func hevc60() async throws {
        let video = try #require(try await MediaProbe.probe(Fixtures.url("hevc_1080p60.mov")).video)
        #expect(video.codecFourCC == "hvc1")
        #expect(video.profile == "Main")
        #expect(abs(video.nominalFrameRate - 60) < 0.1)
    }

    @Test func hdrHLG10Bit() async throws {
        let video = try #require(try await MediaProbe.probe(Fixtures.url("hevc_hlg_10bit_2160p30.mov")).video)
        #expect(video.profile == "Main 10")
        #expect(video.bitDepth == 10)
        #expect(video.hdrFormat == .hlg)
        #expect(video.codedSize == CGSize(width: 3840, height: 2160))
    }

    @Test func portraitRotation() async throws {
        let video = try #require(try await MediaProbe.probe(Fixtures.url("portrait_rotated_1080p30.mov")).video)
        #expect([90, 270].contains(video.rotation))
        #expect(video.displaySize == CGSize(width: 1080, height: 1920))
        #expect(video.isPortrait)
    }

    @Test func variableFrameRate() async throws {
        let video = try #require(try await MediaProbe.probe(Fixtures.url("vfr_1080p30.mov")).video)
        #expect(video.isVariableFrameRate)
        #expect(!video.isHighFrameRate)
    }

    @Test func multipleAudioTracks() async throws {
        let info = try await MediaProbe.probe(Fixtures.url("multi_audio_51_stereo.mov"))
        #expect(info.audio.map(\.channels) == [6, 2])
        #expect(info.audio.first?.channelLayoutName == "5.1")
    }

    @Test func frameRate24() async throws {
        let video = try #require(try await MediaProbe.probe(Fixtures.url("h264_720p24.mp4")).video)
        #expect(abs(video.nominalFrameRate - 24) < 0.1)
    }

    @Test func captureMetadata() async throws {
        let meta = try await MediaProbe.probe(Fixtures.url("iphone_metadata.mov")).metadata
        #expect(meta.creationDate == ISO8601DateFormatter().date(from: "2026-11-15T06:49:14Z"))
        #expect(meta.location == GeoLocation(latitude: -33.8568, longitude: 151.2153, altitude: 5))
        #expect(meta.make == "Apple")
        #expect(meta.model == "iPhone 17 Pro Max")
        #expect(meta.software == "26.7.1")
    }

    @Test func rejectsNonVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video.mov")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: MediaProbeError.self) { try await MediaProbe.probe(url) }
    }
}

struct MediaProbeUnitTests {
    @Test(arguments: [
        (CGAffineTransform.identity, 0),
        (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0), 90),
        (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080), 180),
        (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920), 270),
    ])
    func rotation(transform: CGAffineTransform, degrees: Int) {
        #expect(MediaProbe.rotationDegrees(transform) == degrees)
    }

    @Test func iso6709() {
        let loc = GeoLocation(iso6709: "+37.3349-122.0090+010.000/")
        #expect(loc == GeoLocation(latitude: 37.3349, longitude: -122.009, altitude: 10))
        #expect(GeoLocation(iso6709: "+37.3349-122.0090/")?.altitude == nil)
        #expect(GeoLocation(iso6709: "garbage") == nil)
    }

    @Test func iphoneDateFormat() {
        #expect(MediaProbe.parseDate("2026-11-15T17:49:14+1100")
                == ISO8601DateFormatter().date(from: "2026-11-15T06:49:14Z"))
    }

    @Test func approximateSizes() {
        #expect(Format.approximateBytes(88_100_000) == Format.bytes(88_000_000))
        #expect(Format.approximateBytes(2_149_000) == Format.bytes(2_100_000))
        #expect(Format.approximateBytes(154_700_000) == Format.bytes(150_000_000))
        #expect(Format.approximateBytes(0) == Format.bytes(0))
    }

    @Test func durationFormatting() {
        #expect(Format.duration(62.5) == "1:02.500")
        #expect(Format.duration(3723.45) == "1:02:03.450")
    }
}

struct CameraDataTests {
    @Test func timedTrackNames() {
        #expect(MediaProbe.describeTimedTrack(["fiel/com.apple.quicktime.detected-face.bounds"]) == "detected faces")
        #expect(MediaProbe.describeTimedTrack(["mdta/com.apple.quicktime.live-photo-info"]) == "Live Photo info")
        #expect(MediaProbe.describeTimedTrack(["mdta/com.example.something"]) == "something")
        #expect(MediaProbe.describeTimedTrack([]) == "camera data")
    }

    @Test(.enabled(if: Fixtures.available)) func syntheticClipsHaveNone() async throws {
        #expect(try await MediaProbe.probe(Fixtures.url("iphone_metadata.mov")).camera.isEmpty)
    }
}
