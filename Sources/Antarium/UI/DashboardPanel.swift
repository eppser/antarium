import AppKit
import SwiftUI

/// Hosts the dashboard in a borderless floating panel rather than a popover —
/// no arrow, no bubble chrome, and it can stay on screen when pinned.
@MainActor
final class DashboardPanel: NSObject {
    /// One panel for the whole app. Every menu bar item used to build its own,
    /// so with three agents enabled you could have three dashboards on screen
    /// at once, each with its own copy of the same rows.
    static let shared = DashboardPanel()

    /// Private, so the single instance is a fact of the type rather than a
    /// convention someone has to remember.
    private override init() { super.init() }

    private var panel: NSPanel?
    private var hosting: NSHostingView<DashboardView>?
    private var outsideClick: Any?
    private var localClick: Any?
    private weak var anchor: NSStatusBarButton?
    /// Set when a frame change didn't come from us — i.e. the user dragged it.
    private var userMoved = false
    private var expectedFrame: NSRect = .zero

    var isOpen: Bool { panel?.isVisible ?? false }
    var onVisibilityChange: ((Bool) -> Void)?

    // MARK: - Show / hide

    func toggle(relativeTo button: NSStatusBarButton?, settings: @escaping () -> Void) {
        // Clicking the item it is already hanging from closes it; clicking a
        // different agent's item moves it there. Closing in that case would
        // read as the click having failed.
        if isOpen, button == nil || button === anchor { close(); return }
        show(relativeTo: button, settings: settings)
    }

    func show(relativeTo button: NSStatusBarButton?, settings: @escaping () -> Void) {
        anchor = button ?? anchor
        // Each fresh open starts from the menu bar again unless it's pinned to
        // a spot the user chose.
        if !Settings.dashboardPinned { userMoved = false }
        let view = DashboardView(
            store: AgentStore.shared,
            onSettings: settings,
            onTogglePin: { [weak self] in self?.applyPinState() },
            onClose: { [weak self] in self?.close() },
            onResize: { [weak self] in
                // SwiftUI reports the new size before it has finished laying
                // out; resize on the next tick so fittingSize is settled.
                DispatchQueue.main.async { self?.relayout() }
            })

        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            // Through PanelChrome, not a plain NSHostingView: this panel is
            // non-activating, so without its first-mouse handling AppKit spends
            // the first click raising the window and the sort buttons only
            // answer every second time. This code had drifted into a private
            // copy of PanelChrome.host and so missed that fix entirely.
            self.hosting = PanelChrome.host(view, in: panel)
        }

        layout()
        panel.orderFrontRegardless()
        startWatchingForOutsideClicks()
        onVisibilityChange?(true)
    }

    func close() {
        panel?.orderOut(nil)
        stopWatchingForOutsideClicks()
        onVisibilityChange?(false)
    }

    /// Re-lay-out after the content changes size (agents come and go).
    func relayout() { if isOpen { layout() } }

    private func applyPinState() {
        layout()
        // Pinned panels shouldn't vanish on the next stray click.
        if Settings.dashboardPinned { stopWatchingForOutsideClicks() }
        else { startWatchingForOutsideClicks() }
    }

    // MARK: - Construction

    private func makePanel() -> NSPanel {
        // Through PanelChrome, not a copy of it. This method had drifted into a
        // private duplicate of it for the second time: the first cost the
        // dashboard its first-click handling, and the second its backdrop —
        // every panel got the darker tint except the one you look at.
        let panel = PanelChrome.makePanel()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // Ignore the moves we make ourselves.
                guard abs(panel.frame.origin.x - self.expectedFrame.origin.x) > 1
                        || abs(panel.frame.origin.y - self.expectedFrame.origin.y) > 1
                else { return }
                self.userMoved = true
                Settings.dashboardOrigin = panel.frame.origin
            }
        }

        self.panel = panel
        return panel
    }

    // MARK: - Placement

    private func layout() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }

        let screenHeight = (anchor?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        size.height = min(size.height, screenHeight - 20)

        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The button's frame in screen coordinates, or nothing to hang from.
        let anchorFrame: CGRect? = anchor.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        let origin = DashboardPlacement.origin(
            saved: Settings.dashboardOrigin, userMoved: userMoved,
            pinned: Settings.dashboardPinned, anchor: anchorFrame,
            visible: visible, size: size)

        let frame = NSRect(origin: origin, size: size)
        expectedFrame = frame
        panel.setFrame(frame, display: true)
    }

    // MARK: - Dismissal

    private func startWatchingForOutsideClicks() {
        guard outsideClick == nil, !Settings.dashboardPinned else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !Settings.dashboardPinned else { return }
                self.close()
            }
        }
        // A click inside our own app but outside the panel also dismisses.
        localClick = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, !Settings.dashboardPinned, event.window !== self.panel {
                Task { @MainActor in self.close() }
            }
            return event
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        outsideClick = nil
        localClick = nil
    }
}
