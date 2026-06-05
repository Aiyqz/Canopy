import SwiftUI

/// Audio bars beside the notch. When ScreenCaptureKit audio capture is running
/// (something is playing + Screen Recording granted), the bars reflect the real
/// spectrum from `AudioLevelMonitor`. Otherwise they fall back to a stylized
/// TimelineView animation so they still move while playing.
struct EqualizerBars: View {
    var active: Bool
    var color: Color = .white

    @ObservedObject private var audio = AudioLevelMonitor.shared

    private let bars = 4
    private let heights: [CGFloat] = [0.4, 1.0, 0.6, 0.85]

    var body: some View {
        let live = audio.levels
        let useReal = active && live.count == bars

        Group {
            if useReal {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(color)
                            .frame(width: 2.5, height: 4 + 12 * live[i])
                    }
                }
                .frame(height: 16)
                .animation(.linear(duration: 0.06), value: live)
            } else {
                stylized
            }
        }
    }

    private var stylized: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let phase = active ? context.date.timeIntervalSinceReferenceDate * 4 : 0
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: barHeight(i, phase: phase))
                }
            }
            .frame(height: 16)
            .opacity(active ? 1 : 0.35)
        }
    }

    private func barHeight(_ i: Int, phase: Double) -> CGFloat {
        let base = heights[i % heights.count]
        guard active else { return 16 * base * 0.5 }
        let wobble = CGFloat(sin(phase + Double(i) * 1.3)) * 0.5 + 0.5
        return 4 + 12 * base * wobble
    }
}
