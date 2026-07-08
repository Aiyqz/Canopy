import AppKit

// 顶层可执行代码，运行在主线程。
MainActor.assumeIsolated {
    let app = NSApplication.shared

    // 离屏渲染模式（用于验证界面）：`Canopy --snapshot [目录]`。
    if let idx = CommandLine.arguments.firstIndex(of: "--snapshot") {
        app.setActivationPolicy(.prohibited)
        let dir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp"
        NotchSnapshotter.run(to: dir)
        exit(0)
    }

    // 图标渲染模式：`Canopy --icon <路径.png>`。
    if let idx = CommandLine.arguments.firstIndex(of: "--icon") {
        app.setActivationPolicy(.prohibited)
        let path = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/canopy_icon.png"
        IconRenderer.render(to: path)
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    // 设为辅助应用：不显示 Dock 图标、无主菜单，仅常驻菜单栏 + 灵动岛。
    app.setActivationPolicy(.accessory)
    app.run()
}
