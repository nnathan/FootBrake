import Foundation

/// Human-readable strings shared by the app and the CLI.
public enum Format {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    public static func bitRate(_ bps: Double) -> String {
        bps >= 1_000_000
            ? String(format: "%.1f Mbps", bps / 1_000_000)
            : String(format: "%.0f kbps", bps / 1000)
    }

    /// `1:02:03.450` or `2:03.450`.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let millis = Int((seconds * 1000).rounded())
        let h = millis / 3_600_000, m = millis / 60_000 % 60, s = millis / 1000 % 60, ms = millis % 1000
        return h > 0
            ? String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
            : String(format: "%d:%02d.%03d", m, s, ms)
    }

    public static func frameRate(_ fps: Double) -> String {
        abs(fps - fps.rounded()) < 0.01 ? String(format: "%.0f fps", fps) : String(format: "%.2f fps", fps)
    }

    public static func containerName(_ uti: String?) -> String {
        switch uti {
        case "com.apple.quicktime-movie": "QuickTime (MOV)"
        case "public.mpeg-4": "MPEG-4 (MP4)"
        case "com.apple.m4v-video": "MPEG-4 (M4V)"
        case "public.3gpp": "3GPP"
        default: uti ?? "Unknown"
        }
    }

    public static func coordinate(_ location: GeoLocation) -> String {
        String(format: "%.5f°%@, %.5f°%@",
               abs(location.latitude), location.latitude >= 0 ? "N" : "S",
               abs(location.longitude), location.longitude >= 0 ? "E" : "W")
    }
}
