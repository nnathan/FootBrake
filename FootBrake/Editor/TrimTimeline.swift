import FootBrakeCore
import SwiftUI

/// Filmstrip with draggable start/end handles and a playhead.
/// Dragging the filmstrip itself scrubs the playhead.
struct TrimTimeline: View {
    @ObservedObject var model: EditorModel

    private let handleWidth: CGFloat = 16
    private let height: CGFloat = 56
    private let space = "timeline"

    var body: some View {
        GeometryReader { geo in
            let track = max(1, geo.size.width - handleWidth * 2)
            let startX = handleWidth + x(model.start, track)
            let endX = handleWidth + x(model.end, track)

            ZStack(alignment: .leading) {
                filmstrip
                    .frame(width: track, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(x: handleWidth)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(track))

                // Dim everything outside the selection.
                Color.black.opacity(0.55)
                    .frame(width: max(0, startX - handleWidth), height: height)
                    .offset(x: handleWidth)
                    .allowsHitTesting(false)
                Color.black.opacity(0.55)
                    .frame(width: max(0, handleWidth + track - endX), height: height)
                    .offset(x: endX)
                    .allowsHitTesting(false)

                // Selection frame.
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX) + handleWidth * 2, height: height)
                    .offset(x: startX - handleWidth)
                    .allowsHitTesting(false)

                handle(systemImage: "chevron.compact.left")
                    .offset(x: startX - handleWidth)
                    .gesture(handleGesture(track) { model.setStart($0) })
                    .accessibilityLabel("Start")
                    .accessibilityValue(Format.duration(model.start))
                handle(systemImage: "chevron.compact.right")
                    .offset(x: endX)
                    .gesture(handleGesture(track) { model.setEnd($0) })
                    .accessibilityLabel("End")
                    .accessibilityValue(Format.duration(model.end))

                // Playhead.
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: height + 8)
                    .shadow(radius: 1)
                    .offset(x: handleWidth + x(model.playhead, track) - 1.5)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: space)
        }
        .frame(height: height + 8)
        .task { await model.loadThumbnails(count: 10) }
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Color.secondary.opacity(0.3))
    }

    private func handle(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: handleWidth, height: height)
            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
            .frame(width: 44, height: height + 8)   // larger hit target
            .contentShape(Rectangle())
            .offset(x: -(44 - handleWidth) / 2)
    }

    private func x(_ time: Double, _ track: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(time / model.duration) * track : 0
    }

    private func time(_ x: CGFloat, _ track: CGFloat) -> Double {
        Double((x - handleWidth) / track) * model.duration
    }

    private func handleGesture(_ track: CGFloat, set: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { set(time($0.location.x, track)) }
    }

    private func scrubGesture(_ track: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { model.scrub(to: time($0.location.x, track)) }
    }
}
