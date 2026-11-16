#if DEBUG
import GaussCore
import PhotosUI
import SwiftUI

/// Debug-only: encodes one clip across codecs, sizes, rate-control modes and
/// bitrate multipliers, plus a near-lossless reference for each codec/size,
/// writing everything and `results.csv` to Documents/Measurements/<clip>/.
/// Pull it with `devicectl` and score on the Mac with Tools/score-device.sh.
struct MeasurementView: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var source: URL?
    @State private var info: MediaInfo?
    @State private var log: [String] = []
    @State private var progress: (done: Int, total: Int)?
    @State private var task: Task<Void, Never>?
    @State private var storedSize = MeasurementView.folderSize()

    static let root = URL.documentsDirectory.appendingPathComponent("Measurements", isDirectory: true)

    static func folderSize() -> Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static let multipliers = [0.5, 0.75, 1, 1.5]
    static let sizes = [1080, 720, 480]

    var body: some View {
        List {
            Section {
                PhotosPicker("Choose clip", selection: $photoItem, matching: .videos, preferredItemEncoding: .current)
                if let info {
                    LabeledContent("Clip", value: info.fileName)
                    LabeledContent("Duration", value: Format.duration(info.duration))
                    LabeledContent("Encodes", value: "\(jobs(for: info).count)")
                }
            }
            Section {
                if task == nil {
                    Button("Run measurement") { start() }
                        .disabled(source == nil)
                } else {
                    if let progress {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                            Text("\(progress.done) of \(progress.total)")
                        }
                    }
                    Button("Stop", role: .destructive) { task?.cancel() }
                }
            } footer: {
                Text("Keep Gauss open while this runs. Outputs go to Documents/Measurements.")
            }
            Section {
                Button("Delete measurement files", role: .destructive) {
                    try? FileManager.default.removeItem(at: Self.root)
                    log.append("Deleted \(Self.root.lastPathComponent).")
                    storedSize = Self.folderSize()
                }
                .disabled(task != nil)
            } footer: {
                Text("Stored: \(Format.bytes(storedSize))")
            }
            Section("Log") {
                ForEach(Array(log.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Measurement run")
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                guard let movie = try? await item.loadTransferable(type: ImportedMovie.self) else { return }
                source = movie.url
                info = try? await MediaProbe.probe(movie.url)
            }
        }
    }

    private struct Job {
        let name: String
        let settings: TranscodeSettings
        let targetBitRate: Int?
    }

    private func jobs(for info: MediaInfo) -> [Job] {
        let short = info.video.map { Double(min($0.displaySize.width, $0.displaySize.height)) } ?? 1080
        var jobs: [Job] = []
        for codec in [VideoCodec.hevc, .h264] {
            for size in Self.sizes where Double(size) < short {
                let base = TranscodeSettings(codec: codec, maxShortSide: size, frameRateCap: 30,
                                             keepHDR: codec == .hevc, audio: .none)
                var reference = base
                reference.rateControl = .fixedQuality(1.0)
                jobs.append(Job(name: "\(codec.rawValue)-\(size)-ref", settings: reference, targetBitRate: nil))

                guard case .averageBitRate(let defaultBps) = TranscodePlan(source: info, settings: base).rateControl
                else { continue }
                for mode in ["vbr", "abr"] {
                    for multiplier in Self.multipliers {
                        let bps = Int(Double(defaultBps) * multiplier)
                        var settings = base
                        settings.rateControl = mode == "vbr" ? .variableBitRate(bps) : .averageBitRate(bps)
                        jobs.append(Job(name: "\(codec.rawValue)-\(size)-\(mode)-\(multiplier)",
                                        settings: settings, targetBitRate: bps))
                    }
                }
            }
        }
        return jobs
    }

    private func start() {
        guard let source, let info else { return }
        let jobs = jobs(for: info)
        let folder = Self.root.appendingPathComponent(source.deletingPathExtension().lastPathComponent, isDirectory: true)
        UIApplication.shared.isIdleTimerDisabled = true
        progress = (0, jobs.count)
        log = []
        task = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                task = nil
            }
            do {
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("source." + source.pathExtension))
                var csv = "name,codec,size,mode,multiplier,target_kbps,video_kbps,file_bytes,encode_s,hardware,width,height\n"
                for (index, job) in jobs.enumerated() {
                    try Task.checkCancellation()
                    let output = folder.appendingPathComponent(job.name + ".mp4")
                    let result = try await Transcoder.transcode(source: source, settings: job.settings, to: output)
                    let out = try await MediaProbe.probe(output)
                    let parts = job.name.split(separator: "-")
                    let mode = parts.count > 2 ? String(parts[2]) : ""
                    let multiplier = parts.count > 3 ? String(parts[3]) : ""
                    csv += [job.name, job.settings.codec.rawValue, String(job.settings.maxShortSide ?? 0), mode, multiplier,
                            job.targetBitRate.map { String($0 / 1000) } ?? "", String(Int((out.video?.bitRate ?? 0) / 1000)),
                            String(out.fileSize), String(format: "%.2f", result.seconds),
                            result.usedHardwareEncoder.map { $0 ? "yes" : "no" } ?? "?",
                            String(Int(result.plan.outputSize.width)), String(Int(result.plan.outputSize.height))]
                        .joined(separator: ",") + "\n"
                    try csv.write(to: folder.appendingPathComponent("results.csv"), atomically: true, encoding: .utf8)
                    log.append("\(job.name): \(Format.bytes(out.fileSize)) in \(String(format: "%.1f", result.seconds)) s")
                    progress = (index + 1, jobs.count)
                }
                log.append("Done: \(folder.path)")
            } catch is CancellationError {
                log.append("Stopped.")
            } catch {
                log.append("Error: \(error.localizedDescription)")
            }
        }
    }
}
#endif
