import GaussCore
import SwiftUI

/// Device and VideoToolbox encoder details, shown from the About screen.
struct DeviceInfoView: View {
    @State private var capabilities: [EncoderCapability] = []
    #if DEBUG
    @AppStorage(DebugSettings.simulateSoftwareEncoders) private var simulateSoftware = false
    #endif

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: deviceDescription)
                LabeledContent("Background exports", value: backgroundExports)
            }
            Section("Video encoders") {
                ForEach(capabilities, id: \.codec) { cap in
                    EncoderRow(capability: cap)
                }
            }
            #if DEBUG
            Section {
                LabeledContent("Core", value: GaussCore.version)
                Toggle("Force software encoders", isOn: $simulateSoftware)
                NavigationLink("Measurement run") { MeasurementView() }
            } header: {
                Text("Debug")
            } footer: {
                Text("Shows the editor's warning and encodes with Apple's software encoder (iOS 17.4+), to test the slow path. Applies to videos opened after changing it.")
            }
            #endif
        }
        .navigationTitle("Device & Encoders")
        .navigationBarTitleDisplayMode(.inline)
        .task { capabilities = Capabilities.probe() }
    }

    private var backgroundExports: String {
        if #available(iOS 26, *) {
            return BackgroundExportTask.supportsBackgroundGPU ? "Supported" : "Copies only (no background GPU)"
        }
        return "Needs iOS 26"
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
    DeviceInfoView()
}

#if DEBUG
/// UserDefaults keys for debug-only switches. Compiled out of release builds.
enum DebugSettings {
    static let simulateSoftwareEncoders = "debug.simulateSoftwareEncoders"
    /// `-GaussDemo`: README recordings in the simulator, which has no hardware
    /// encoders, look as they would on an iPhone.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-GaussDemo")
}
#endif
