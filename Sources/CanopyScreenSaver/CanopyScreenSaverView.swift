import ScreenSaver
import AppKit

/// Canopy's screen saver. It is a pure *consumer*: the sandboxed screen-saver
/// host can't read media or spawn helpers, so this view never touches now-playing
/// data. It simply draws the latest now-playing card that the Canopy app renders
/// into the shared App Group container, centred over a colour fill.
///
/// `@objc` keeps the runtime name module-independent so Info.plist's
/// NSPrincipalClass can be just "CanopyScreenSaverView".
@objc(CanopyScreenSaverView)
final class CanopyScreenSaverView: ScreenSaverView {
    private var frame: NSImage?
    private var background = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.06, alpha: 1)
    private var lastModified: Date?
    private var lastFrameSeen: Date?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 2.0   // poll the shared frame twice a second
        reload()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 2.0
        reload()
    }

    override func startAnimation() {
        super.startAnimation()
        CanopyShared.logResolutionOnce(role: "saver")
        reload()
    }

    override func animateOneFrame() {
        if reload() { setNeedsDisplay(bounds) }
    }

    /// Loads the newest frame + status if the PNG changed. Returns true on change.
    @discardableResult
    private func reload() -> Bool {
        let fm = FileManager.default
        let url = CanopyShared.frameURL
        let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard modified != lastModified else { return false }
        lastModified = modified

        if let modified, let image = NSImage(contentsOf: url) {
            frame = image
            lastFrameSeen = modified
        }

        if let data = try? Data(contentsOf: CanopyShared.statusURL),
           let status = try? JSONDecoder().decode(CanopyShareStatus.self, from: data),
           let color = NSColor(hex: status.backgroundHex) {
            // Deepen the album colour so the card pops against it.
            background = color.blended(withFraction: 0.8, of: .black) ?? color
        }
        return true
    }

    override func draw(_ rect: NSRect) {
        background.setFill()
        bounds.fill()

        // Treat a frame older than ~30s as stale (app quit / nothing playing).
        let fresh = lastFrameSeen.map { Date().timeIntervalSince($0) < 30 } ?? false
        guard let image = frame, fresh else {
            drawPlaceholder()
            return
        }

        // Fit the card into ~70% of the height / 50% of the width, keeping aspect.
        let aspect = image.size.width / max(image.size.height, 1)
        var h = bounds.height * 0.7
        var w = h * aspect
        let maxW = bounds.width * 0.5
        if w > maxW { w = maxW; h = w / aspect }
        let dst = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        image.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawPlaceholder() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let message = CanopyShared.isUsingAppGroup
            ? "🌿 Canopy\nStart playback (and enable “Show on Screen Saver”) to see your now-playing card here."
            : "🌿 Canopy\nApp Group unavailable — sign the app and screen saver with the same Apple Team ID. See README."
        let text = NSAttributedString(
            string: message,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                .font: NSFont.systemFont(ofSize: max(14, bounds.height * 0.02), weight: .medium),
                .paragraphStyle: paragraph
            ]
        )
        let size = text.size()
        text.draw(in: NSRect(x: bounds.midX - 300, y: bounds.midY - size.height / 2,
                             width: 600, height: size.height))
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}

private extension NSColor {
    /// Parses "#RRGGBB".
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
