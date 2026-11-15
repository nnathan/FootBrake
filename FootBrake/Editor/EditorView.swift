import FootBrakeCore
import SwiftUI

/// Preview, trim and export one source video.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @State private var showingInfo = false
    @State private var exportJob: ExportJob?

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
            LabeledContent("Mode", value: "Copy (no re-encode)")
            Picker("Cut", selection: $model.cutMode) {
                Text("At keyframe").tag(CopyCutMode.keyframe)
                Text("Exact").tag(CopyCutMode.exact)
            }
            .pickerStyle(.segmented)
            if model.cutMode == .keyframe, let keyframe = model.keyframeStart, keyframe < model.start - 0.001 {
                LabeledContent("Starts at", value: "\(Format.duration(keyframe)) (keyframe)")
            }
            LabeledContent("Estimated size", value: "≈ \(Format.bytes(model.estimatedCopySize))")
            Button {
                let job = ExportJob(source: model.source)
                job.startCopy(range: model.selectionRange, mode: model.cutMode, wholeFile: model.isWholeFile)
                exportJob = job
            } label: {
                Text("Export").frame(maxWidth: .infinity).bold()
            }
        } header: {
            Text("Export")
        } footer: {
            Text(model.cutMode == .keyframe
                 ? "Copies every frame untouched. The clip starts at the keyframe at or before your start point, which plays everywhere."
                 : "Copies every frame untouched and starts exactly at your start point. A few websites may show a short freeze at the start.")
        }
    }
}
