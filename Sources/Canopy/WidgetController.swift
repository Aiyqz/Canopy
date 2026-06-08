import AppKit
import SwiftUI
import Combine

/// Owns the floating "Liquid Glass" desktop widget window.
@MainActor
final class WidgetController {
    private var window: NSPanel?
    private let model: NowPlayingModel
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(model: NowPlayingModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings

        settings.$widgetVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.apply(visible: visible) }
            .store(in: &cancellables)

        settings.$preset
            .receive(on: RunLoop.main)
            .sink { [weak self] preset in self?.apply(preset: preset) }
            .store(in: &cancellables)

        apply(visible: settings.widgetVisible)
    }

    private func apply(visible: Bool) {
        if visible {
            show()
        } else {
            window?.orderOut(nil)
        }
    }

    private func apply(preset: WidgetPreset) {
        guard let window, settings.widgetVisible else { return }
        rebuildContent(preset: preset)
        resize(to: preset, window: window)
    }

    private func show() {
        let preset = settings.preset
        let window = self.window ?? makeWindow(preset: preset)
        self.window = window
        rebuildContent(preset: preset)
        resize(to: preset, window: window)
        window.orderFront(nil)
    }

    private func makeWindow(preset: WidgetPreset) -> NSPanel {
        let size = preset.size
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Sit on the desktop, above the wallpaper but below normal app windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        // Remember where the user dragged the widget across launches. On first run
        // there's nothing to restore, so place it near the top-right of the screen.
        let restored = panel.setFrameUsingName("CanopyWidget")
        panel.setFrameAutosaveName("CanopyWidget")
        if !restored, let screen = NSScreen.main {
            let v = screen.visibleFrame
            let origin = NSPoint(x: v.maxX - size.width - 40, y: v.maxY - size.height - 40)
            panel.setFrameOrigin(origin)
        }
        return panel
    }

    private func rebuildContent(preset: WidgetPreset) {
        guard let window else { return }
        let root = WidgetView(vm: model, preset: preset)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: window.frame.size)
        // Track the window during the resize animation so content doesn't snap.
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
    }

    private func resize(to preset: WidgetPreset, window: NSPanel) {
        // Keep the top-left corner anchored when the size changes.
        let old = window.frame
        let size = preset.size
        let newFrame = NSRect(
            x: old.minX,
            y: old.maxY - size.height,
            width: size.width,
            height: size.height
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(newFrame, display: true)
        }
        window.contentView?.frame = NSRect(origin: .zero, size: size)
    }
}
