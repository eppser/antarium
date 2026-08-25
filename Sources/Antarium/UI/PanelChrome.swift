import AppKit
import SwiftUI

/// Shared construction for Antarium's floating panels — borderless, material
/// backed, rounded. Used by both the agent dashboard and the settings panel so
/// they are the same object with different contents.
@MainActor
enum PanelChrome {
    /// A borderless window reports `canBecomeKey == false`, and a
    /// non-activating panel never takes focus from a click. Between them a text
    /// field inside one can never receive a keystroke — the harness filter was
    /// inert for exactly this reason. Only the panel that needs typing opts in;
    /// the dashboard has no field and should keep its hands off your focus.
    /// A veil over the vibrancy. The popover material is translucent, so on a
    /// bright desktop the panel takes the wallpaper's colour and the rows lose
    /// their contrast against it. This keeps the translucency and deepens it.
    ///
    /// It redraws itself on an appearance change rather than baking a CGColor
    /// once: a layer colour is not dynamic, so a panel built in light mode
    /// would have stayed light after the Mac switched to dark.
    private final class Tint: NSView {
        var darkness: CGFloat = 0.38
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // A veil that deepens a dark panel only muddies a light one, so
            // light appearance takes a fraction of it.
            layer?.backgroundColor = NSColor.black
                .withAlphaComponent(dark ? darkness : darkness * 0.28).cgColor
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    static func makePanel(keyboard: Bool = false) -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        let style: NSWindow.StyleMask = keyboard
            ? [.borderless] : [.borderless, .nonactivatingPanel]
        let panel: NSPanel = keyboard
            ? KeyablePanel(contentRect: frame, styleMask: style,
                           backing: .buffered, defer: false)
            : NSPanel(contentRect: frame, styleMask: style,
                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        panel.contentView = effect

        // 0 leaves the plain material. Negative lifts the panel off a dark
        // desktop; positive deepens it against a bright one. The caps stop it
        // going opaque either way, which would lose the point of a vibrant
        // panel.
        let darkness = min(max(Config.double("panelDarkness") ?? -0.10, -0.5), 0.85)
        if darkness != 0 {
            Log.debug("panel", "backdrop darkness \(darkness)")
            let tint = Tint(frame: effect.bounds)
            tint.darkness = darkness
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            effect.addSubview(tint)
        }
        return panel
    }

    /// A menu bar panel is never the key window — the user is working in their
    /// editor, and the panel is deliberately non-activating so that clicking it
    /// does not steal focus. The cost is that AppKit spends the first click
    /// making the window front and only the second reaches the control beneath,
    /// which reads as a button that sometimes ignores you. Accepting first
    /// mouse delivers both.
    final class ClickThrough<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        required init(rootView: V) { super.init(rootView: rootView) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }
    }

    /// Pins a SwiftUI view to every edge, so the panel's frame drives its size.
    static func host<V: View>(_ view: V, in panel: NSPanel) -> NSHostingView<V> {
        let hosting = ClickThrough(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        guard let container = panel.contentView else { return hosting }
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return hosting
    }

    /// Hangs a panel under a status item, clamped to the screen.
    static func place(_ panel: NSPanel, under anchor: NSStatusBarButton?, size: NSSize) {
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        var x = visible.maxX - size.width - margin
        if let button = anchor, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            x = min(max(frame.maxX - size.width, visible.maxX - size.width - margin),
                    visible.maxX - size.width - margin)
        }
        panel.setFrame(NSRect(x: x, y: visible.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }
}
