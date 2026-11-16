import CoreMedia
import GaussCore
import Foundation

// macOS test harness for GaussCore. Runs the same engine code as the iOS
// app so it can be exercised against fixture clips without a device.

/// --no-location, --no-device, --date <ISO 8601 | remove>
func metadataEdits(_ arguments: [String]) -> MetadataEdits {
    var edits = MetadataEdits(removeLocation: arguments.contains("--no-location"),
                              removeDeviceInfo: arguments.contains("--no-device"))
    if let i = arguments.firstIndex(of: "--date"), i + 1 < arguments.count {
        let value = arguments[i + 1]
        if value == "remove" {
            edits.date = .remove
        } else if let date = ISO8601DateFormatter().date(from: value) {
            edits.date = .custom(date)
        }
    }
    return edits
}

/// --audio-track <index | none>; index as listed by `probe` (audio 1 = 0).
func audioTrackChoice(_ arguments: [String]) -> AudioTrackChoice {
    guard let i = arguments.firstIndex(of: "--audio-track"), i + 1 < arguments.count else { return .automatic }
    let value = arguments[i + 1]
    return value == "none" ? .none : Int(value).map { .track($0) } ?? .automatic
}

let usage = """
    gauss-cli \(GaussCore.version)

    usage: gauss-cli <command>

    commands:
      caps            print this machine's VideoToolbox encoder capabilities
      probe <file>... print media info for each file

    copy, shrink-audio and transcode also take:
      --no-location --no-device --date <2026-01-02T03:04:05+11:00 | remove>
      --audio-track <0-based index | none>

      copy <in> <out> --start <time> --end <time> [--exact]
                      trim without re-encoding (default: start at previous keyframe)
      shrink-audio <in> <out> [--kbps <n>] [--start <time>] [--end <time>] [--exact]
                      copy video untouched, re-encode audio to AAC (default 96 kbps)
      transcode <in> <out> [--codec hevc|h264] [--short <px>] [--fps 30|60]
                [--vbr <kbps> | --abr <kbps> | --cq <0-1> | --qp <0-1>] [--sdr]
                [--start <time>] [--end <time>] [--audio <kbps>|0 to keep] [--software] [--fit <MB>]
                      re-encode with the hardware encoder
    """

func printCapabilities() {
    for cap in Capabilities.probe() {
        let flag = { (b: Bool) in b ? "yes" : "no" }
        print("""
            \(cap.codec.displayName)
              available:         \(flag(cap.isAvailable))
              encoder:           \(cap.encoderID ?? "-")
              hardware:          \(flag(cap.isHardwareAccelerated))
              10-bit:            \(flag(cap.supports10Bit))
              constant quality:  \(flag(cap.supportsConstantQuality))
              speed priority:    \(flag(cap.supportsSpeedPriority))
            """)
    }
}

func printMediaInfo(_ info: MediaInfo) {
    print("\(info.fileName)")
    print("  container:   \(Format.containerName(info.containerType)), \(Format.bytes(info.fileSize)), \(Format.bitRate(info.overallBitRate))")
    print("  duration:    \(Format.duration(info.duration))")
    if let v = info.video {
        let size = "\(Int(v.codedSize.width))x\(Int(v.codedSize.height))"
        let display = "\(Int(v.displaySize.width))x\(Int(v.displaySize.height))"
        print("  video:       \(v.codecName) [\(v.codecFourCC)] \(v.profile ?? "?"), \(v.bitDepth)-bit, \(Format.bitRate(v.bitRate))")
        print("  size:        \(size) coded, \(display) displayed, rotation \(v.rotation)°")
        print("  frame rate:  \(Format.frameRate(v.nominalFrameRate)) nominal, \(Format.frameRate(v.peakFrameRate)) peak\(v.isVariableFrameRate ? " (VFR)" : "")")
        print("  color:       \(v.hdrFormat.rawValue); \(v.colorPrimaries ?? "-") / \(v.transferFunction ?? "-") / \(v.matrix ?? "-")")
    }
    for (i, a) in info.audio.enumerated() {
        print("  audio \(i + 1):     \(a.codecName) \(a.channelLayoutName), \(Int(a.sampleRate)) Hz, \(Format.bitRate(a.bitRate))\(a.languageCode.map { ", \($0)" } ?? "")")
    }
    let m = info.metadata
    if let date = m.creationDate { print("  created:     \(date.ISO8601Format())") }
    if let loc = m.location { print("  location:    \(Format.coordinate(loc))") }
    if m.make != nil || m.model != nil { print("  device:      \([m.make, m.model, m.software].compactMap { $0 }.joined(separator: " "))") }
    let c = info.camera
    if let lens = c.lensModel { print("  lens:        \(lens) (+\(max(c.trackMetadataCount - 1, 0)) more track fields)") }
    if !c.timedTracks.isEmpty { print("  camera data: \(c.timedTracks.count) timed tracks: \(c.timedTracks.joined(separator: ", "))") }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "caps":
    printCapabilities()
case "probe" where arguments.count > 1:
    var failed = false
    for path in arguments.dropFirst() {
        do {
            printMediaInfo(try await MediaProbe.probe(URL(fileURLWithPath: path)))
        } catch {
            failed = true
            FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8))
        }
    }
    exit(failed ? 1 : 0)
