// EqualizerBars.swift —— 播放时显示在灵动岛旁的小型动态音律条。
import SwiftUI

/// Tiny animated audio bars shown beside the notch while something is playing.
struct EqualizerBars: View {
    var active: Bool
    var color: Color = .white

    @State private var phase: CGFloat = 0
    private let bars = 4
    private let heights: [CGFloat] = [0.4, 1.0, 0.6, 0.85]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(i))
            }
        }
        .frame(height: 16)
        .opacity(active ? 1 : 0.35)
        .onAppear { animate() }
        .onChange(of: active) { _, _ in animate() }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base = heights[i % heights.count]
        guard active else { return 16 * base * 0.5 }
        let wobble = sin(phase + CGFloat(i) * 1.3) * 0.5 + 0.5
        return 4 + 12 * base * wobble
    }

    private func animate() {
        guard active else { return }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            phase = .pi * 2
        }
    }
}
