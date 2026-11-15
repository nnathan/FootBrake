import FootBrakeCore
import SwiftUI

/// Preview, trim and export one source video.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @State private var showingInfo = false
    @State private var exportJob: ExportJob?
    // Remembered between videos.
    @AppStorage("exportPreset") private var preset: OutputPreset = .original
    @AppStorage("exportCodec") private var codec: VideoCodec = .hevc
    @AppStorage("exportFrameRate") private var frameRateCap = 30
    @AppStorage("exportKeepHDR") private var keepHDR = true
    /// Audio picker value (0 = keep), remembered per preset in UserDefaults.
    @State private var audioKbps = 0

    init(source: SourceVideo) {
        _model = StateObject(wrappedValue: EditorModel(source: source))
    }

    private var info: MediaInfo { model.source.info }

    var body: some View {
        VStack(spacing: 0) {
            Color.black
                .aspectRatio(playerAspectRatio, contentMode: .fit)
                .overlay(PlayerLayerView(player: model.player))
                .frame(maxWidth: .infinity, maxHeight: 360)
                .background(Color.black)
                .onTapGesture { model.togglePlay() }

            VStack(spacing: 8) {
                TrimTimeline(model: model)
                transport
                markButtons
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Form {
                selectionSection
                exportSection
            }
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
        }
        .sheet(isPresented: $showingInfo) { SourceInfoView(info: info) }
        .sheet(item: $exportJob) { job in ExportSheet(job: job) }
        .onDisappear { model.tearDown() }
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

            Button {
                let job = ExportJob(source: model.source)
                switch (preset, audioKbps) {
                case (.copy, 0):
                    job.startCopy(range: model.selectionRange, mode: model.cutMode, wholeFile: model.isWholeFile)
                case (.copy, let kbps):
                    job.startShrinkAudio(range: model.selectionRange, mode: model.cutMode, audioBitRate: kbps * 1000)
                default:
                    job.startTranscode(range: model.selectionRange, settings: transcodeSettings,
                                       suffix: preset.fileSuffix)
                }
                exportJob = job
            } label: {
                Text("Export").frame(maxWidth: .infinity).bold()
            }
        } header: {
            Text("Export")
        } footer: {
            Text(footerText)
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
        LabeledContent("Output", value: outputDescription(model.plan(for: transcodeSettings)))
        if !model.isHardware(codec) {
            Label("Software encoding: much slower and uses more battery", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var audioOptions: some View {
        Picker("Audio", selection: $audioKbps) {
            Text("Keep").tag(0)
            Text("64k").tag(64)
            Text("96k").tag(96)
            Text("128k").tag(128)
        }
        .pickerStyle(.segmented)
        .onChange(of: audioKbps) { UserDefaults.standard.set($0, forKey: audioKey(preset)) }
        if let audio = mainAudio {
            LabeledContent("Audio now", value: "\(audio.codecName) \(audio.channelLayoutName), \(Format.bitRate(audio.bitRate))")
        }
        LabeledContent("Estimated size", value: "≈ \(Format.approximateBytes(estimatedSize))")
    }

    private var estimatedSize: Int64 {
        switch (preset, audioKbps) {
        case (.copy, 0): model.estimatedCopySize
        case (.copy, let kbps): model.estimatedShrinkAudioSize(audioBitRate: kbps * 1000)
        default: model.estimatedSize(for: model.plan(for: transcodeSettings))
        }
    }

    private var mainAudio: AudioTrackInfo? {
        info.audio.first { $0.codecFourCC == "aac " } ?? info.audio.first
    }

    private func audioKey(_ preset: OutputPreset) -> String { "exportAudioKbps.\(preset.rawValue)" }

    private func storedAudioKbps(for preset: OutputPreset) -> Int {
        UserDefaults.standard.object(forKey: audioKey(preset)) as? Int ?? preset.defaultAudioKbps
    }

    private var transcodeSettings: TranscodeSettings {
        var settings = preset.settings(codec: codec, frameRateCap: frameRateCap, keepHDR: keepHDR, audioKbps: audioKbps)
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
            if audioKbps > 0 {
                notes.append("Only the main audio track is re-encoded; spatial audio and other extra tracks are left out.")
            }
        } else {
            notes.append(codec == .hevc
                ? "HEVC gives the smallest files and plays on Apple devices and most modern phones and browsers."
                : "H.264 plays everywhere, at roughly 1.5× the size of HEVC.")
            let other: VideoCodec = codec == .hevc ? .h264 : .hevc
            if !model.isHardware(codec) {
                notes.append(model.isHardware(other)
                    ? "This iPhone has no hardware encoder for \(codec.displayName); \(other.displayName) would be much faster."
                    : "This iPhone has no hardware video encoder available, so exports will be slow.")
            }
            if sourceIsHDR && (codec == .h264 || !keepHDR) {
                notes.append("HDR will be converted to standard range, so it looks right on any screen.")
            }
        }
        if audioKbps > 0 { notes.append("64k suits speech; 128k suits music.") }
        return notes.joined(separator: " ")
    }
}
