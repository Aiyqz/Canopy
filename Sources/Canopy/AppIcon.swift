// AppIcon.swift —— 生成应用图标（叶片 + 绿色渐变圆角方块）。
import SwiftUI

/// The Canopy app icon — a leaf over a green gradient squircle with a hint of
/// the Dynamic Island notch.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.66, blue: 0.44),
                            Color(red: 0.04, green: 0.28, blue: 0.22)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // A nod to the notch / Dynamic Island.
            RoundedRectangle(cornerRadius: 70, style: .continuous)
                .fill(.black.opacity(0.85))
                .frame(width: 360, height: 132)
                .offset(y: -250)

            Image(systemName: "leaf.fill")
                .font(.system(size: 440, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.white, .white.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .rotationEffect(.degrees(-18))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 18)
                .offset(y: 70)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
enum IconRenderer {
    static func render(to path: String) {
        NotchSnapshotter.write(AppIconView(), to: path)
    }
}
