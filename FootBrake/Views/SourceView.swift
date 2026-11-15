import AVKit
import FootBrakeCore
import SwiftUI

/// Plays a source video and shows everything `MediaProbe` found out about it.
struct SourceView: View {
    let source: SourceVideo
    @State private var player: AVPlayer

    init(source: SourceVideo) {
        self.source = source
        _player = State(initialValue: AVPlayer(url: source.url))
    }

    private var info: MediaInfo { source.info }

    var body: some View {
        ScrollViewReader { proxy in
            list
            #if DEBUG
            // Simulator testing: `-FBScrollToBottom` shows the last sections.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-FBScrollToBottom") {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            #endif
        }
        .navigationTitle(info.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.pause() }
    }

    private var list: some View {
        List {
            Section {
                VideoPlayer(player: player)
                    .aspectRatio(playerAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 440)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.black)
            } footer: {
                badges
            }

            Section("File") {
                LabeledContent("Format", value: Format.containerName(info.containerType))
                LabeledContent("Size", value: Format.bytes(info.fileSize))
                LabeledContent("Duration", value: Format.duration(info.duration))
                LabeledContent("Overall bitrate", value: Format.bitRate(info.overallBitRate))
            }

            if let video = info.video {
                videoSection(video)
            }

            ForEach(Array(info.audio.enumerated()), id: \.offset) { index, audio in
                audioSection(audio, number: index + 1)
            }

            captureSection
            Color.clear.frame(height: 0).listRowBackground(Color.clear).id("bottom")
        }
    }

    private var playerAspectRatio: CGFloat {
        guard let size = info.video?.displaySize, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    // MARK: - Sections

    private func videoSection(_ video: VideoTrackInfo) -> some View {
        Section("Video") {
            LabeledContent("Codec", value: [video.codecName, video.profile].compactMap { $0 }.joined(separator: " · "))
            LabeledContent("Resolution", value: dimensions(video.displaySize))
            if video.rotation != 0 {
                LabeledContent("Stored as", value: "\(dimensions(video.codedSize)), rotated \(video.rotation)°")
            }
            LabeledContent("Frame rate", value: frameRateText(video))
            LabeledContent("Bitrate", value: Format.bitRate(video.bitRate))
            LabeledContent("Bit depth", value: "\(video.bitDepth)-bit")
            LabeledContent("Dynamic range", value: video.hdrFormat.rawValue)
            if let primaries = video.colorPrimaries {
                LabeledContent("Color", value: [primaries, video.transferFunction, video.matrix]
                    .compactMap { $0 }.map(colorName).joined(separator: " / "))
            }
        }
    }

    private func audioSection(_ audio: AudioTrackInfo, number: Int) -> some View {
        Section(info.audio.count > 1 ? "Audio \(number)" : "Audio") {
            LabeledContent("Codec", value: audio.codecName)
            LabeledContent("Channels", value: audio.channelLayoutName)
            LabeledContent("Sample rate", value: "\(Int(audio.sampleRate)) Hz")
            LabeledContent("Bitrate", value: Format.bitRate(audio.bitRate))
            if let language = audio.languageCode {
                LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: language) ?? language)
            }
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        let meta = info.metadata
        if meta.creationDate != nil || meta.location != nil || meta.model != nil {
            Section("Capture") {
                if let date = meta.creationDate {
                    LabeledContent("Recorded", value: date.formatted(date: .abbreviated, time: .standard))
                }
                if let location = meta.location {
                    LabeledContent("Location") {
                        Link(Format.coordinate(location), destination: mapsURL(location))
                    }
                }
                if let model = meta.model {
                    LabeledContent("Device", value: [meta.make, model].compactMap { $0 }.joined(separator: " "))
                }
                if let software = meta.software {
                    LabeledContent("Software", value: software)
                }
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        let tags = badgeTexts
        if !tags.isEmpty {
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
            .padding(.top, 8)
        }
    }

    private var badgeTexts: [String] {
        guard let video = info.video else { return [] }
        var tags: [String] = []
        if video.hdrFormat.isHDR { tags.append(video.hdrFormat.rawValue) }
        if video.isHighFrameRate { tags.append("Slo-mo \(Int(video.nominalFrameRate.rounded())) fps") }
        if video.isPortrait { tags.append("Portrait") }
        return tags
    }

    // MARK: - Formatting

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
