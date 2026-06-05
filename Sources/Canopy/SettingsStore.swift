import SwiftUI
import ServiceManagement

enum WidgetPreset: String, CaseIterable, Identifiable {
    case lockscreen
    case nowPlaying
    case lyrics
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockscreen: return "Lockscreen"
        case .nowPlaying: return "Now Playing"
        case .lyrics:     return "Lyrics"
        case .minimal:    return "Minimal Clock"
        }
    }

    var size: CGSize {
        switch self {
        case .lockscreen: return CGSize(width: 340, height: 540)
        case .nowPlaying: return CGSize(width: 340, height: 460)
        case .lyrics:     return CGSize(width: 360, height: 500)
        case .minimal:    return CGSize(width: 320, height: 200)
        }
    }
}

/// Persisted user settings (widget visibility + chosen preset).
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var widgetVisible: Bool {
        didSet { defaults.set(widgetVisible, forKey: "widgetVisible") }
    }
    @Published var preset: WidgetPreset {
        didSet { defaults.set(preset.rawValue, forKey: "widgetPreset") }
    }

    init() {
        // Default the widget ON for first launch (no stored value yet).
        if defaults.object(forKey: "widgetVisible") == nil {
            widgetVisible = true
        } else {
            widgetVisible = defaults.bool(forKey: "widgetVisible")
        }
        preset = WidgetPreset(rawValue: defaults.string(forKey: "widgetPreset") ?? "")
            ?? .lockscreen
    }
}

/// Launch-at-login via the modern ServiceManagement API.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Canopy: launch-at-login toggle failed: \(error)")
        }
    }
}
