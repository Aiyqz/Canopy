import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = NowPlayingModel()
    private let settings = SettingsStore()
    private let mirror = NotificationMirror()
    private var notchController: NotchController?
    private var widgetController: WidgetController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        notchController = NotchController(model: model)
        widgetController = WidgetController(model: model, settings: settings)

        mirror.onBanner = { [weak self] banner in self?.model.pushBanner(banner) }
        mirror.onStatusChange = { [weak self] in self?.rebuildMenu() }
        mirror.start()

        setUpStatusItem()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "leaf.fill",
            accessibilityDescription: "Canopy"
        )

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let status = model.mediaAvailable
            ? "Canopy — media: \(model.backendName)"
            : "Canopy — media bridge unavailable"
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let widgetToggle = NSMenuItem(
            title: "Show Lockscreen Widget",
            action: #selector(toggleWidget),
            keyEquivalent: "l"
        )
        widgetToggle.target = self
        widgetToggle.state = settings.widgetVisible ? .on : .off
        menu.addItem(widgetToggle)

        let styleItem = NSMenuItem(title: "Widget Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for preset in WidgetPreset.allCases {
            let entry = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.rawValue
            entry.state = settings.preset == preset ? .on : .off
            styleMenu.addItem(entry)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        // Notification mirroring status (+ shortcut to grant access if needed).
        let mirrorStatus = NSMenuItem(title: mirror.status.menuText, action: nil, keyEquivalent: "")
        mirrorStatus.isEnabled = false
        menu.addItem(mirrorStatus)
        if mirror.status == .noAccess {
            let grant = NSMenuItem(
                title: "Grant Full Disk Access…",
                action: #selector(openFullDiskAccess),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        }
        let testBanner = NSMenuItem(
            title: "Test Notch Banner",
            action: #selector(testBanner),
            keyEquivalent: ""
        )
        testBanner.target = self
        menu.addItem(testBanner)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Canopy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // Refresh checkmarks each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func toggleWidget() {
        settings.widgetVisible.toggle()
        rebuildMenu()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = WidgetPreset(rawValue: raw) else { return }
        settings.preset = preset
        if !settings.widgetVisible { settings.widgetVisible = true }
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        rebuildMenu()
    }

    @objc private func openFullDiskAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    @objc private func testBanner() {
        model.pushBanner(NotchBanner(
            title: "Canopy",
            subtitle: "Notch banners are working",
            body: nil,
            icon: NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil),
            kind: .system
        ))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
