import GaussCore
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
    @State private var showingDetails = false
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
                            // Larger text truncates the file name and pushes the buttons off screen.
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                case .failed(let failure):
                    failed(failure)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .overlay(alignment: .top) { bannerView }
        }
        .interactiveDismissDisabled(isRunning)
    }

    /// Standard sheet buttons: Cancel (top-left) while running, Done or
    /// Close (top-right) afterwards.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch job.state {
        case .running:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) {
                    job.cancel()
                    dismiss()
                }
            }
        case .finished:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        case .failed:
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") { dismiss() }
            }
        }
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
                Text(job.activity)
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
            }
            if job.runsInBackground {
                Label {
                    Text("You can switch apps or lock your phone. iOS keeps the export going and shows its progress on the Lock Screen.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label {
                    Text("Keep Gauss open until this finishes. Switching to another app or locking your phone will stop the export.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func finished(url: URL, info: MediaInfo, seconds: Double) -> some View {
        VStack(spacing: 24) {
            ExportPreview(url: url)

            VStack(spacing: 6) {
                nameField(url)
                // One line, or stacked when large text won't fit on one.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text("\(Format.duration(info.duration)) · \(Format.bytes(info.fileSize)) ·")
                            .foregroundStyle(.secondary)
                        detailsButton
                    }
                    VStack(spacing: 6) {
                        Text("\(Format.duration(info.duration)) · \(Format.bytes(info.fileSize))")
                            .foregroundStyle(.secondary)
                        detailsButton
                    }
                }
                .sheet(isPresented: $showingDetails) {
                    SourceInfoView(info: info, original: job.source.info)
                }
                Text("Done in \(String(format: "%.1f", seconds)) s · was \(Format.bytes(job.source.info.fileSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let limit = job.targetFileSize {
                    let fits = info.fileSize <= limit
                    Label(fits ? "Fits in \(Format.bytes(limit))"
                               : "\(Format.bytes(info.fileSize)): slightly over the \(Format.bytes(limit)) limit",
                          systemImage: fits ? "checkmark.seal" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(fits ? Color.green : Color.orange)
                }
                if let first = job.firstAttemptSize {
                    Text("Fitted in 2 passes (first try \(Format.bytes(first)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = job.encoderNote {
                    Label(note, systemImage: note.hasPrefix("Encoded with hardware") ? "cpu" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(note.hasPrefix("Encoded with hardware") ? Color.secondary : Color.orange)
                }
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
            }
            .controlSize(.large)

            if let saveError {
                Text(saveError).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private func failed(_ failure: ExportFailure) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(failure.title).font(.headline)
            Text(failure.explanation).multilineTextAlignment(.center)
            Button {
                job.retry()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(failure.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }

    // MARK: - Pieces

    private var detailsButton: some View {
        Button {
            showingDetails = true
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        .buttonStyle(.borderless)
    }

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
            try await PhotoLibrarySaver.save(file, capture: job.metadata.apply(to: job.source.info.metadata))
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
