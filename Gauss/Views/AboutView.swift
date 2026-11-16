import SwiftUI

/// About Gauss: version, ethos, licence, source and credits, with the
/// device and encoder details one level down.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    static let repository = URL(string: "https://github.com/nnathan/Gauss")!
    static let licence = URL(string: "https://github.com/nnathan/Gauss/blob/main/LICENSE")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Text("Gauss").font(.title2.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                        commitLabel
                        Text("Free and open source: no ads, no monetisation, no telemetry. "
                             + "Gauss will always respect its users.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    Link(destination: Self.repository) {
                        Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: Self.licence) {
                        Label("GNU General Public License v3", systemImage: "doc.text")
                    }
                } header: {
                    Text("Open source")
                } footer: {
                    Text("© 2026 Naveen Nathan. Gauss is free software: you can redistribute it and/or modify it "
                         + "under the terms of the GPL v3. The Gauss name and icon are not covered by the licence.")
                }

                Section {
                    Text("Gauss is a homage to the venerable HandBrake.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        DeviceInfoView()
                    } label: {
                        Label("Device & Encoders", systemImage: "cpu")
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The git commit this build came from (stamped at build time by
    /// Tools/stamp-build-info.sh). Links to GitHub unless it has local changes.
    @ViewBuilder
    private var commitLabel: some View {
        let info = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) }
        let commit = info?["Commit"] as? String ?? "unknown"
        let dirty = info?["Dirty"] as? Bool ?? false
        let short = String(commit.prefix(7))
        Group {
            if commit == "unknown" {
                Text("Commit unknown")
            } else if dirty {
                Text("Commit \(short) (modified)")
            } else {
                Link(destination: Self.repository.appendingPathComponent("commit/\(commit)")) {
                    Text("Commit \(short) \(Image(systemName: "arrow.up.right.square"))")
                }
            }
        }
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    AboutView()
}
