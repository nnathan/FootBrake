import FootBrakeCore
import SwiftUI

/// Stage 0 placeholder: proves the app, the Core package, and VideoToolbox
/// all work on the device by listing the hardware encoders it reports.
struct ContentView: View {
    @State private var capabilities: [EncoderCapability] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("App", value: appVersion)
                    LabeledContent("Core", value: FootBrakeCore.version)
                    LabeledContent("Device", value: deviceDescription)
                }
                Section("Video encoders") {
                    ForEach(capabilities, id: \.codec) { cap in
                        EncoderRow(capability: cap)
                    }
                }
            }
            .navigationTitle("FootBrake")
            .task { capabilities = Capabilities.probe() }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var deviceDescription: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(model), iOS \(UIDevice.current.systemVersion)"
    }
}

private struct EncoderRow: View {
    let capability: EncoderCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(capability.codec.displayName).font(.headline)
                Spacer()
                Image(systemName: capability.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(capability.isAvailable ? .green : .secondary)
            }
            if capability.isAvailable {
                Text(features.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var features: [String] {
        var list = [capability.isHardwareAccelerated ? "Hardware" : "Software"]
        if capability.supports10Bit { list.append("10-bit HDR") }
        if capability.supportsConstantQuality { list.append("Constant quality") }
        return list
    }
}

#Preview {
    ContentView()
}
