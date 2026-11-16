import GaussCore
import SwiftUI

/// Preview, trim and export one source video.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @State private var showingInfo = false
    @State private var exportJob: ExportJob?
    @State private var storageAlert: String?
    // Remembered between videos.
    @AppStorage("exportPreset") private var preset: OutputPreset = .original
    @AppStorage("exportCodec") private var codec: VideoCodec = .hevc
    @AppStorage("exportFrameRate") private var frameRateCap = 30
    @AppStorage("exportKeepHDR") private var keepHDR = true
    // Metadata: the removal toggles are remembered; the date choice is per video.
    @AppStorage("metadataRemoveLocation") private var removeLocation = false
    @AppStorage("metadataRemoveDevice") private var removeDeviceInfo = false
    @State private var dateChoice = DateChoice.original
    @State private var customDate = Date()

    enum DateChoice: Hashable { case original, custom, remove }

    /// "Fit in size" limit in MB: one of the preset choices, or 0 for custom.
    @AppStorage("fitSizeChoice") private var fitSizeChoice: Double = 20
    @AppStorage("fitSizeCustomMB") private var fitSizeCustomMB: Double = 40
    /// Which audio track(s) to keep; chosen per video.
    @State private var audioTrack: AudioTrackChoice = .automatic
    /// Audio picker value (0 = keep), remembered per preset in UserDefaults.
    @State private var audioKbps = 0

    init(source: SourceVideo) {
        _model = StateObject(wrappedValue: EditorModel(source: source))
    }

    private var info: MediaInfo { model.source.info }

    var body: some View {
        GeometryReader { geometry in
            editor(playerHeight: min(560, geometry.size.height * 0.45))
        }
    }

    /// The player takes at most 45% of the height (capped at 560 pt), so the
    /// trim controls and settings keep room in every orientation, including
    /// a landscape iPhone.
    private func editor(playerHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.black
                .aspectRatio(playerAspectRatio, contentMode: .fit)
                .overlay(PlayerLayerView(player: model.player))
                .frame(maxWidth: .infinity, maxHeight: playerHeight)
                .background(Color.black)
                .onTapGesture { model.togglePlay() }

            VStack(spacing: 8) {
                TrimTimeline(model: model)
                transport
                markButtons
            }
            // A single row of compact controls: larger text would truncate them.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            // A single row of compact controls: larger text would truncate them.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal)
            .padding(.vertical, 12)

            Form {
                selectionSection
                exportSection
                metadataSection
                exportButtonSection
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(info.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingInfo = true
                } label: {
                    Label("Video Details", systemImage: "info.circle")
                }
            }
            // The number pad (custom size limit) has no Return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .bold()
            }
        }
        .sheet(isPresented: $showingInfo) { SourceInfoView(info: info) }
        .sheet(item: $exportJob) { job in ExportSheet(job: job) }
        .alert("Not Enough Storage", isPresented: .constant(storageAlert != nil)) {
            Button("OK") { storageAlert = nil }
        } message: {
            Text(storageAlert ?? "")
        }
        .onDisappear { model.tearDown() }
        #if DEBUG
        // Simulator testing, with -GaussOpen: `-GaussShowInfo` or `-GaussExport`
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-GaussShowInfo") { showingInfo = true }
            if args.contains("-GaussExport") { startExport() }
        }
        #endif
    }

    private var playerAspectRatio: CGFloat {
        guard let size = info.video?.displaySize, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    // MARK: - Transport

    private var transport: some View {
        HStack {
            Button { model.step(frames: -1) } label: {
                Image(systemName: "backward.frame.fill")
            }
            .accessibilityLabel("Previous frame")
            Spacer()
            Text(Format.duration(model.playhead))
                .monospacedDigit()
                .font(.callout)
            Spacer()
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 32)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play selection")
            Spacer()
            Text("/ \(Format.duration(model.duration))")
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.step(frames: 1) } label: {
                Image(systemName: "forward.frame.fill")
            }
            .accessibilityLabel("Next frame")
        }
        .buttonStyle(.borderless)
    }

    /// Mark-in / mark-out from the playhead, as in video editors.
    private var markButtons: some View {
        HStack(spacing: 12) {
            Button { model.setStartToPlayhead() } label: {
                Label("Set Start", systemImage: "arrow.right.to.line").frame(maxWidth: .infinity)
            }
            Button { model.setEndToPlayhead() } label: {
                Label("Set End", systemImage: "arrow.left.to.line").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Sections

    private var selectionSection: some View {
        Section {
            pointRow("Start", value: model.start, set: model.setStart, nudge: model.nudgeStart)
            pointRow("End", value: model.end, set: model.setEnd, nudge: model.nudgeEnd)
            LabeledContent("Length", value: Format.duration(model.end - model.effectiveStart))
        } header: {
            Text("Selection")
        } footer: {
            Text("Drag the yellow handles, type a time, or use \(Image(systemName: "chevron.left")) \(Image(systemName: "chevron.right")) to move a point by one frame.")
        }
    }

    private func pointRow(_ title: String, value: Double, set: @escaping (Double) -> Double,
                          nudge: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Button { nudge(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }
            .accessibilityLabel("\(title) one frame earlier")
            TimeField(title: title, value: value, commit: set)
                .fixedSize()
            Button { nudge(1) } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 32)
            }
            .accessibilityLabel("\(title) one frame later")
        }
        .buttonStyle(.borderless)
    }

    private var exportSection: some View {
        Section {
            Picker("Preset", selection: $preset) {
                ForEach(availablePresets) { Text($0.title).tag($0) }
            }
            .onChange(of: preset) { newPreset in
                codec = newPreset.defaultCodec
                audioKbps = storedAudioKbps(for: newPreset)
            }
            .onAppear { audioKbps = storedAudioKbps(for: preset) }

            if preset == .copy {
                copyOptions
            } else {
                transcodeOptions
            }
            audioOptions
        } header: {
            Text("Export")
        } footer: {
            Text(footerText)
        }
    }

    private var exportButtonSection: some View {
        Section {
            Button(action: startExport) {
                Text("Export").frame(maxWidth: .infinity).bold()
            }
        }
    }

    private func startExport() {
        if let shortfall = storageShortfall {
            storageAlert = shortfall
            return
        }
        let job = ExportJob(source: model.source, metadata: metadataEdits)
        switch (preset, audioKbps) {
        case (.copy, 0):
            job.startCopy(range: model.selectionRange, mode: model.cutMode, audioTrack: effectiveAudioTrack,
                          wholeFile: model.isWholeFile)
        case (.copy, let kbps):
            job.startShrinkAudio(range: model.selectionRange, mode: model.cutMode, audioBitRate: kbps * 1000,
                                 audioTrack: effectiveAudioTrack)
        default:
            job.startTranscode(range: model.selectionRange, settings: transcodeSettings,
                               suffix: exportSuffix)
        }
        exportJob = job
    }

    /// A message if the estimated output (plus a 20% + 50 MB margin) won't fit.
    private var storageShortfall: String? {
        let needed = Int64(Double(estimatedSize) * 1.2) + 50_000_000
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free < needed else { return nil }
        return "This export needs about \(Format.approximateBytes(needed)), but only \(Format.bytes(free)) is free. "
            + "Free up space in Settings › General › \(UIDevice.current.model) Storage, or trim the video or pick a smaller preset."
    }

    // MARK: - Metadata

    private var capture: CaptureMetadata { info.metadata }
    private var hasDeviceInfo: Bool { capture.make != nil || capture.model != nil || capture.software != nil }

    private var metadataEdits: MetadataEdits {
        let date: DateEdit = switch dateChoice {
        case .original: .original
        case .custom: .custom(customDate)
        case .remove: .remove
        }
        return MetadataEdits(removeLocation: removeLocation && capture.location != nil,
                             removeDeviceInfo: removeDeviceInfo && hasDeviceInfo, date: date)
    }

    private var metadataSection: some View {
        Section {
            if let location = capture.location {
                Toggle(isOn: $removeLocation) {
                    detailLabel("Remove location", detail: Format.coordinate(location))
                }
            }
            if hasDeviceInfo {
                Toggle(isOn: $removeDeviceInfo) {
                    detailLabel("Remove device info", detail: deviceDescription)
                }
            }
            Picker("Recording date", selection: $dateChoice) {
                Text("Original").tag(DateChoice.original)
                Text("Custom").tag(DateChoice.custom)
                Text("Remove").tag(DateChoice.remove)
            }
            .pickerStyle(.segmented)
            .onChange(of: dateChoice) { choice in
                if choice == .custom { customDate = capture.creationDate ?? Date() }
            }
            switch dateChoice {
            case .original:
                LabeledContent("Recorded", value: capture.creationDate
                    .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not in file")
            case .custom:
                DatePicker("Recorded", selection: $customDate)
            case .remove:
                Text("Photos will show it as taken when you save it. The file still notes when it was exported, but not when it was recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Metadata")
        } footer: {
            Text("Lens details and camera data such as detected faces are never included in re-encoded videos, "
                 + "and are left out of copies when you remove anything. Save to Photos follows these choices.")
        }
    }

    private var deviceDescription: String {
        let device = [capture.make, capture.model].compactMap { $0 }.joined(separator: " ")
        return [device.isEmpty ? nil : device, capture.software.map { "iOS \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func detailLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Presets that would actually shrink this video (plus Copy and Original).
    private var availablePresets: [OutputPreset] {
        let short = info.video.map { Double(min($0.displaySize.width, $0.displaySize.height)) } ?? 1080
        return OutputPreset.allCases.filter { $0.reducesSize(ofShortSide: short) }
    }

    @ViewBuilder
    private var copyOptions: some View {
        Picker("Cut", selection: $model.cutMode) {
            Text("At keyframe").tag(CopyCutMode.keyframe)
            Text("Exact").tag(CopyCutMode.exact)
        }
        .pickerStyle(.segmented)
        if model.cutMode == .keyframe, let keyframe = model.keyframeStart, keyframe < model.start - 0.001 {
            LabeledContent("Starts at", value: "\(Format.duration(keyframe)) (keyframe)")
        }
    }

    @ViewBuilder
    private var transcodeOptions: some View {
        Picker("Codec", selection: $codec) {
            Text("HEVC").tag(VideoCodec.hevc)
            Text("H.264").tag(VideoCodec.h264)
        }
        .pickerStyle(.segmented)
        if sourceAbove30 {
            Picker("Frame rate", selection: $frameRateCap) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
        } else {
            // Frame rates are only ever capped, never raised, so there's no choice to make.
            LabeledContent("Frame rate", value: "\(Format.frameRate(info.video?.nominalFrameRate ?? 30)) (same as source)")
        }
        if sourceIsHDR && codec == .hevc {
            Toggle("Keep HDR", isOn: $keepHDR)
        }
        if preset == .fitSize {
            // A labelled menu row: segmented pickers in a form hide their label.
            Picker("Size limit", selection: $fitSizeChoice) {
                // Hint on the same line: menu pickers drop second lines on some iOS versions.
                ForEach(OutputPreset.fitSizeChoices, id: \.self) { mb in
                    Text("\(Int(mb)) MB · \(OutputPreset.fitSizeHint(mb))").tag(mb)
                }
                Text("Custom…").tag(0.0)
            }
            .pickerStyle(.menu)
            .onAppear {
                // A remembered size that's no longer a choice becomes a custom one.
                if fitSizeChoice != 0 && !OutputPreset.fitSizeChoices.contains(fitSizeChoice) {
                    fitSizeCustomMB = fitSizeChoice
                    fitSizeChoice = 0
                }
            }
            if fitSizeChoice == 0 {
                LabeledContent("Custom limit") {
                    HStack(spacing: 4) {
                        TextField("MB", value: $fitSizeCustomMB, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: fitSizeCustomMB) { value in
                    let range = OutputPreset.fitSizeRange
                    if !range.contains(value) { fitSizeCustomMB = min(max(value, range.lowerBound), range.upperBound) }
                }
            }
        }
        let plan = model.plan(for: transcodeSettings)
        LabeledContent("Output", value: outputDescription(plan))
        if plan.isStarved {
            Label("Too long to look good at this size. Trim it, or use a bigger limit.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        if !model.isHardware(codec) {
            Label("Software encoding: much slower and uses more battery", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var audioOptions: some View {
        if !info.audio.isEmpty {
            Picker("Audio track", selection: audioTrackSelection) {
                if offersAllTracks {
                    Text("All tracks").tag(AudioTrackChoice.automatic)
                }
                ForEach(info.audio.indices, id: \.self) { index in
                    Text(trackLabel(index)).tag(AudioTrackChoice.track(index))
                }
                Text("No audio").tag(AudioTrackChoice.none)
            }
        }
        if effectiveAudioTrack != .none && !info.audio.isEmpty {
            Picker("Audio quality", selection: $audioKbps) {
                ForEach(AudioPlan.kbpsChoices, id: \.self) { Text(AudioPlan.kbpsLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: audioKbps) { UserDefaults.standard.set($0, forKey: audioKey(preset)) }
        }
        if preset == .fitSize, let limit = transcodeSettings.targetFileSize {
            LabeledContent("Estimated size", value: "≈ \(Format.approximateBytes(estimatedSize)) (limit \(Format.bytes(limit)))")
        } else {
            LabeledContent("Estimated size", value: "≈ \(Format.approximateBytes(estimatedSize))")
        }
    }

    /// "All tracks" only makes sense for a lossless copy of a multi-track file.
    private var offersAllTracks: Bool {
        preset == .copy && audioKbps == 0 && info.audio.count > 1
    }

    private var isLosslessCopy: Bool { preset == .copy && audioKbps == 0 }

    /// The choice the export uses. "Automatic" keeps every track in a lossless
    /// copy and the main track otherwise; picking the only track of a
    /// single-track file in a lossless copy is the same as automatic, so it
    /// doesn't needlessly switch to the remux path.
    private var effectiveAudioTrack: AudioTrackChoice {
        switch audioTrack {
        case .automatic where !isLosslessCopy:
            return AudioTrackChoice.mainIndex(info.audio).map { .track($0) } ?? .none
        case .track where isLosslessCopy && info.audio.count == 1:
            return .automatic
        default:
            return audioTrack
        }
    }

    /// What the picker shows: always one of its listed options.
    private var audioTrackSelection: Binding<AudioTrackChoice> {
        Binding(get: {
            if audioTrack == .automatic && !offersAllTracks {
                return AudioTrackChoice.mainIndex(info.audio).map { .track($0) } ?? .none
            }
            return audioTrack
        }, set: { audioTrack = $0 })
    }

    private func trackLabel(_ index: Int) -> String {
        let track = info.audio[index]
        var label = track.codecFourCC == "apac"
            ? "Spatial audio (\(track.channels)-channel)"
            : "\(track.channelLayoutName) \(track.codecName), \(Format.bitRate(track.bitRate))"
        if let language = track.languageCode {
            label += " · " + (Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        return label
    }

    private var estimatedSize: Int64 {
        let track = effectiveAudioTrack
        switch (preset, audioKbps) {
        case (.copy, 0) where track == .automatic:
            return model.estimatedCopySize
        case (.copy, 0):
            let kept = track.singleTrack(in: info.audio).map { info.audio[$0].bitRate } ?? 0
            return model.estimatedRemuxSize(keptAudioBitRate: track == .none ? 0 : kept)
        case (.copy, let kbps):
            return model.estimatedShrinkAudioSize(audioBitRate: track == .none ? 0 : kbps * 1000)
        default:
            return model.estimatedSize(for: model.plan(for: transcodeSettings))
        }
    }

    private func audioKey(_ preset: OutputPreset) -> String { "exportAudioKbps.\(preset.rawValue)" }

    private func storedAudioKbps(for preset: OutputPreset) -> Int {
        UserDefaults.standard.object(forKey: audioKey(preset)) as? Int ?? preset.defaultAudioKbps
    }

    private var fitSizeMB: Double { fitSizeChoice == 0 ? fitSizeCustomMB : fitSizeChoice }

    /// File-name suffix, e.g. "720p" or, for Fit in size, "25MB".
    private var exportSuffix: String {
        guard preset == .fitSize else { return preset.fileSuffix }
        return fitSizeMB.formatted(.number.precision(.fractionLength(0...1))) + "MB"
    }

    private var transcodeSettings: TranscodeSettings {
        var settings = preset.settings(codec: codec, frameRateCap: frameRateCap, keepHDR: keepHDR, audioKbps: audioKbps,
                                       fitSizeMB: fitSizeMB)
        settings.audioTrack = effectiveAudioTrack
        #if DEBUG
        settings.forceSoftwareEncoder = UserDefaults.standard.bool(forKey: DebugSettings.simulateSoftwareEncoders)
        #endif
        return settings
    }

    private var sourceAbove30: Bool { (info.video?.nominalFrameRate ?? 0) > 31 }
    private var sourceIsHDR: Bool { info.video?.hdrFormat.isHDR ?? false }

    private func outputDescription(_ plan: TranscodePlan) -> String {
        let size = "\(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height))"
        let range = plan.hdr.isHDR ? " HDR" : ""
        return "\(size) · \(plan.settings.codec == .hevc ? "HEVC" : "H.264")\(range) · \(Format.frameRate(plan.frameRate))"
    }

    private var footerText: String {
        var notes: [String] = []
        if preset == .copy {
            notes.append(model.cutMode == .keyframe
                ? "Copies the video untouched. The clip starts at the keyframe at or before your start point, which plays everywhere."
                : "Copies the video untouched and starts exactly at your start point. A few websites may show a short freeze at the start.")
            if audioKbps > 0 && effectiveAudioTrack != .none {
                notes.append("Only the chosen audio track is re-encoded; other tracks, lens details and camera data are left out.")
            } else if audioKbps == 0 && effectiveAudioTrack != .automatic {
                notes.append("Other audio tracks, lens details and camera data are left out; the rest is copied untouched.")
            }
        } else {
            notes.append(codec == .hevc
                ? "HEVC gives the smallest files and plays on Apple devices and most modern phones and browsers."
                : "H.264 plays everywhere, at roughly 1.5× the size of HEVC.")
            let other: VideoCodec = codec == .hevc ? .h264 : .hevc
            if !model.isHardware(codec) {
                notes.append(model.isHardware(other)
                    ? "This device has no hardware encoder for \(codec.displayName); \(other.displayName) would be much faster."
                    : "This device has no hardware video encoder available, so exports will be slow.")
            }
            if preset == .fitSize, let limit = transcodeSettings.targetFileSize {
                if Double(estimatedSize) < Double(limit) * 0.8 {
                    notes.append("This clip fits comfortably at full quality, so the file will be smaller than "
                        + "\(Format.bytes(limit)) rather than padded to the limit.")
                } else {
                    notes.append("The size is chosen from the length so the file stays under \(Format.bytes(limit)); "
                        + "if it comes out over, Gauss re-encodes once at a lower bitrate.")
                }
            }
            if sourceIsHDR && (codec == .h264 || !keepHDR) {
                notes.append("HDR will be converted to standard range, so it looks right on any screen.")
            }
        }
        if effectiveAudioTrack == .none && !info.audio.isEmpty {
            notes.append("The exported video will have no sound.")
        } else if audioKbps > 0 {
            notes.append("Audio is never made larger than the original: if it's already at or below "
                + "\(audioKbps) kbps, it's kept as is.")
        }
        return notes.joined(separator: " ")
    }
}
