/// Which audio track(s) an export keeps. Indices refer to `MediaInfo.audio`,
/// which follows the file's audio track order.
public enum AudioTrackChoice: Sendable, Hashable, Codable {
    /// FootBrake's default: every track for a lossless copy, otherwise the
    /// main stereo track (AAC rather than the iPhone's spatial APAC track).
    case automatic
    case track(Int)
    /// A silent video.
    case none

    /// The track re-encodes use by default.
    public static func mainIndex(_ audio: [AudioTrackInfo]) -> Int? {
        audio.firstIndex { $0.codecFourCC == "aac " }
            ?? audio.firstIndex { $0.codecFourCC != "apac" }
            ?? audio.indices.first
    }

    /// The one track an export that keeps a single track uses (nil: no audio).
    public func singleTrack(in audio: [AudioTrackInfo]) -> Int? {
        switch self {
        case .automatic: Self.mainIndex(audio)
        case .track(let index): audio.indices.contains(index) ? index : Self.mainIndex(audio)
        case .none: nil
        }
    }
}
