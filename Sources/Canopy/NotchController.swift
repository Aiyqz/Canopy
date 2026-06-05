import AppKit
import SwiftUI

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
/// animates between collapsed and expanded sizes on hover.
@MainActor
final class NotchController {
    private let window: NSPanel
    private let screen: NSScreen
    private let metrics: NotchMetrics
    private let collapsedSize: CGSize
    private let expandedSize: CGSize
    private let bannerSize: CGSize

    private var collapseWork: DispatchWorkItem?

    init(model: NowPlayingModel) {
        // Prefer the screen that actually has a notch; fall back to main.
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        metrics = NotchController.notchMetrics(for: screen)

        // Collapsed: notch width + small "peeks" on each side for art / bars.
        let peek: CGFloat = 86
        collapsedSize = CGSize(
            width: metrics.notchWidth + peek * 2,
            height: metrics.notchHeight
        )
        expandedSize = CGSize(
            width: max(metrics.notchWidth + 360, 420),
            height: 196
        )
        bannerSize = CGSize(
            width: max(metrics.notchWidth + 320, 400),
            height: 80
        )

        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
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

        let metricsCopy = metrics
        let root = NotchView(vm: model, metrics: metricsCopy) { [weak self] presentation in
            self?.present(presentation)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: expandedSize)
        window.contentView = hosting

        position(for: collapsedSize)
        window.orderFrontRegardless()
    }

    private func present(_ presentation: NotchPresentation) {
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

    private static func notchMetrics(for screen: NSScreen) -> NotchMetrics {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            let height = max(left.height, right.height)
            if width > 0, height > 0 {
                return NotchMetrics(notchWidth: width, notchHeight: height)
            }
        }
        // No notch (external display / older Mac): a floating island.
        return NotchMetrics(notchWidth: 190, notchHeight: 32)
    }
}
