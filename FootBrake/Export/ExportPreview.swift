import AVKit
import SwiftUI

/// The exported video's first frame with a play button; tapping plays the
/// exported file itself full screen, so the result can be checked before
/// saving or sharing it.
struct ExportPreview: View {
    let url: URL
    @State private var thumbnail: UIImage?
    @State private var playing = false

    var body: some View {
        Button {
            playing = true
        } label: {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.secondary.opacity(0.2).aspectRatio(16 / 9, contentMode: .fit)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 52))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
            }
            .frame(maxWidth: 260, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .green)
                    .offset(x: 10, y: 10)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play exported video")
        .task(id: url) { thumbnail = await Self.firstFrame(of: url) }
        .fullScreenCover(isPresented: $playing) {
            ZStack(alignment: .topLeading) {
                PlayerController(url: url).ignoresSafeArea()
                Button {
                    playing = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding()
                .accessibilityLabel("Close")
            }
        }
    }

    private static func firstFrame(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Apple's standard player (scrubbing, volume, Picture in Picture, AirPlay).
private struct PlayerController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
    }
}
