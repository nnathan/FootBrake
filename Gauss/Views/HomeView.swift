import GaussCore
import PhotosUI
import SwiftUI

/// A probed video in the import store, ready to inspect, trim and encode.
struct SourceVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let info: MediaInfo

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HomeView: View {
    @State private var path: [SourceVideo] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var showingDeviceInfo = false
    @State private var importProgress: Progress?
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 32) {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Shrink, trim and convert your videos.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 12) {
                    PhotosPicker(selection: $photoItem, matching: .videos,
                                 preferredItemEncoding: .current) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Choose from Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(isImporting)
                .frame(maxWidth: 420)   // phone width on iPad, rather than edge to edge
            }
            .padding(24)
            .navigationTitle("Gauss")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingDeviceInfo = true
                    } label: {
                        Label("About Gauss", systemImage: "info.circle")
                    }
                }
            }
            .navigationDestination(for: SourceVideo.self) { source in
                EditorView(source: source)
            }
            .overlay {
                if isImporting { importOverlay }
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task { await importFromPhotos(item) }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url): Task { await importFromFiles(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingDeviceInfo) { AboutView() }
        #if DEBUG
        // Simulator testing: `simctl launch … -GaussOpen /path/to/clip.mov` or `-GaussShowAbout`
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-GaussOpen"), i + 1 < args.count {
                await importFromFiles(URL(fileURLWithPath: args[i + 1]))
            }
            if args.contains("-GaussShowAbout") { showingDeviceInfo = true }
        }
        #endif
        .alert("Couldn't Open Video", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var importOverlay: some View {
        VStack(spacing: 16) {
            if let importProgress {
                ProgressView(importProgress)
                Button("Cancel", role: .cancel) { importProgress.cancel() }
            } else {
                ProgressView("Reading video…")
            }
        }
        .padding(24)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Importing

    private func importFromPhotos(_ item: PhotosPickerItem) async {
        discardCurrentSource()
        isImporting = true
        defer { isImporting = false; importProgress = nil }
        do {
            let movie: ImportedMovie? = try await withCheckedThrowingContinuation { continuation in
                let progress = item.loadTransferable(type: ImportedMovie.self) { result in
                    continuation.resume(with: result)
                }
                progress.localizedDescription = "Loading from Photos…"
                importProgress = progress
            }
            importProgress = nil
            guard let movie else { return }
            await open(movie.url)
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFromFiles(_ url: URL) async {
        discardCurrentSource()
        isImporting = true
        defer { isImporting = false }
        do {
            let copy = try await Task.detached { try ImportStore.copyFromFiles(url) }.value
            await open(copy)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Only one source is worked on at a time; imports can be gigabytes.
    private func discardCurrentSource() {
        path = []
        ImportStore.removeAll()
    }

    private func open(_ url: URL) async {
        do {
            let info = try await MediaProbe.probe(url)
            path = [SourceVideo(url: url, info: info)]
        } catch {
            ImportStore.remove(url)
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    HomeView()
}