case "copy" where arguments.count >= 3:
    func value(_ flag: String) -> Double? {
        arguments.firstIndex(of: flag).flatMap { i in
            i + 1 < arguments.count ? Format.parseDuration(arguments[i + 1]) : nil
        }
    }
    let source = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
    let info = try await MediaProbe.probe(source)
    let start = value("--start") ?? 0, end = value("--end") ?? info.duration
    let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90_000),
                            end: CMTime(seconds: end, preferredTimescale: 90_000))
    let began = Date()
    try await CopyExporter.export(source: source, range: range,
                                  mode: arguments.contains("--exact") ? .exact : .keyframe,
                                  audioTrack: audioTrackChoice(arguments),
                                  metadata: metadataEdits(arguments), to: output)
    let result = try await MediaProbe.probe(output)
    print("wrote \(output.path): \(Format.duration(result.duration)), \(Format.bytes(result.fileSize)) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
case "shrink-audio" where arguments.count >= 3:
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { i in i + 1 < arguments.count ? arguments[i + 1] : nil }
    }
    let source = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
    let duration = try await MediaProbe.probe(source).duration
    let start = value("--start").flatMap(Format.parseDuration) ?? 0
    let end = value("--end").flatMap(Format.parseDuration) ?? duration
    let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90_000),
                            end: CMTime(seconds: end, preferredTimescale: 90_000))
    let began = Date()
    try await AudioReencoder.export(source: source, range: range,
                                    mode: arguments.contains("--exact") ? .exact : .keyframe,
                                    audioBitRate: (value("--kbps").flatMap(Int.init) ?? 96) * 1000,
                                    audioTrack: audioTrackChoice(arguments),
                                    metadata: metadataEdits(arguments), to: output)
    let result = try await MediaProbe.probe(output)
    print("wrote \(output.lastPathComponent): \(Format.duration(result.duration)), \(Format.bytes(result.fileSize)) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
case "transcode" where arguments.count >= 3:
    func option(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { i in i + 1 < arguments.count ? arguments[i + 1] : nil }
    }
    let source = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
    var settings = TranscodeSettings()
    settings.codec = option("--codec") == "h264" ? .h264 : .hevc
    settings.maxShortSide = option("--short").flatMap(Int.init)
    settings.frameRateCap = option("--fps").flatMap(Int.init) ?? 30
    settings.keepHDR = !arguments.contains("--sdr")
    settings.forceSoftwareEncoder = arguments.contains("--software")
    settings.metadata = metadataEdits(arguments)
    settings.audioTrack = audioTrackChoice(arguments)
    if let mb = option("--fit").flatMap(Double.init) { settings.targetFileSize = Int64(mb * 1_000_000) }
    settings.container = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
    if let kbps = option("--audio").flatMap(Int.init) { settings.audio = AudioPlan(kbps: kbps) }   // 0 = keep
    if let v = option("--vbr").flatMap(Int.init) { settings.rateControl = .variableBitRate(v * 1000) }
    if let v = option("--abr").flatMap(Int.init) { settings.rateControl = .averageBitRate(v * 1000) }
    if let v = option("--cq").flatMap(Double.init) { settings.rateControl = .constantQuality(v) }
    if let v = option("--qp").flatMap(Double.init) { settings.rateControl = .fixedQuality(v) }
    var range: CMTimeRange?
    if option("--start") != nil || option("--end") != nil {
        let duration = try await MediaProbe.probe(source).duration
        let start = option("--start").flatMap(Format.parseDuration) ?? 0
        let end = option("--end").flatMap(Format.parseDuration) ?? duration
        range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90_000),
                            end: CMTime(seconds: end, preferredTimescale: 90_000))
    }
    let result = try await Transcoder.transcode(source: source, range: range, settings: settings, to: output)
    let out = try await MediaProbe.probe(output)
    let plan = result.plan
    print("""
        wrote \(output.lastPathComponent): \(Int(plan.outputSize.width))x\(Int(plan.outputSize.height)) \(plan.hdr.rawValue), \
        \(result.usedHardwareEncoder == false ? "software" : "hardware") \(result.rateControl.label), \(Format.duration(out.duration)), \(Format.bytes(out.fileSize)) \
        (video \(Format.bitRate(out.video?.bitRate ?? 0))), \(result.attempts) pass(es), frames \(result.framesEncoded)/\(result.framesRead), \
        \(String(format: "%.2f", result.seconds))s
        """)
default:
    print(usage)
    exit(CommandLine.arguments.count > 1 ? 64 : 0)
}
