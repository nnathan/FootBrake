import Testing
@testable import GaussCore

struct CapabilitiesTests {
    @Test func probesEveryCodec() {
        #expect(Capabilities.probe().map(\.codec) == VideoCodec.allCases)
    }

    // Every Apple Silicon Mac and every iPhone has a hardware H.264 encoder.
    @Test func h264HardwareEncoderIsAvailable() {
        let cap = Capabilities.probe(.h264)
        #expect(cap.isAvailable)
        #expect(cap.isHardwareAccelerated)
        #expect(!cap.supports10Bit)
    }
}
