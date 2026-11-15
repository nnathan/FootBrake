import AVFoundation

/// How a 1:1 copy handles a start point that isn't on a keyframe.
public enum CopyCutMode: String, CaseIterable, Sendable, Codable {
    /// Move the start back to the previous keyframe. Every player handles it.
    case keyframe
    /// Keep the exact start: the GOP prefix is stored and hidden with an edit
    /// list. Apple players honour this; a few web uploaders don't.
    case exact
}

public enum CopyExportError: Error, LocalizedError {
    case cannotCreateSession
    case unsupportedFileType

    public var errorDescription: String? {
        switch self {
        case .cannotCreateSession: "This video can't be copied without re-encoding."
        case .unsupportedFileType: "This video can't be copied into its original format."
        }
    }
}

public enum KeyframeLocator {
    /// Presentation time of the last sync sample at or before `time` in the
    /// video track, found from the sample table without decoding anything.
    /// Returns `time` unchanged if the file can't provide sample cursors.
    public static func keyframe(atOrBefore time: CMTime, in url: URL) async throws -> CMTime {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              try await track.load(.canProvideSampleCursors)
        else { return time }

        // Sample cursors work in media time; the trim range is in track
        // (presentation) time. Edit lists, e.g. the B-frame delay ffmpeg and
        // the iPhone camera write, make the two differ.
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        guard let segment = segments.last(where: { $0.timeMapping.target.start <= time }) ?? segments.first,
              let cursor = track.makeSampleCursor(presentationTimeStamp: toMedia(time, segment))
        else { return time }

        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
        }
        let keyframe = toTrack(cursor.presentationTimeStamp, segment)
        return CMTimeMaximum(.zero, CMTimeMinimum(keyframe, time))
    }

    private static func toMedia(_ time: CMTime, _ segment: AVAssetTrackSegment) -> CMTime {
        segment.timeMapping.source.start + (time - segment.timeMapping.target.start)
    }

    private static func toTrack(_ time: CMTime, _ segment: AVAssetTrackSegment) -> CMTime {
        segment.timeMapping.target.start + (time - segment.timeMapping.source.start)
    }
}

/// Trims a video without re-encoding: every track (video, all audio including
/// spatial audio, timed metadata) and the file's capture metadata are copied
/// sample-for-sample.
public enum CopyExporter {
    /// The output container FootBrake uses for a copy of `source`.
    public static func fileType(for source: URL) -> AVFileType {
        switch source.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    public static func export(
        source: URL,
        range: CMTimeRange,
        mode: CopyCutMode,
        metadata edits: MetadataEdits = .none,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        // Apple's export session copies lens details and timed camera tracks
        // it can't edit, so removing data goes through FootBrake's own
        // lossless remux instead (same samples, camera data left out).
        if edits.dropsCameraData {
            try await AudioReencoder.export(source: source, range: range, mode: mode, audioBitRate: nil,
                                            metadata: edits, to: output, progress: progress)
            return
        }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CopyExportError.cannotCreateSession
        }
        let fileType = fileType(for: source)
        guard session.supportedFileTypes.contains(fileType) else { throw CopyExportError.unsupportedFileType }

        var timeRange = range
        if mode == .keyframe {
            let start = try await KeyframeLocator.keyframe(atOrBefore: range.start, in: source)
            timeRange = CMTimeRange(start: start, end: range.end)
        }
        session.timeRange = timeRange
        session.metadata = edits.apply(to: try await asset.load(.metadata))
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)

        if #available(iOS 18, macOS 15, *) {
            // The states sequence is designed to be observed while export runs.
            nonisolated(unsafe) let observed = session
            let monitor = Task {
                for await state in observed.states(updateInterval: 0.1) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { monitor.cancel() }
            try await session.export(to: output, as: fileType)
        } else {
            try await legacyExport(session, to: output, as: fileType, progress: progress)
        }
        progress(1)
    }

    /// iOS 16–17: callback-based export with polled progress.
    private static func legacyExport(
        _ session: AVAssetExportSession, to output: URL, as fileType: AVFileType,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        nonisolated(unsafe) let session = session
        session.outputURL = output
        session.outputFileType = fileType
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler { @Sendable in
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }
        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw session.error ?? CopyExportError.cannotCreateSession
        }
    }
}
