import AVFoundation
import Foundation
import Testing
@testable import FootBrakeCore

struct FitPlanTests {
    /// Portrait 4K60 iPhone clip with stereo AAC, like IMG_4472.
    private func source(duration: Double) -> MediaInfo {
        MediaInfo(fileName: "x.mov", fileSize: 0, containerType: nil, duration: duration,
                  video: VideoTrackInfo(codecFourCC: "hvc1", profile: nil, codedSize: CGSize(width: 3840, height: 2160),
                                        rotation: 90, nominalFrameRate: 60, peakFrameRate: 60, bitRate: 80_000_000,
                                        bitDepth: 10, colorPrimaries: nil, transferFunction: nil, matrix: nil,
                                        dolbyVisionProfile: 8),
                  audio: [AudioTrackInfo(codecFourCC: "aac ", channels: 2, sampleRate: 48_000, bitRate: 190_000,
                                         languageCode: nil)],
                  metadata: CaptureMetadata())
    }

    private func shortSide(_ megabytes: Double, seconds: Double) -> Int {
        let settings = OutputPreset.fitSize.settings(codec: .h264, frameRateCap: 30, keepHDR: false, audioKbps: 64,
                                                     fitSizeMB: megabytes)
        let plan = TranscodePlan(source: source(duration: seconds), settings: settings)
        return Int(min(plan.outputSize.width, plan.outputSize.height))
    }

    // Matches HandBrake's "Social 25 MB / 10 MB" presets.
    @Test func resolutionFollowsLength() {
        #expect(shortSide(25, seconds: 30) == 1080)
        #expect(shortSide(25, seconds: 60) == 720)
        #expect(shortSide(25, seconds: 300) == 360)
        #expect(shortSide(10, seconds: 60) == 540)
    }

    @Test func bitrateFitsTheBudget() {
        let settings = OutputPreset.fitSize.settings(codec: .h264, frameRateCap: 30, keepHDR: false, audioKbps: 64, fitSizeMB: 10)
        let plan = TranscodePlan(source: source(duration: 60), settings: settings)
        guard case .averageBitRate(let video) = plan.rateControl else { Issue.record("not ABR"); return }
        let bytes = Double(video + 64_000) * 60 / 8
        #expect(bytes <= 10_000_000 * 0.95 + 1)
        #expect(bytes > 10_000_000 * 0.9)
    }

    @Test func largerLimitsAndCustomSizes() {
        #expect(shortSide(100, seconds: 60) == 1080)
        #expect(shortSide(50, seconds: 300) == 540)
        // Out-of-range custom values are clamped (1 MB minimum).
        let tiny = OutputPreset.fitSize.settings(codec: .h264, frameRateCap: 30, keepHDR: false, audioKbps: 64,
                                                 fitSizeMB: 0.1)
        #expect(tiny.targetFileSize == 1_000_000)
    }

    @Test func trimmedSelectionGetsMoreBits() {
        let settings = OutputPreset.fitSize.settings(codec: .h264, frameRateCap: 30, keepHDR: false, audioKbps: 64, fitSizeMB: 10)
        let whole = TranscodePlan(source: source(duration: 300), settings: settings)
        let trimmed = TranscodePlan(source: source(duration: 300), settings: settings, duration: 30)
        #expect(trimmed.outputSize.height > whole.outputSize.height)
    }

    @Test func veryLongClipIsStarved() {
        let settings = OutputPreset.fitSize.settings(codec: .h264, frameRateCap: 30, keepHDR: false, audioKbps: 64, fitSizeMB: 10)
        let plan = TranscodePlan(source: source(duration: 1800), settings: settings)
        #expect(plan.isStarved)
        #expect(min(plan.outputSize.width, plan.outputSize.height) == 240)
    }
}

@Suite(.enabled(if: Fixtures.available, "run Fixtures/make-fixtures.sh first"))
struct FitTranscodeTests {
    @Test func outputFitsUnderTheLimit() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        var settings = TranscodeSettings(codec: .h264, audio: .aac(bitRate: 64_000))
        settings.targetFileSize = 1_000_000
        let result = try await Transcoder.transcode(source: Fixtures.url("h264_1080p30_stereo.mp4"),
                                                    settings: settings, to: output)
        #expect(result.fileSize <= 1_000_000)
        #expect(result.fileSize > 700_000)
        #expect(result.attempts <= 2)
    }
}
