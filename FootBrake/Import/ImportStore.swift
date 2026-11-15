import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Owns the sandbox folder that imported source videos are copied into.
/// Each import gets its own subfolder so original file names are kept.
enum ImportStore {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)

    static func destination(for fileName: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    /// Moves (or, if that fails, copies) a file into the store.
    static func adopt(_ file: URL) throws -> URL {
        let destination = try destination(for: file.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            try FileManager.default.copyItem(at: file, to: destination)
        }
        return destination
    }

    /// Copies a user-picked file from Files (security-scoped) into the store.
    static func copyFromFiles(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = try destination(for: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Imports are only needed while the app is working on them.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A movie received from the Photos picker, already moved into `ImportStore`.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            ImportedMovie(url: try ImportStore.adopt(received.file))
        }
    }
}
