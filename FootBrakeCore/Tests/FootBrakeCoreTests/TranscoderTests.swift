import AVFoundation
import Foundation
import Testing
@testable import FootBrakeCore

struct TranscodePlanTests {
    private func info(width: Int = 1920, height: Int = 1080, rotation: Int = 0, fps: Double = 30,
                      hdr: String? = nil, bitRate: Double = 20_000_000) -> MediaInfo {
        MediaInfo(fileName: "x.mov", fileSize: 0, containerType: nil, duration: 10,
                  video: VideoTrackInfo(codecFourCC: "hvc1", profile: nil,
                                        codedSize: CGSize(width: width, height: height), rotation: rotation,
                                        nominalFrameRate: fps, peakFrameRate: fps, bitRate: bitRate,
                                        bitDepth: hdr == nil ? 8 : 10, colorPrimaries: nil,
                                        transferFunction: hdr, matrix: nil, dolbyVisionProfile: nil),
                  audio: [], metadata: CaptureMetadata())
    }

    @Test func scalesShortSideAndKeepsAspect() {
        #expect(TranscodePlan.outputSize(display: CGSize(width: 3840, height: 2160), maxShortSide: 720)
                == CGSize(width: 1280, height: 720))
        #expect(TranscodePlan.outputSize(display: CGSize(width: 1080, height: 1920), maxShortSide: 480)
                == CGSize(width: 480, height: 854))
    }

    @Test func neverUpscales() {
        #expect(TranscodePlan.outputSize(display: CGSize(width: 1280, height: 720), maxShortSide: 1080)
                == CGSize(width: 1280, height: 720))
        #expect(TranscodePlan.outputSize(display: CGSize(width: 1280, height: 720), maxShortSide: nil)
                == CGSize(width: 1280, height: 720))
    }

    @Test func portraitSourceComesOutUpright() {
        let plan = TranscodePlan(source: info(rotation: 90), settings: TranscodeSettings(maxShortSide: 720))
        #expect(plan.outputSize == CGSize(width: 720, height: 1280))
    }

    @Test func frameRateIsCappedNeverRaised() {
        #expect(TranscodePlan(source: info(fps: 60), settings: TranscodeSettings(frameRateCap: 30)).frameRate == 30)
        #expect(TranscodePlan(source: info(fps: 24), settings: TranscodeSettings(frameRateCap: 60)).frameRate == 24)
    }

    @Test func hdrKeptOnlyForHEVC() {
        let hlg = info(hdr: "ITU_R_2100_HLG")
        #expect(TranscodePlan(source: hlg, settings: TranscodeSettings(codec: .hevc)).hdr == .hlg)
        #expect(TranscodePlan(source: hlg, settings: TranscodeSettings(codec: .h264)).hdr == .sdr)
        #expect(TranscodePlan(source: hlg, settings: TranscodeSettings(codec: .hevc, keepHDR: false)).hdr == .sdr)
        #expect(TranscodePlan(source: info(), settings: TranscodeSettings(codec: .hevc)).hdr == .sdr)
    }

    @Test func defaultBitRateNeverExceedsSource() {
        let plan = TranscodePlan(source: info(bitRate: 2_000_000), settings: TranscodeSettings(codec: .h264))
        #expect(plan.rateControl == .averageBitRate(1_800_000))
    }

    @Test func sixtyFPSCostsOneAndAHalfTimes() {
        let size = CGSize(width: 1920, height: 1080)
        let at30 = TranscodePlan.defaultBitRate(codec: .hevc, size: size, frameRate: 30, sourceBitRate: 0)
        let at60 = TranscodePlan.defaultBitRate(codec: .hevc, size: size, frameRate: 60, sourceBitRate: 0)
        #expect(Double(at60) / Double(at30) == 1.5)
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct TranscoderTests {
    private func temporaryOutput(_ ext: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).\(ext)")
    }

    @Test func portraitIsRotatedIntoThePixels() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await Transcoder.transcode(source: Fixtures.url("portrait_rotated_1080p30.mov"),
                                           settings: TranscodeSettings(codec: .h264, maxShortSide: 480), to: output)
        let video = try #require(try await MediaProbe.probe(output).video)
        #expect(video.codedSize == CGSize(width: 480, height: 854))
        #expect(video.rotation == 0)
    }

    @Test func sixtyFPSCappedToThirty() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await Transcoder.transcode(source: Fixtures.url("hevc_1080p60.mov"),
                                                    settings: TranscodeSettings(maxShortSide: 720, frameRateCap: 30),
                                                    to: output)
        #expect(result.usedHardwareEncoder == true)
        #expect(result.framesRead == 600)
        #expect(result.framesEncoded == 300)
        let info = try await MediaProbe.probe(output)
        #expect(abs((info.video?.nominalFrameRate ?? 0) - 30) < 0.5)
        #expect(abs(info.duration - 10) < 0.1)
    }

    @Test func hdrKeptAsHLGMain10() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await Transcoder.transcode(source: Fixtures.url("hevc_hlg_10bit_2160p30.mov"),
                                           settings: TranscodeSettings(codec: .hevc, maxShortSide: 1080), to: output)
        let video = try #require(try await MediaProbe.probe(output).video)
        #expect(video.profile == "Main 10")
        // VideoToolbox adds Dolby Vision 8.4 metadata to HLG Main 10 encodes.
        #expect([.hlg, .dolbyVision].contains(video.hdrFormat))
        #expect(video.transferFunction == "ITU_R_2100_HLG")
        #expect(video.codedSize == CGSize(width: 1920, height: 1080))
    }

    @Test func hdrToneMappedForH264() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await Transcoder.transcode(source: Fixtures.url("hevc_hlg_10bit_2160p30.mov"),
                                           settings: TranscodeSettings(codec: .h264, maxShortSide: 720), to: output)
        let video = try #require(try await MediaProbe.probe(output).video)
        #expect(video.codecName == "H.264")
        #expect(video.bitDepth == 8)
        #expect(video.hdrFormat == .sdr)
    }

    @Test func trimRangeAndStereoDownmix() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let range = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600),
                                end: CMTime(seconds: 6, preferredTimescale: 600))
        _ = try await Transcoder.transcode(source: Fixtures.url("multi_audio_51_stereo.mov"), range: range,
                                           settings: TranscodeSettings(codec: .h264, maxShortSide: 480), to: output)
        let info = try await MediaProbe.probe(output)
        #expect(abs(info.duration - 4) < 0.1)
        #expect(info.audio.count == 1)
        #expect(info.audio.first?.channels == 2)
        #expect(info.audio.first?.codecName == "AAC")
    }

    @Test func keepAudioCopiesTheTrack() async throws {
        let source = Fixtures.url("h264_1080p30_stereo.mp4")
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await Transcoder.transcode(source: source,
                                           settings: TranscodeSettings(maxShortSide: 480, audio: .keep), to: output)
        let before = try #require(try await MediaProbe.probe(source).audio.first)
        let after = try #require(try await MediaProbe.probe(output).audio.first)
        #expect(after.codecName == "AAC")
        #expect(abs(after.bitRate - before.bitRate) / before.bitRate < 0.05)
    }

    @Test func softwareEncoderCanBeForced() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        var settings = TranscodeSettings(codec: .h264, maxShortSide: 480)
        settings.forceSoftwareEncoder = true
        let result = try await Transcoder.transcode(source: Fixtures.url("h264_720p24.mp4"), settings: settings, to: output)
        #expect(result.usedHardwareEncoder == false)
        #expect(try await MediaProbe.probe(output).video?.codecName == "H.264")
    }

    @Test func keepsCaptureMetadata() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await Transcoder.transcode(source: Fixtures.url("iphone_metadata.mov"),
                                           settings: TranscodeSettings(maxShortSide: 480), to: output)
        let meta = try await MediaProbe.probe(output).metadata
        #expect(meta.creationDate == ISO8601DateFormatter().date(from: "2026-11-15T06:49:14Z"))
        #expect(meta.location != nil)
    }

    @Test func averageBitRateRespected() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await Transcoder.transcode(
            source: Fixtures.url("h264_1080p30_stereo.mp4"),
            settings: TranscodeSettings(codec: .h264, maxShortSide: 720, rateControl: .averageBitRate(1_500_000)),
            to: output)
        #expect(result.rateControl == .averageBitRate(1_500_000))
        let bitRate = try #require(try await MediaProbe.probe(output).video?.bitRate)
        #expect(bitRate > 1_000_000 && bitRate < 2_000_000)
    }

    @Test func cancellationMidEncode() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await Transcoder.transcode(source: Fixtures.url("hevc_hlg_10bit_2160p30.mov"),
                                           settings: TranscodeSettings(), to: output) { p in
                if p > 0.05 { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationStopsAndThrows() async throws {
        let output = temporaryOutput()
        defer { try? FileManager.default.removeItem(at: output) }
        let task = Task {
            try await Transcoder.transcode(source: Fixtures.url("hevc_hlg_10bit_2160p30.mov"),
                                           settings: TranscodeSettings(), to: output)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
