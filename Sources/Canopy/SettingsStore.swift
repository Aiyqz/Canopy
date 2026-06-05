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

/// How big the expanded notch island is. Drives the panel's width/height; the
/// collapsed pill always hugs the real notch regardless.
enum NotchSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }

    /// Extra width added on top of the physical notch width, the minimum overall
    /// width, and the expanded/banner heights — tuned per size.
    var extraWidth: CGFloat {
        switch self {
        case .small:  return 280
        case .medium: return 360
        case .large:  return 460
        }
    }
    var minWidth: CGFloat {
        switch self {
        case .small:  return 380
        case .medium: return 420
        case .large:  return 520
        }
    }
    var expandedHeight: CGFloat {
        switch self {
        case .small:  return 168
        case .medium: return 196
        case .large:  return 240
        }
    }
    var bannerHeight: CGFloat {
        switch self {
        case .small:  return 72
        case .medium: return 80
        case .large:  return 92
        }
    }
}

/// The look of the island while it's open. Both stay dark enough to read as an
/// extension of the physical notch.
enum HoverStyle: String, CaseIterable, Identifiable {
    case solidBlack
    case subtleGradient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solidBlack:     return "Solid Black"
        case .subtleGradient: return "Subtle Gradient"
        }
    }
}

/// Persisted user settings (widget visibility, preset, notch size & hover style).
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var widgetVisible: Bool {
        didSet { defaults.set(widgetVisible, forKey: "widgetVisible") }
    }
    @Published var preset: WidgetPreset {
        didSet { defaults.set(preset.rawValue, forKey: "widgetPreset") }
    }
    @Published var notchSize: NotchSize {
        didSet { defaults.set(notchSize.rawValue, forKey: "notchSize") }
    }
    @Published var hoverStyle: HoverStyle {
        didSet { defaults.set(hoverStyle.rawValue, forKey: "hoverStyle") }
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
        notchSize = NotchSize(rawValue: defaults.string(forKey: "notchSize") ?? "")
            ?? .medium
        hoverStyle = HoverStyle(rawValue: defaults.string(forKey: "hoverStyle") ?? "")
            ?? .solidBlack
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
