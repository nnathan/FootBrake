import FootBrakeCore
import SwiftUI

/// Everything `MediaProbe` found out about a video. Given the original too
/// (for an export), it offers an Export | Original switch and highlights
/// what changed. Missing capture data is shown as "Not in file" rather than
/// hidden, so a removal is visible.
struct SourceInfoView: View {
    let info: MediaInfo
    /// The source, when `info` describes an export of it.
    var original: MediaInfo?
    @Environment(\.dismiss) private var dismiss
    @State private var showingOriginal = false

    var body: some View {
        NavigationStack {
            List {
                if original != nil {
                    Picker("Show", selection: $showingOriginal) {
                        Text("Export").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                ForEach(sections(for: shown)) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row, previous: comparison?.value(section: section.id, row: row.id))
                        }
                    } header: {
                        if section.id == "file" { badges(for: shown) } else { Text(section.title) }
                    }
                }
            }
            .navigationTitle(shown.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var shown: MediaInfo { showingOriginal ? original ?? info : info }

    /// Values to compare against: the original's, while showing the export.
    private var comparison: Rows? {
        guard let original, !showingOriginal else { return nil }
        return Rows(sections(for: original))
    }

    // MARK: - Rows

    struct InfoRow: Identifiable {
        let id: String
        let value: String
        var link: URL?
    }

    struct InfoSection: Identifiable {
        let id: String
        let title: String
        let rows: [InfoRow]
    }

    struct Rows {
        let values: [String: String]
        init(_ sections: [InfoSection]) {
            var values: [String: String] = [:]
            for section in sections {
                for row in section.rows { values["\(section.id)/\(row.id)"] = row.value }
            }
            self.values = values
        }
        func value(section: String, row: String) -> String? { values["\(section)/\(row)"] }
    }

    @ViewBuilder
    private func rowView(_ row: InfoRow, previous: String?) -> some View {
        let changed = comparison != nil && previous != row.value
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                if let link = row.link {
                    Link(row.value, destination: link)
                } else {
                    Text(row.value)
                        .foregroundStyle(changed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .fontWeight(changed ? .semibold : .regular)
                }
                if changed {
                    Text("was \(previous ?? "not shown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        } label: {
            Text(row.id)
        }
    }

    private func sections(for info: MediaInfo) -> [InfoSection] {
        var sections = [InfoSection(id: "file", title: "File", rows: [
            InfoRow(id: "Format", value: Format.containerName(info.containerType)),
            InfoRow(id: "Size", value: Format.bytes(info.fileSize)),
            InfoRow(id: "Duration", value: Format.duration(info.duration)),
            InfoRow(id: "Overall bitrate", value: Format.bitRate(info.overallBitRate)),
            InfoRow(id: "Audio tracks", value: info.audio.isEmpty ? "None" : "\(info.audio.count)"),
        ])]

        if let video = info.video {
            var rows = [
                InfoRow(id: "Codec", value: [video.codecName, video.profile].compactMap { $0 }.joined(separator: " · ")),
                InfoRow(id: "Resolution", value: dimensions(video.displaySize)),
                InfoRow(id: "Stored as", value: video.rotation == 0
                        ? "Upright" : "\(dimensions(video.codedSize)), rotated \(video.rotation)°"),
                InfoRow(id: "Frame rate", value: frameRateText(video)),
                InfoRow(id: "Bitrate", value: Format.bitRate(video.bitRate)),
                InfoRow(id: "Bit depth", value: "\(video.bitDepth)-bit"),
                InfoRow(id: "Dynamic range", value: video.hdrFormat.rawValue),
            ]
            if let primaries = video.colorPrimaries {
                rows.append(InfoRow(id: "Color", value: [primaries, video.transferFunction, video.matrix]
                    .compactMap { $0 }.map(colorName).joined(separator: " / ")))
            }
            sections.append(InfoSection(id: "video", title: "Video", rows: rows))
        }

        for (index, audio) in info.audio.enumerated() {
            var rows = [
                InfoRow(id: "Codec", value: audio.codecName),
                InfoRow(id: "Channels", value: audio.channelLayoutName),
                InfoRow(id: "Sample rate", value: "\(Int(audio.sampleRate)) Hz"),
                InfoRow(id: "Bitrate", value: Format.bitRate(audio.bitRate)),
            ]
            if let language = audio.languageCode {
                rows.append(InfoRow(id: "Language",
                                    value: Locale.current.localizedString(forLanguageCode: language) ?? language))
            }
            sections.append(InfoSection(id: "audio\(index)", title: "Audio \(index + 1)", rows: rows))
        }

        let meta = info.metadata, camera = info.camera
        let notInFile = "Not in file"
        let device = [meta.make, meta.model].compactMap { $0 }.joined(separator: " ")
        sections.append(InfoSection(id: "capture", title: "Capture", rows: [
            InfoRow(id: "Recorded", value: meta.creationDate?.formatted(date: .abbreviated, time: .standard) ?? notInFile),
            meta.location.map { InfoRow(id: "Location", value: Format.coordinate($0), link: mapsURL($0)) }
                ?? InfoRow(id: "Location", value: notInFile),
            InfoRow(id: "Device", value: device.isEmpty ? notInFile : device),
            InfoRow(id: "Software", value: meta.software ?? notInFile),
            InfoRow(id: "Lens details", value: camera.lensModel
                    ?? (camera.trackMetadataCount > 0 ? "\(camera.trackMetadataCount) fields" : notInFile)),
            InfoRow(id: "Camera data", value: camera.timedTracks.isEmpty
                    ? "None" : "\(camera.timedTracks.count) tracks: \(camera.timedTracks.joined(separator: ", "))"),
        ]))
        return sections
    }

    // MARK: - Badges and formatting

    @ViewBuilder
    private func badges(for info: MediaInfo) -> some View {
        let tags = badgeTexts(info)
        if tags.isEmpty {
            Text("File")
        } else {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
            .textCase(nil)
            .padding(.bottom, 8)
        }
    }

    private func badgeTexts(_ info: MediaInfo) -> [String] {
        guard let video = info.video else { return [] }
        var tags: [String] = []
        if video.hdrFormat.isHDR { tags.append(video.hdrFormat.rawValue) }
        if video.isHighFrameRate { tags.append("Slo-mo \(Int(video.nominalFrameRate.rounded())) fps") }
        if video.isPortrait { tags.append("Portrait") }
        return tags
    }

    private func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    private func frameRateText(_ video: VideoTrackInfo) -> String {
        let nominal = Format.frameRate(video.nominalFrameRate)
        // iPhone footage stamps each frame with its real capture time, so the
        // average (nominal) rate is the meaningful number, not the peak.
        return video.isVariableFrameRate ? "\(nominal) · variable" : nominal
    }

    private func colorName(_ value: String) -> String {
        switch value {
        case "ITU_R_709_2": "BT.709"
        case "ITU_R_2020": "BT.2020"
        case "ITU_R_2100_HLG": "HLG"
        case "SMPTE_ST_2084_PQ": "PQ"
        case "P3_D65": "Display P3"
        case "ITU_R_601_4": "BT.601"
        default: value
        }
    }

    private func mapsURL(_ location: GeoLocation) -> URL {
        URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Recorded%20here")!
    }
}
