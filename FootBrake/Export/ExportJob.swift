import AVFoundation
import FootBrakeCore
import Foundation

/// Sandbox folder for finished exports; they live until saved or shared.
enum OutputStore {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)

    /// `IMG_4438.mov` → `Exports/IMG_4438 trimmed.mov`
    static func url(for source: URL, suffix: String, fileType: AVFileType) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = fileType == .mp4 ? "mp4" : fileType == .m4v ? "m4v" : "mov"
        return directory.appendingPathComponent("\(base) \(suffix).\(ext)")
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs one export and publishes its progress and outcome.
@MainActor
final class ExportJob: ObservableObject, Identifiable {
    enum State {
        case running(progress: Double)
        case finished(url: URL, info: MediaInfo, seconds: Double)
        case failed(String)
    }

    let id = UUID()
    let source: SourceVideo
    @Published private(set) var state: State = .running(progress: 0)
    private var task: Task<Void, Never>?

    init(source: SourceVideo) {
        self.source = source
    }

    func startCopy(range: CMTimeRange, mode: CopyCutMode, wholeFile: Bool) {
        let source = source
        task = Task {
            let began = Date()
            do {
                OutputStore.removeAll()
                let output = try OutputStore.url(for: source.url, suffix: wholeFile ? "copy" : "trimmed",
                                                 fileType: CopyExporter.fileType(for: source.url))
                try await CopyExporter.export(source: source.url, range: range, mode: mode, to: output) { p in
                    Task { @MainActor in
                        if case .running = self.state { self.state = .running(progress: p) }
                    }
                }
                let info = try await MediaProbe.probe(output)
                state = .finished(url: output, info: info, seconds: Date().timeIntervalSince(began))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Renames the finished file (keeping its extension). Invalid or
    /// clashing names are ignored, so the file always has a usable name.
    func rename(to name: String) {
        guard case .finished(let url, let info, let seconds) = state else { return }
        let clean = Self.sanitizedFileName(name)
        guard !clean.isEmpty else { return }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(clean)
            .appendingPathExtension(url.pathExtension)
        guard target != url, (try? FileManager.default.moveItem(at: url, to: target)) != nil else { return }
        state = .finished(url: target, info: info, seconds: seconds)
    }

    /// A copy of the finished file with the same name but different bytes
    /// (fresh container timestamps). Photos appears to match identical video
    /// data to an existing item and reuse its original filename, so a repeat
    /// save under a new name needs distinct content.
    func distinctCopy() async throws -> URL {
        guard case .finished(let url, _, _) = state else { throw CancellationError() }
        let folder = OutputStore.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try await CopyExporter.export(source: url, range: CMTimeRange(start: .zero, duration: .positiveInfinity),
                                      mode: .exact, to: copy)
        return copy
    }

    static func sanitizedFileName(_ name: String) -> String {
        let replaced = name.map { "/:\\".contains($0) ? "-" : String($0) }.joined()
        var trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return String(trimmed.prefix(200))
    }
}
