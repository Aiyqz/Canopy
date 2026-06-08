import SwiftUI

/// A behind-window blur so the widget reads as real frosted glass over the
/// desktop wallpaper.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The full desktop widget: Liquid Glass + album-art gradient + content.
struct WidgetView: View {
    @ObservedObject var vm: NowPlayingModel
    var preset: WidgetPreset
    /// When true, replaces the live blur with an opaque gradient (for offscreen snapshots).
    var snapshotMode = false

    /// Honor the Accessibility "Reduce Transparency" setting by dropping the
    /// behind-window blur for a solid backing.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let corner: CGFloat = 38

    var body: some View {
        ZStack {
            background
            WidgetContent(vm: vm, preset: preset)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(glassEdge)
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        .padding(14) // room for the shadow inside the window
    }

    @ViewBuilder private var background: some View {
        ZStack {
            baseMaterial
            // Apple-Music-style gradient tint from album art, infused into the glass.
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .opacity(snapshotMode || reduceTransparency ? 0.85 : 0.5)
            .blur(radius: 8)
        }
    }

    @ViewBuilder private var baseMaterial: some View {
        if snapshotMode || reduceTransparency {
            // Opaque for offscreen renders (ImageRenderer can't capture live glass)
            // and for the Reduce Transparency accessibility setting.
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)
        } else if #available(macOS 26.0, *) {
            // Native Liquid Glass, matching the notch.
            Color.clear.glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: corner, style: .continuous)
            )
        } else {
            VisualEffectView()
        }
    }

    private var gradientColors: [Color] {
        let p = vm.palette
        guard p.count >= 2 else { return ColorExtractor.fallback }
        return Array(p.prefix(3))
    }

    private var glassEdge: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}
