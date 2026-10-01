import AppKit
import SwiftUI

/// Everything Antarium can be told to do, in one place.
///
/// Settings are plain statics over a JSON file, not observable, so this holds a
/// revision counter: every change bumps it, which redraws the panel and its
/// live preview, then applies the change to the menu bar.
@MainActor
final class SettingsModel: ObservableObject {
    /// Set by the panel so the header's close button can dismiss it.
    var onClose: (() -> Void)?
    @Published private(set) var revision = 0
    var onApply: (() -> Void)?

    func update(_ change: () -> Void) {
        change()
        revision += 1
        SettingsBus.shared.changed()
        onApply?()
    }
}

@MainActor
final class SettingsPanel: NSObject {
    /// One settings window, for the same reason as the dashboard.
    static let shared = SettingsPanel()

    /// Private, so the single instance is a fact of the type rather than a
    /// convention someone has to remember.
    private override init() { super.init() }

    /// Which item it is hanging from, so a second request can tell "close this"
    /// from "open it over here".
    private weak var anchorButton: NSStatusBarButton?

    private var panel: NSPanel?
    private var hosting: NSHostingView<SettingsView>?
    private var dismiss: Any?
    /// Set when a frame change didn't come from us — i.e. you dragged it.
    /// Every settings change re-lays the panel out, and re-laying it out used
    /// to re-place it under the menu bar item, so changing anything after
    /// moving the window snatched it back to the corner.
    private var userMoved = false
    private var expectedFrame: NSRect = .zero
    private var moveObserver: Any?
    private let model = SettingsModel()

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle(under anchor: NSStatusBarButton?, onApply: @escaping () -> Void) {
        // One window: a second request raises the one already open rather than
        // building another beside it.
        if isOpen, anchor == nil || anchor === anchorButton { close(); return }
        show(under: anchor, onApply: onApply)
    }

    func show(under anchor: NSStatusBarButton?, onApply: @escaping () -> Void) {
        anchorButton = anchor ?? anchorButton
        model.onApply = { [weak self] in onApply(); self?.resize(under: anchor) }
        model.onClose = { [weak self] in self?.close() }
        let panel = self.panel ?? PanelChrome.makePanel(keyboard: true)
        self.panel = panel
        if moveObserver == nil {
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel else { return }
                    // Ignore the moves we make ourselves.
                    guard abs(panel.frame.origin.x - self.expectedFrame.origin.x) > 1
                            || abs(panel.frame.origin.y - self.expectedFrame.origin.y) > 1
                    else { return }
                    self.userMoved = true
                }
            }
        }
        if hosting == nil {
            hosting = PanelChrome.host(SettingsView(model: model), in: panel)
        }
        resize(under: anchor)
        panel.orderFrontRegardless()
        // Typing in the filter needs the window to be key, and a menu bar app
        // has to ask for the activation a normal app gets for free.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        if dismiss == nil {
            dismiss = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in Task { @MainActor in self?.close() }
            }
        }
    }

    func close() {
        // A fresh open starts from the menu bar item again.
        userMoved = false
        panel?.orderOut(nil)
        if let dismiss { NSEvent.removeMonitor(dismiss) }
        dismiss = nil
    }

    private func resize(under anchor: NSStatusBarButton?) {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }

        if userMoved {
            // Keep where you put it. Only the height follows the content, and
            // it grows downward from the same top edge so the title stays put.
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            if let screen = panel.screen ?? NSScreen.main {
                // The same rule the other panels use. Its own clamp inverted
                // on a screen smaller than the panel: the high bound falls
                // below the low one there, and clamping to it put the panel
                // off the left edge rather than leaving it at the margin.
                frame.origin = PanelPlacement.origin(
                    saved: frame.origin, userMoved: true, pinned: false, anchor: nil,
                    visible: screen.visibleFrame, size: size, margin: 0)
            }
            panel.setFrame(frame, display: true)
        } else {
            PanelChrome.place(panel, under: anchor, size: size)
        }
        expectedFrame = panel.frame
    }
}
