import AppKit
import SwiftUI

/// Owns the Canopy preferences window. Since Canopy is an accessory app (no Dock
/// icon, no main menu), we activate the app and bring the window forward so its
/// controls are focusable.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    private let settings: SettingsStore
    private let model: NowPlayingModel
    private let mirrorStatus: () -> String
    private let onGrantFDA: () -> Void
    private let onTestBanner: () -> Void

    init(
        settings: SettingsStore,
        model: NowPlayingModel,
        mirrorStatus: @escaping () -> String,
        onGrantFDA: @escaping () -> Void,
        onTestBanner: @escaping () -> Void
    ) {
        self.settings = settings
        self.model = model
        self.mirrorStatus = mirrorStatus
        self.onGrantFDA = onGrantFDA
        self.onTestBanner = onTestBanner
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(
            settings: settings,
            model: model,
            mirrorStatus: mirrorStatus,
            onGrantFDA: onGrantFDA,
            onTestBanner: onTestBanner,
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Canopy Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CanopySettings")
        return window
    }
}
