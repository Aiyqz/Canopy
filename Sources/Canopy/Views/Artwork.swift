import SwiftUI

/// Album art with a graceful fallback to a music glyph.
struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat = 8

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.28), Color(white: 0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        // Lift the art off the glass so it reads as a card sitting above the
        // pane rather than printed on it. Scales with the art so the tiny
        // collapsed thumbnail gets only a whisper of shadow.
        .shadow(color: .black.opacity(0.28), radius: size * 0.06, y: size * 0.02)
    }
}
