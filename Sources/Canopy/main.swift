import AppKit

// Top-level executable code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Offscreen render mode for verification: `Canopy --snapshot [dir]`.
    if let idx = CommandLine.arguments.firstIndex(of: "--snapshot") {
        app.setActivationPolicy(.prohibited)
        let dir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp"
        NotchSnapshotter.run(to: dir)
        exit(0)
    }

    // Icon render mode: `Canopy --icon <path.png>`.
    if let idx = CommandLine.arguments.firstIndex(of: "--icon") {
        app.setActivationPolicy(.prohibited)
        let path = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/canopy_icon.png"
        IconRenderer.render(to: path)
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    // Accessory: no Dock icon, no main menu — lives in the menu bar + notch.
    app.setActivationPolicy(.accessory)
    app.run()
}
