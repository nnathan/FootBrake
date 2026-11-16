import AVFoundation
import Foundation
import Testing
@testable import GaussCore

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct CopyExporterTests {
    // h264_1080p30_stereo.mp4 has a keyframe every 30 frames (1 s).
    let source = Fixtures.url("h264_1080p30_stereo.mp4")

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private func temporaryOutput(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).\(ext)")
    }

    @Test func keyframeLocator() async throws {
        let t = try await KeyframeLocator.keyframe(atOrBefore: CMTime(seconds: 2.5, preferredTimescale: 600), in: source)
        #expect(abs(t.seconds - 2.0) < 0.001)
        let onKeyframe = try await KeyframeLocator.keyframe(atOrBefore: CMTime(seconds: 3, preferredTimescale: 600), in: source)
        #expect(abs(onKeyframe.seconds - 3.0) < 0.001)
    }

    @Test func keyframeModeStartsAtPreviousKeyframe() async throws {
        let output = temporaryOutput("mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await CopyExporter.export(source: source, range: range(2.5, 5), mode: .keyframe, to: output)

        let info = try await MediaProbe.probe(output)
        #expect(abs(info.duration - 3.0) < 0.05)
        #expect(info.containerType == "public.mpeg-4")
        #expect(info.audio.count == 1)
    }

    @Test func exactModeKeepsRequestedStart() async throws {
        let output = temporaryOutput("mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await CopyExporter.export(source: source, range: range(2.5, 5), mode: .exact, to: output)

        let info = try await MediaProbe.probe(output)
        #expect(abs(info.duration - 2.5) < 0.05)
    }

    @Test func videoSamplesAreBitIdentical() async throws {
        let output = temporaryOutput("mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await CopyExporter.export(source: source, range: range(2.0, 4.0), mode: .keyframe, to: output)

        let original = try await videoSampleData(source, from: 2.0, count: 60)
        let copied = try await videoSampleData(output, from: 0, count: 60)
        #expect(copied.count == 60)
        #expect(copied == original)
    }

    @Test func keepsEveryTrackAndCaptureMetadata() async throws {
        let output = temporaryOutput("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        try await CopyExporter.export(source: Fixtures.url("multi_audio_51_stereo.mov"),
                                      range: range(1, 3), mode: .keyframe, to: output)
        #expect(try await MediaProbe.probe(output).audio.map(\.channels) == [6, 2])

        try await CopyExporter.export(source: Fixtures.url("iphone_metadata.mov"),
                                      range: range(1, 3), mode: .keyframe, to: output)
        let meta = try await MediaProbe.probe(output).metadata
        #expect(meta.model == "iPhone 17 Pro Max")
        #expect(meta.location != nil)
        #expect(meta.creationDate != nil)
    }

    @Test func keepsRotation() async throws {
        let output = temporaryOutput("mov")
        defer { try? FileManager.default.removeItem(at: output) }
        try await CopyExporter.export(source: Fixtures.url("portrait_rotated_1080p30.mov"),
                                      range: range(0, 2), mode: .keyframe, to: output)
        #expect(try await MediaProbe.probe(output).video?.isPortrait == true)
    }

    /// Raw compressed bytes of `count` video samples starting at `start`, in decode order.
    private func videoSampleData(_ url: URL, from start: Double, count: Int) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples: [Data] = []
        while samples.count < count, let buffer = output.copyNextSampleBuffer() {
            guard let block = buffer.dataBuffer, let data = try? block.dataBytes() else { continue }
            samples.append(data)
        }
        return samples
    }
}

struct DurationParsingTests {
    @Test func parses() {
        #expect(Format.parseDuration("5") == 5)
        #expect(Format.parseDuration("2.5") == 2.5)
        #expect(Format.parseDuration("1:02.500") == 62.5)
        #expect(Format.parseDuration("1:02:03.45") == 3723.45)
    }

    @Test func rejects() {
        #expect(Format.parseDuration("") == nil)
        #expect(Format.parseDuration("1:75") == nil)
        #expect(Format.parseDuration("1.5:00") == nil)
        #expect(Format.parseDuration("-3") == nil)
        #expect(Format.parseDuration("a:b") == nil)
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct AudioReencoderTests {
    @Test func copiesVideoAndShrinksAudio() async throws {
        let source = Fixtures.url("multi_audio_51_stereo.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let range = CMTimeRange(start: .zero, end: CMTime(seconds: 4, preferredTimescale: 600))
        try await AudioReencoder.export(source: source, range: range, mode: .keyframe,
                                        audioBitRate: 64_000, to: output)

        let before = try await MediaProbe.probe(source), after = try await MediaProbe.probe(output)
        #expect(abs(after.duration - 4) < 0.05)
        #expect(after.video?.codedSize == before.video?.codedSize)
        #expect(abs((after.video?.bitRate ?? 0) - (before.video?.bitRate ?? 0)) / (before.video?.bitRate ?? 1) < 0.1)
        #expect(after.audio.count == 1)
        #expect(after.audio.first?.channels == 2)
        #expect((after.audio.first?.bitRate ?? .infinity) < 80_000)
    }

    @Test func keepsRotationFlag() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let range = CMTimeRange(start: .zero, end: CMTime(seconds: 2, preferredTimescale: 600))
        try await AudioReencoder.export(source: Fixtures.url("portrait_rotated_1080p30.mov"), range: range,
                                        mode: .exact, audioBitRate: 64_000, to: output)
        let video = try #require(try await MediaProbe.probe(output).video)
        #expect(video.codedSize == CGSize(width: 1920, height: 1080))
        #expect(video.isPortrait)
    }
}
