import AVFoundation
import Combine
import FootBrakeCore
import UIKit

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

/// A failed export explained in plain language, with the technical error kept as detail.
struct ExportFailure {
    let title: String
    let explanation: String
    let detail: String

    private init(title: String, explanation: String, detail: String) {
        self.title = title
        self.explanation = explanation
        self.detail = detail
    }

    /// iOS ended the background task (e.g. it needed the resources).
    static let stoppedByIOS = ExportFailure(
        title: "Export stopped",
        explanation: "iOS stopped the export while FootBrake was in the background. "
            + "Try again, and keep FootBrake open if it happens again.",
        detail: "Background task expired")

    init(_ error: Error, wentToBackground: Bool) {
        let ns = error as NSError
        detail = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        if wentToBackground {
            title = "Export stopped"
            explanation = "FootBrake left the screen during the export, so iOS stopped the video encoder. "
                + "Keep FootBrake open until the export finishes, then try again."
        } else if case TranscodeError.encoderBusy = error {
            title = "Video encoder busy"
            explanation = "Another app may be using the camera, recording, streaming or on a call. "
                + "Close it or end the call, then try again."
        } else if Self.isOutOfSpace(ns) {
            title = "Not enough storage"
            explanation = "Your iPhone ran out of space while writing the video. "
                + "Free up some storage in Settings › General › iPhone Storage, then try again."
        } else {
            title = "Export failed"
            explanation = "Something went wrong while exporting. Trying again often works; "
                + "if it keeps failing, the details below will help track it down."
        }
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        let codes: [(String, Int)] = [(NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                                      (AVFoundationErrorDomain, AVError.diskFull.rawValue),
                                      (NSPOSIXErrorDomain, Int(ENOSPC))]
        var current: NSError? = error
        while let e = current {
            if codes.contains(where: { $0.0 == e.domain && $0.1 == e.code }) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// Runs one export and publishes its progress and outcome.
@MainActor
final class ExportJob: ObservableObject, Identifiable {
    enum State {
        case running(progress: Double)
        case finished(url: URL, info: MediaInfo, seconds: Double)
        case failed(ExportFailure)
    }

    let id = UUID()
    let source: SourceVideo
    /// Metadata choices for this export; Save to Photos follows them too.
    let metadata: MetadataEdits
    @Published private(set) var state: State = .running(progress: 0)
    /// Size limit of a "Fit in" export, to show whether it fits.
    private(set) var targetFileSize: Int64?
    /// e.g. "Encoded with hardware HEVC", for re-encodes.
    @Published private(set) var encoderNote: String?
    /// iOS 26+: the export may continue if the user leaves FootBrake.
    @Published private(set) var runsInBackground = false
    private var backgroundTask: AnyObject?
    private var stoppedByIOS = false
    private var task: Task<Void, Never>?
    /// Re-runs the last export with the same settings (for Try Again).
    private var restart: (() -> Void)?
    private var wentToBackground = false
    private var backgroundObserver: AnyCancellable?

    init(source: SourceVideo, metadata: MetadataEdits = .none) {
        self.source = source
        self.metadata = metadata
        // iOS stops the hardware encoder when the app leaves the screen; note
        // it so a resulting failure can be explained.
        backgroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if case .running = self?.state { self?.wentToBackground = true }
            }
    }

    func retry() {
        restart?()
    }

    /// "Copying…" or "Encoding…", shown while running.
    private(set) var activity = "Copying…"

    func startCopy(range: CMTimeRange, mode: CopyCutMode, wholeFile: Bool) {
        activity = "Copying…"
        let metadata = metadata
        run(suffix: wholeFile ? "copy" : "trimmed", fileType: CopyExporter.fileType(for: source.url)) { source, output, progress in
            try await CopyExporter.export(source: source, range: range, mode: mode, metadata: metadata,
                                          to: output, progress: progress)
            return nil
        }
    }

    func startShrinkAudio(range: CMTimeRange, mode: CopyCutMode, audioBitRate: Int) {
        activity = "Shrinking audio…"
        let metadata = metadata
        run(suffix: "smaller audio", fileType: CopyExporter.fileType(for: source.url)) { source, output, progress in
            try await AudioReencoder.export(source: source, range: range, mode: mode, audioBitRate: audioBitRate,
                                            metadata: metadata, to: output, progress: progress)
            return nil
        }
    }

    func startTranscode(range: CMTimeRange, settings: TranscodeSettings, suffix: String) {
        activity = "Encoding…"
        targetFileSize = settings.targetFileSize
        let settings = { var s = settings; s.metadata = metadata; return s }()
        run(suffix: suffix, fileType: settings.container == .mov ? .mov : .mp4, usesGPU: true) { source, output, progress in
            let result = try await Transcoder.transcode(source: source, range: range, settings: settings,
                                                        to: output, progress: progress)
            let codec = settings.codec == .hevc ? "HEVC" : "H.264"
            return result.usedHardwareEncoder.map { $0 ? "Encoded with hardware \(codec)" : "Encoded in software (\(codec))" }
        }
    }

    /// `usesGPU`: re-encodes rotate and scale on the GPU, so they can only
    /// continue in the background where iOS allows background GPU work.
    private func run(suffix: String, fileType: AVFileType, usesGPU: Bool = false,
                     work: @escaping @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> String?) {
        let source = source
        restart = { [weak self] in self?.run(suffix: suffix, fileType: fileType, usesGPU: usesGPU, work: work) }
        state = .running(progress: 0)
        wentToBackground = false
        stoppedByIOS = false
        startBackgroundTask(title: "Exporting \(source.info.fileName)", usesGPU: usesGPU)
        // Exports can take minutes; don't let the screen lock part-way.
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let began = Date()
            do {
                OutputStore.removeAll()
                let output = try OutputStore.url(for: source.url, suffix: suffix, fileType: fileType)
                encoderNote = try await work(source.url, output) { p in
                    Task { @MainActor in
                        if case .running = self.state { self.state = .running(progress: p) }
                        self.updateBackgroundTask(progress: p)
                    }
                }
                let info = try await MediaProbe.probe(output)
                state = .finished(url: output, info: info, seconds: Date().timeIntervalSince(began))
                finishBackgroundTask(success: true)
            } catch is CancellationError {
                finishBackgroundTask(success: false)
                if stoppedByIOS { state = .failed(.stoppedByIOS) }
            } catch {
                finishBackgroundTask(success: false)
                // With a background task running, leaving the app isn't the cause.
                state = .failed(ExportFailure(error, wentToBackground: wentToBackground && !runsInBackground))
            }
        }
    }

    // MARK: - Background task (iOS 26+)

    private func startBackgroundTask(title: String, usesGPU: Bool) {
        backgroundTask = nil
        runsInBackground = false
        guard #available(iOS 26, *), !usesGPU || BackgroundExportTask.supportsBackgroundGPU else { return }
        let task = BackgroundExportTask(title: title, subtitle: activity) { [weak self] in
            self?.stoppedByIOS = true
            self?.cancel()
        }
        backgroundTask = task
        runsInBackground = task != nil
    }

    private func updateBackgroundTask(progress: Double) {
        guard #available(iOS 26, *) else { return }
        (backgroundTask as? BackgroundExportTask)?.update(progress: progress)
    }

    private func finishBackgroundTask(success: Bool) {
        guard #available(iOS 26, *) else { return }
        (backgroundTask as? BackgroundExportTask)?.finish(success: success)
        backgroundTask = nil
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
