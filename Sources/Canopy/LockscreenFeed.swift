import AppKit
import SwiftUI
import Combine

/// Renders the selected widget preset to the shared PNG roughly once a second so
/// the CanopyScreenSaver bundle can display it on the screen saver. Active only
/// while the user enables "Show on Screen Saver"; the saver itself decides when
/// it's actually on screen, so this just keeps a fresh frame available.
///
/// All media access and rendering happen here, in the full-capability app
/// process — the sandboxed saver never touches media.
@MainActor
final class LockscreenFeed {
    private let model: NowPlayingModel
    private let settings: SettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(model: NowPlayingModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings

        settings.$screenSaverEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.setEnabled(on) }
            .store(in: &cancellables)

        setEnabled(settings.screenSaverEnabled)
    }

    private func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        renderFrame()
        // 1 Hz keeps the clock and scrubber on the card current; rendering a
        // ~340×540 view offscreen is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderFrame() }
        }
    }

    private func renderFrame() {
        let preset = settings.preset
        let size = preset.size
        let view = WidgetView(vm: model, preset: preset, snapshotMode: true)
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        try? png.write(to: CanopyShared.frameURL, options: .atomic)

        let status = CanopyShareStatus(
            updated: Date(),
            isPlaying: model.isPlaying,
            hasMedia: model.hasMedia,
            backgroundHex: Self.hex(model.palette.first)
        )
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: CanopyShared.statusURL, options: .atomic)
        }
    }

    private static func hex(_ color: Color?) -> String {
        guard let color, let ns = NSColor(color).usingColorSpace(.sRGB) else { return "#0B0B0F" }
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
