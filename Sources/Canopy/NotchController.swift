import AppKit
import SwiftUI
import Combine

struct NotchMetrics {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
}

enum NotchPresentation {
    case collapsed
    case banner
    case expanded
}

/// Owns the floating borderless panel, positions it over the notch, and
/// animates between collapsed and expanded sizes on hover. Geometry is derived
/// from the real notch (`NSScreen.safeAreaInsets.top` + the auxiliary top areas)
/// and recomputed whenever the screen configuration changes.
@MainActor
final class NotchController {
    private let model: NowPlayingModel
    private let settings: SettingsStore
    private let window: NSPanel
    private let hosting: NotchHostingView

    private var screen: NSScreen
    private var metrics: NotchMetrics
    private var collapsedSize: CGSize = .zero
    private var expandedSize: CGSize = .zero
    private var bannerSize: CGSize = .zero
    private var expandedContentHeight: CGFloat = 196
    private var presentation: NotchPresentation = .collapsed

    private var collapseWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    init(model: NowPlayingModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings

        screen = NotchController.notchScreen()
        metrics = NotchController.notchMetrics(for: screen)

        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 200, height: 32)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.hidesOnDeactivate = false

        let root = NotchView(vm: model, settings: settings, metrics: metrics) { _ in }
        hosting = NotchHostingView(rootView: root)
        window.contentView = hosting

        // Wire the presentation callback now that `self` is available.
        rebuildRootView()
        recomputeSizes()
        position(for: collapsedSize)
        if settings.notchEnabled {
            window.orderFrontRegardless()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Re-size live when the user changes the notch size in the menu.
        settings.$notchSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySizeChange() }
            .store(in: &cancellables)

        // Show/hide the whole island when the user toggles it.
        settings.$notchEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in self?.applyEnabled(enabled) }
            .store(in: &cancellables)
    }

    private func applyEnabled(_ enabled: Bool) {
        if enabled {
            collapseWork?.cancel()
            presentation = .collapsed
            position(for: collapsedSize)
            window.orderFrontRegardless()
        } else {
            collapseWork?.cancel()
            window.orderOut(nil)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Screen changes

    /// Re-pick the notch screen, recompute metrics, and reposition. Fires when a
    /// display is connected/disconnected, resolution changes, etc.
    @objc private func screenParametersChanged() {
        screen = NotchController.notchScreen()
        metrics = NotchController.notchMetrics(for: screen)
        rebuildRootView()
        recomputeSizes()
        // Snap back to collapsed at the new geometry; hover will re-expand.
        collapseWork?.cancel()
        presentation = .collapsed
        position(for: collapsedSize)
    }

    private func rebuildRootView() {
        hosting.rootView = NotchView(
            vm: model,
            settings: settings,
            metrics: metrics,
            onPresent: { [weak self] presentation in self?.present(presentation) },
            onExpandedHeight: { [weak self] height in self?.setExpandedContentHeight(height) }
        )
    }

    private func recomputeSizes() {
        let size = settings.notchSize

        // Collapsed: notch width + small "peeks" on each side for art / bars.
        let peek: CGFloat = 86
        collapsedSize = CGSize(
            width: metrics.notchWidth + peek * 2,
            height: metrics.notchHeight
        )
        // Width is driven by the size setting; height follows the content (see
        // setExpandedContentHeight) so the island never clips its controls/shelf.
        expandedSize = CGSize(
            width: max(metrics.notchWidth + size.extraWidth, size.minWidth),
            height: max(expandedContentHeight, 80)
        )
        bannerSize = CGSize(
            width: max(metrics.notchWidth + size.extraWidth - 40, size.minWidth - 20),
            height: size.bannerHeight
        )
    }

    /// The expanded panel reports its natural height; grow/shrink the window to
    /// match so content is never clipped (and the island morphs to its content).
    private func setExpandedContentHeight(_ height: CGFloat) {
        let clamped = max(height, 80)
        guard abs(clamped - expandedContentHeight) > 0.5 else { return }
        expandedContentHeight = clamped
        expandedSize.height = clamped
        if presentation == .expanded { animate(to: expandedSize) }
    }

    /// React to a live notch-size change: recompute and re-apply the current
    /// presentation at the new dimensions.
    private func applySizeChange() {
        recomputeSizes()
        switch presentation {
        case .expanded: animate(to: expandedSize)
        case .banner:   animate(to: bannerSize)
        case .collapsed: position(for: collapsedSize)
        }
    }

    // MARK: Presentation

    private func present(_ presentation: NotchPresentation) {
        self.presentation = presentation
        collapseWork?.cancel()
        switch presentation {
        case .expanded:
            animate(to: expandedSize)
        case .banner:
            animate(to: bannerSize)
        case .collapsed:
            // Small debounce so brief cursor exits don't flicker the panel.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.animate(to: self.collapsedSize)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func animate(to size: CGSize) {
        let frame = frame(for: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    private func position(for size: CGSize) {
        window.setFrame(frame(for: size), display: true)
    }

    /// Top-center of the notch screen; top edge flush with the physical top.
    private func frame(for size: CGSize) -> NSRect {
        let sf = screen.frame
        return NSRect(
            x: sf.midX - size.width / 2,
            y: sf.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Geometry

    /// The screen that physically has a notch, falling back to the main screen.
    private static func notchScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static func notchMetrics(for screen: NSScreen) -> NotchMetrics {
        // The notch height is exactly the top safe-area inset on notched Macs.
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 0 {
                return NotchMetrics(notchWidth: width, notchHeight: topInset)
            }
        }
        // No notch (external display / older Mac): a floating island.
        return NotchMetrics(notchWidth: 190, notchHeight: 32)
    }
}

/// Hosting view that only accepts clicks and hovers landing on the visible notch
/// shape. Events in the transparent rounded-corner gaps return nil from
/// `hitTest`, so AppKit passes them through to whatever app is underneath
/// instead of the island swallowing the whole top strip.
private final class NotchHostingView: NSHostingView<NotchView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; bring it into our own.
        // NSHostingView is flipped (top-left origin), matching NotchShape's
        // coordinate space, so the path lines up with what's rendered.
        let local = convert(point, from: superview)
        let shape = NotchShape().path(in: bounds).cgPath
        guard shape.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

