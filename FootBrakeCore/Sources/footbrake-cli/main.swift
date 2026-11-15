import CoreMedia
import FootBrakeCore
import Foundation

// macOS test harness for FootBrakeCore. Runs the same engine code as the iOS
// app so it can be exercised against fixture clips without a device.

let usage = """
    footbrake-cli \(FootBrakeCore.version)

    usage: footbrake-cli <command>

    commands:
      caps            print this machine's VideoToolbox encoder capabilities
      probe <file>... print media info for each file
      copy <in> <out> --start <time> --end <time> [--exact]
                      trim without re-encoding (default: start at previous keyframe)
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
                                  mode: arguments.contains("--exact") ? .exact : .keyframe, to: output)
    let result = try await MediaProbe.probe(output)
    print("wrote \(output.path): \(Format.duration(result.duration)), \(Format.bytes(result.fileSize)) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
default:
    print(usage)
    exit(CommandLine.arguments.count > 1 ? 64 : 0)
}
