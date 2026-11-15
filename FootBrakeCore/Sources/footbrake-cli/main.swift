import FootBrakeCore
import Foundation

// macOS test harness for FootBrakeCore. Runs the same engine code as the iOS
// app so it can be exercised against fixture clips without a device.

let usage = """
    footbrake-cli \(FootBrakeCore.version)

    usage: footbrake-cli <command>

    commands:
      caps      print this machine's VideoToolbox encoder capabilities
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

switch CommandLine.arguments.dropFirst().first {
case "caps":
    printCapabilities()
default:
    print(usage)
    exit(CommandLine.arguments.count > 1 ? 64 : 0)
}
