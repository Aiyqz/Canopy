import SwiftUI

/// The Canopy preferences window content. Bound to the live SettingsStore +
/// NowPlayingModel, so every change applies immediately (the controllers observe
/// the same store).
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: NowPlayingModel

    var mirrorStatus: () -> String
    var onGrantFDA: () -> Void
    var onTestBanner: () -> Void
    var onQuit: () -> Void

    @ObservedObject private var audio = AudioLevelMonitor.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var mirrorText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                section("Notch") {
                    Toggle("Show the notch island", isOn: $settings.notchEnabled)
                        .help("Turn off to run Canopy as a menu-bar + desktop-widget app with no floating island.")
                    labeledRow("Size") {
                        Picker("", selection: $settings.notchSize) {
                            ForEach(NotchSize.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    .disabled(!settings.notchEnabled)
                    labeledRow("Hover look") {
                        Picker("", selection: $settings.hoverStyle) {
                            ForEach(HoverStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    .disabled(!settings.notchEnabled)
                    NotchPreview(style: settings.hoverStyle, size: settings.notchSize)
                        .padding(.top, 4)
                        .opacity(settings.notchEnabled ? 1 : 0.4)
                }

                section("Desktop Widget") {
                    Toggle("Show widget on the desktop", isOn: $settings.widgetVisible)
                    labeledRow("Style") {
                        Picker("", selection: $settings.preset) {
                            ForEach(WidgetPreset.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .disabled(!settings.widgetVisible)
                    }
                    labeledRow("Opacity") {
                        Slider(value: $settings.widgetOpacity, in: 0.3...1.0)
                            .frame(width: 200)
                            .disabled(!settings.widgetVisible)
                            .help("How see-through the desktop widget is.")
                    }
                }

                section("Screen Saver") {
                    Toggle("Show on Screen Saver", isOn: $settings.screenSaverEnabled)
                    Text("Feeds the selected widget style to the Canopy screen saver — the closest macOS allows to a lock-screen widget. Install it with Scripts/install-screensaver.sh, then pick Canopy in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    HStack {
                        Spacer()
                        Button("Open Screen Saver Settings…") { openScreenSaverSettings() }
                    }
                }

                section("Media") {
                    labeledRow("Backend") {
                        Text(model.mediaAvailable ? model.backendName : "unavailable")
                            .foregroundStyle(.secondary)
                    }
                    Text("Reads & controls whatever is playing system-wide.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Divider()

                    labeledRow("EQ bars") {
                        Text(audio.levels.isEmpty ? "Animated" : "Live audio spectrum")
                            .foregroundStyle(.secondary)
                    }
                    if audio.levels.isEmpty {
                        HStack {
                            Text("Grant Screen Recording for bars that react to the audio.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("Open…") { openScreenRecording() }
                        }
                    }
                }

                section("Notifications") {
                    labeledRow("Mirroring") {
                        Text(mirrorText.isEmpty ? mirrorStatus() : mirrorText)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 10) {
                        Button("Grant Full Disk Access…") { onGrantFDA() }
                        Button("Test Banner") { onTestBanner() }
                    }
                }

                section("General") {
                    Toggle("Launch Canopy at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAtLogin.set(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    HStack {
                        Spacer()
                        Button("Quit Canopy", role: .destructive) { onQuit() }
                    }
                }

                HStack {
                    Spacer()
                    Text("Canopy \(Self.appVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(22)
        }
        .frame(width: 460)
        .frame(minHeight: 560)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            mirrorText = mirrorStatus()
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "v\(short) (\(build))"
    }

    private func openScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenSaverSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"
        ]
        if let url = candidates.compactMap(URL.init(string:)).first {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Building blocks

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.18, green: 0.66, blue: 0.44),
                                 Color(red: 0.04, green: 0.28, blue: 0.22)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Canopy").font(.title2.weight(.bold))
                Text("Dynamic Island for macOS")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }
}

// MARK: - Offscreen snapshot (for verification without screen recording)

@MainActor
enum SettingsSnapshot {
    static func render(to path: String) {
        let settings = SettingsStore()
        let model = NotchSnapshotter.sampleModel()
        model.backendName = "MediaRemote adapter"
        let view = SettingsView(
            settings: settings,
            model: model,
            mirrorStatus: { "Notifications: mirroring active" },
            onGrantFDA: {}, onTestBanner: {}, onQuit: {}
        )
        .frame(width: 460, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        NotchSnapshotter.write(view, to: path)
    }
}

// MARK: - Live notch preview

/// A scaled mock of the open island so the hover look + relative size are
/// visible right in Settings.
private struct NotchPreview: View {
    var style: HoverStyle
    var size: NotchSize

    private var width: CGFloat {
        switch size {
        case .small:  return 180
        case .medium: return 220
        case .large:  return 260
        }
    }
    private var height: CGFloat {
        switch size {
        case .small:  return 64
        case .medium: return 74
        case .large:  return 86
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            ZStack {
                NotchShape().fill(.black)
                if style == .subtleGradient {
                    NotchShape().fill(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .white.opacity(0.03), .clear],
                            startPoint: .top, endPoint: .bottom))
                }
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.18))
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: 70, height: 5)
                        Capsule().fill(.white.opacity(0.25)).frame(width: 44, height: 5)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(width: width, height: height)
            }
            .frame(width: width, height: height)
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
    }
}
