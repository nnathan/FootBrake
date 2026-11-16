import AVFoundation
import Foundation
import Testing
@testable import GaussCore

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct HEVCTagFixerTests {
    /// A scratch copy, since the fix edits the file in place.
    private func copy(of name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)-\(name)")
        try FileManager.default.copyItem(at: Fixtures.url(name), to: url)
        return url
    }

    private func transcode(_ source: URL) async throws -> TranscodeResult {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        var settings = TranscodeSettings(codec: .h264, audio: .aac(bitRate: 64_000))
        settings.maxShortSide = 360
        return try await Transcoder.transcode(source: source, settings: settings, to: output)
    }

    @Test func hev1CannotBeDecodedAsIs() async throws {
        let source = try copy(of: "hevc_hev1_10bit.mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect {
            try await transcode(source)
        } throws: { error in
            (error as NSError).domain == AVFoundationErrorDomain
                && (error as NSError).code == AVError.decoderNotFound.rawValue
        }
    }

    @Test func relabelledHev1Transcodes() async throws {
        let source = try copy(of: "hevc_hev1_10bit.mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int

        #expect(try HEVCTagFixer.fixInPlace(source) == .fixed)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int == size)
        let info = try await MediaProbe.probe(source)
        #expect(info.video?.codecFourCC == "hvc1")

        let result = try await transcode(source)
        #expect(result.fileSize > 0)
        #expect(try HEVCTagFixer.fixInPlace(source) == .notNeeded)
    }

    @Test func hvc1IsLeftAlone() throws {
        let source = try copy(of: "hevc_1080p60.mov")
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try Data(contentsOf: source)
        #expect(try HEVCTagFixer.fixInPlace(source) == .notNeeded)
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func hev1WithoutParameterSetsIsUnsupported() throws {
        let source = try copy(of: "hevc_hev1_10bit.mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        // Empty the hvcC's NAL unit arrays (the count byte after 22 bytes of config).
        var data = try Data(contentsOf: source)
        let hvcC = try #require(data.range(of: Data("hvcC".utf8)))
        data[hvcC.upperBound + 22] = 0
        try data.write(to: source)

        #expect(try HEVCTagFixer.fixInPlace(source) == .unsupported)
        #expect(try Data(contentsOf: source) == data)
    }

    @Test func nonMovieIsNotNeeded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie".utf8).write(to: url)
        #expect(try HEVCTagFixer.fixInPlace(url) == .notNeeded)
    }
}
