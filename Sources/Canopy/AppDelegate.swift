import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = NowPlayingModel()
    private let settings = SettingsStore()
    private let mirror = NotificationMirror()
    private var notchController: NotchController?
    private var widgetController: WidgetController?
    private var lockscreenFeed: LockscreenFeed?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        notchController = NotchController(model: model, settings: settings)
        widgetController = WidgetController(model: model, settings: settings)
        lockscreenFeed = LockscreenFeed(model: model, settings: settings)

        mirror.onBanner = { [weak self] banner in self?.model.pushBanner(banner) }
        mirror.onStatusChange = { [weak self] in self?.rebuildMenu() }
        mirror.start()

        settingsWindow = SettingsWindowController(
            settings: settings,
            model: model,
            mirrorStatus: { [weak self] in self?.mirror.status.menuText ?? "" },
            onGrantFDA: { [weak self] in self?.openFullDiskAccess() },
            onTestBanner: { [weak self] in self?.testBanner() }
        )

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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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

        // Notch size (Small / Medium / Large).
        let sizeItem = NSMenuItem(title: "Notch Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in NotchSize.allCases {
            let entry = NSMenuItem(title: size.title, action: #selector(selectNotchSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = size.rawValue
            entry.state = settings.notchSize == size ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // Hover style (Solid Black / Subtle Gradient).
        let hoverItem = NSMenuItem(title: "Hover Style", action: nil, keyEquivalent: "")
        let hoverMenu = NSMenu()
        for style in HoverStyle.allCases {
            let entry = NSMenuItem(title: style.title, action: #selector(selectHoverStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.rawValue
            entry.state = settings.hoverStyle == style ? .on : .off
            hoverMenu.addItem(entry)
        }
        hoverItem.submenu = hoverMenu
        menu.addItem(hoverItem)

        menu.addItem(.separator())

        // Feed the current widget preset to the Canopy screen saver.
        let saverToggle = NSMenuItem(
            title: "Show on Screen Saver",
            action: #selector(toggleScreenSaver),
            keyEquivalent: ""
        )
        saverToggle.target = self
        saverToggle.state = settings.screenSaverEnabled ? .on : .off
        menu.addItem(saverToggle)

        let saverSettings = NSMenuItem(
            title: "Open Screen Saver Settings…",
            action: #selector(openScreenSaverSettings),
            keyEquivalent: ""
        )
        saverSettings.target = self
        menu.addItem(saverSettings)

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

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    @objc private func selectNotchSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = NotchSize(rawValue: raw) else { return }
        settings.notchSize = size
        rebuildMenu()
    }

    @objc private func selectHoverStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = HoverStyle(rawValue: raw) else { return }
        settings.hoverStyle = style
        rebuildMenu()
    }

    @objc private func toggleScreenSaver() {
        settings.screenSaverEnabled.toggle()
        rebuildMenu()
    }

    @objc private func openScreenSaverSettings() {
        // Sonoma+ moved this to the Wallpaper/Screen Saver settings extension;
        // fall back to the legacy pane on older systems.
        let urls = [
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"
        ].compactMap(URL.init(string:))
        if let url = urls.first { NSWorkspace.shared.open(url) }
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
