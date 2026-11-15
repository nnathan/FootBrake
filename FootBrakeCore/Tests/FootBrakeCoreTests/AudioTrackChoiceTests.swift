import AVFoundation
import Foundation
import Testing
@testable import FootBrakeCore

struct AudioTrackChoiceUnitTests {
    private func track(_ fourCC: String, channels: Int = 2) -> AudioTrackInfo {
        AudioTrackInfo(codecFourCC: fourCC, channels: channels, sampleRate: 48_000, bitRate: 160_000, languageCode: nil)
    }

    @Test func automaticPrefersAACOverSpatial() {
        #expect(AudioTrackChoice.automatic.singleTrack(in: [track("apac", channels: 4), track("aac ")]) == 1)
        #expect(AudioTrackChoice.automatic.singleTrack(in: []) == nil)
    }

    @Test func explicitAndNone() {
        let audio = [track("aac "), track("apac", channels: 4)]
        #expect(AudioTrackChoice.track(1).singleTrack(in: audio) == 1)
        #expect(AudioTrackChoice.track(7).singleTrack(in: audio) == 0)   // out of range → main
        #expect(AudioTrackChoice.none.singleTrack(in: audio) == nil)
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct AudioTrackChoiceExportTests {
    // multi_audio_51_stereo.mov: audio 0 = 5.1 AAC, audio 1 = stereo AAC.
    private let source = Fixtures.url("multi_audio_51_stereo.mov")
    private let range = CMTimeRange(start: .zero, end: CMTime(seconds: 3, preferredTimescale: 600))

    private func output(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).\(ext)")
    }

    @Test func copyKeepsOneChosenTrack() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await CopyExporter.export(source: source, range: range, mode: .keyframe, audioTrack: .track(0), to: out)
        #expect(try await MediaProbe.probe(out).audio.map(\.channels) == [6])
    }

    @Test func copyWithNoAudio() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await CopyExporter.export(source: source, range: range, mode: .keyframe, audioTrack: .none, to: out)
        let info = try await MediaProbe.probe(out)
        #expect(info.audio.isEmpty)
        #expect(info.video != nil)
    }

    @Test func copyAutomaticKeepsAllTracks() async throws {
        let out = output("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await CopyExporter.export(source: source, range: range, mode: .keyframe, to: out)
        #expect(try await MediaProbe.probe(out).audio.count == 2)
    }

    @Test func transcodeChosenTrackAndNone() async throws {
        let out = output("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        var settings = TranscodeSettings(codec: .h264, maxShortSide: 480, audio: .aac(bitRate: 96_000))
        settings.audioTrack = .track(0)   // 5.1 → downmixed to stereo
        _ = try await Transcoder.transcode(source: source, range: range, settings: settings, to: out)
        #expect(try await MediaProbe.probe(out).audio.map(\.channels) == [2])

        settings.audioTrack = .none
        _ = try await Transcoder.transcode(source: source, range: range, settings: settings, to: out)
        #expect(try await MediaProbe.probe(out).audio.isEmpty)
    }

    @Test func noAudioLeavesBudgetForVideo() {
        let info = MediaInfo(fileName: "x", fileSize: 0, containerType: nil, duration: 60, video: nil,
                             audio: [AudioTrackInfo(codecFourCC: "aac ", channels: 2, sampleRate: 48_000,
                                                    bitRate: 160_000, languageCode: nil)],
                             metadata: CaptureMetadata())
        #expect(TranscodePlan.audioBitRate(.aac(bitRate: 64_000), track: .none, source: info) == 0)
        #expect(TranscodePlan.audioBitRate(.aac(bitRate: 64_000), track: .automatic, source: info) == 64_000)
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct RemuxProgressTests {
    /// Regression: the remux reported NaN progress for timestamp-less marker
    /// buffers, which crashed the app's background-task progress update.
    @Test func progressIsAlwaysFinite() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let values = ProgressLog()
        let range = CMTimeRange(start: CMTime(seconds: 1.5, preferredTimescale: 600),
                                end: CMTime(seconds: 4, preferredTimescale: 600))
        try await CopyExporter.export(source: Fixtures.url("multi_audio_51_stereo.mov"), range: range,
                                      mode: .keyframe, audioTrack: .none, to: out) { values.add($0) }
        #expect(!values.all.isEmpty)
        #expect(values.all.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}
