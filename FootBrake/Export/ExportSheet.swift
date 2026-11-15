import FootBrakeCore
import SwiftUI

/// Progress while exporting, then the result with Save and Share actions and
/// a running list of what has been done with the file.
struct ExportSheet: View {
    @ObservedObject var job: ExportJob
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var fileName = ""
    @State private var actions: [CompletedAction] = []
    @State private var banner: CompletedAction?
    @FocusState private var editingName: Bool

    struct CompletedAction: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let icon: String
        /// The file name at the time, since later renames don't affect copies.
        let fileName: String
        let date = Date()
    }

    var body: some View {
        NavigationStack {
            Group {
                switch job.state {
                case .running(let progress):
                    running(progress)
                case .finished(let url, let info, let seconds):
                    ScrollView {
                        finished(url: url, info: info, seconds: seconds)
                    }
                case .failed(let message):
                    failed(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) { bannerView }
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    /// File name of the most recent copy added to Photos, if any.
    private var photosCopyName: String? {
        actions.last { $0.icon == "photo.on.rectangle" }?.fileName
    }

    // MARK: - States

    private func running(_ progress: Double) -> some View {
        VStack(spacing: 20) {
            ProgressView(value: progress) {
                Text("Copying…")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
            }
            Button("Cancel", role: .cancel) {
                job.cancel()
                dismiss()
            }
        }
    }

    private func finished(url: URL, info: MediaInfo, seconds: Double) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            VStack(spacing: 6) {
                nameField(url)
                Text("\(Format.duration(info.duration)) · \(Format.bytes(info.fileSize))")
                    .foregroundStyle(.secondary)
                Text("Done in \(String(format: "%.1f", seconds)) s · was \(Format.bytes(job.source.info.fileSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !actions.isEmpty { actionList }

            VStack(spacing: 12) {
                photosButton(url)

                Button {
                    editingName = false
                    Task { await share(url) }
                } label: {
                    Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Done") { dismiss() }
                    .padding(.top, 8)
            }
            .controlSize(.large)

            if let saveError {
                Text(saveError).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Export failed").font(.headline)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close") { dismiss() }.buttonStyle(.bordered)
        }
    }

    // MARK: - Pieces

    private func nameField(_ url: URL) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                TextField("File name", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($editingName)
                    .onChange(of: fileName) { job.rename(to: $0) }
                Text(".\(url.pathExtension)").foregroundStyle(.secondary)
            }
            .font(.headline)
            .task { if fileName.isEmpty { fileName = url.deletingPathExtension().lastPathComponent } }

            if let note = renameNote(current: url.lastPathComponent) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 4)
    }

    /// Explains that renaming doesn't reach copies already saved or shared.
    private func renameNote(current: String) -> String? {
        if let photosName = photosCopyName, photosName != current {
            return "Already saved to Photos as “\(photosName)”. To use the new name there, save again. This adds a second copy."
        }
        if let last = actions.last, last.fileName != current {
            return "Copies already shared keep the name “\(last.fileName)”."
        }
        return nil
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Done so far").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .frame(width: 20, height: 20)
                        .background(Color.green.opacity(0.2), in: Circle())
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.text)
                        Text("as “\(action.fileName)” · \(action.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func photosButton(_ url: URL) -> some View {
        if photosCopyName == url.lastPathComponent {
            Button {
                openURL(URL(string: "photos-redirect://")!)
            } label: {
                Label("Open Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                editingName = false
                Task { await save(url) }
            } label: {
                Label(isSaving ? "Saving…" : photosCopyName == nil ? "Save to Photos" : "Save to Photos (new name)",
                      systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            Label(banner.text, systemImage: banner.icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func record(_ text: String, icon: String, url: URL) {
        let action = CompletedAction(text: text, icon: icon, fileName: url.lastPathComponent)
        withAnimation {
            actions.append(action)
            banner = action
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { if banner == action { banner = nil } }
        }
    }

    private func save(_ url: URL) async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let file = photosCopyName == nil ? url : try await job.distinctCopy()
            defer { if file != url { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
            try await PhotoLibrarySaver.save(file, capture: job.source.info.metadata)
            record("Saved to Photos", icon: "photo.on.rectangle", url: url)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Shares the file. If Photos already holds this video under another
    /// name, the share sheet gets a byte-distinct copy so its "Save Video"
    /// isn't matched to that earlier item (see `ExportJob.distinctCopy`).
    private func share(_ url: URL) async {
        let needsDistinctCopy = photosCopyName.map { $0 != url.lastPathComponent } ?? false
        var file = url
        if needsDistinctCopy {
            do {
                file = try await job.distinctCopy()
            } catch {
                saveError = error.localizedDescription
                return
            }
        }
        ActivitySheet.present(file) { type, completed in
            if file != url { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            guard completed else { return }
            let (text, icon) = ActivitySheet.describe(type)
            record(text, icon: icon, url: url)
        }
    }
}
