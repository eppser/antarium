import AppKit

/// An optional second menu bar item: the word AGENTS with status-coloured
/// counts beneath it, so the machine's state is legible without opening
/// anything.
@MainActor
final class CountItem: NSObject {
    /// What the item draws. Equatable so an unchanged tally costs no redraw.
    struct Tally: Equatable {
        var working = 0     // busy or in a shell
        var waiting = 0     // finished its turn, wants you
        var unknown = 0
        var ended = 0       // process gone, session file left behind

        var total: Int { working + waiting + ended + unknown }

        init(_ rows: [AgentRow] = []) {
            for row in rows {
                switch row.state {
                // Green in the menu bar too: a looping agent is fine, not idle.
                case .working, .shell, .looping: working += 1
                case .waiting: waiting += 1
                case .cloud, .unobserved: unknown += 1
                case .ended: ended += 1
                }
            }
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastTally: Tally?
    /// What the last drawing was resolved against. The menu bar's appearance
    /// arrives after the item is created and can change again a moment later,
    /// and the colours are baked in at draw time — so a redraw is needed when
    /// it moves, not only when the numbers do.
    private var lastAppearance: NSAppearance.Name?
    private let onClick: () -> Void
    private let onRightClick: () -> Void

    init(onClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
        self.onClick = onClick
        self.onRightClick = onRightClick
        super.init()
        statusItem.autosaveName = "Antarium.count"
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        render(Tally())
        renderWhenAttached()
    }

    /// The menu bar's appearance is unknowable until the button joins a window,
    /// which happens after init returns. Redraw once it has — otherwise a
    /// freshly created item bakes in black text and keeps it until something
    /// else forces a redraw. This is what made the counts black after the
    /// item was switched off and on again.
    private func renderWhenAttached(_ attempts: Int = 6) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.forceRender()
            // Keep going even once the window exists. Stopping there was the
            // bug: the window arrives with a provisional appearance and settles
            // afterwards, so a count created at the wrong moment stayed black.
            self.renderWhenAttached(attempts - 1)
        }
    }

    func dispose() { NSStatusBar.system.removeStatusItem(statusItem) }

    func update(with rows: [AgentRow]) { render(Tally(rows)) }

    private var menuBarAppearance: NSAppearance {
        statusItem.button?.window?.effectiveAppearance
            ?? statusItem.button?.effectiveAppearance
            ?? NSApp.effectiveAppearance
    }

    /// Redraw even when the tally is unchanged — the menu bar's appearance can
    /// change under us (dark mode, or a wallpaper that tints the bar), and the
    /// label colours are baked in at draw time.
    func forceRender() {
        let tally = lastTally ?? Tally()
        lastTally = nil
        lastAppearance = nil
        render(tally)
    }

    @objc private func clicked() {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        isRight ? onRightClick() : onClick()
    }

    private func render(_ tally: Tally) {
        let appearance = menuBarAppearance
        guard tally != lastTally || appearance.name != lastAppearance else { return }
        lastTally = tally
        lastAppearance = appearance.name
        // Before the button joins a window it has no useful appearance of its
        // own; fall back to the app's rather than drawing with the default.
        let scale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        statusItem.button?.image = CountRenderer.image(tally, appearance: appearance, scale: scale)
        statusItem.button?.toolTip = tally.total == 0
            ? "No agent sessions"
            : "\(tally.working) working · \(tally.waiting) waiting"
                + (tally.ended > 0 ? " · \(tally.ended) ended" : "")
                + (tally.unknown > 0 ? " · \(tally.unknown) status unknown" : "")
    }
}

/// Draws the two-line count badge.
@MainActor
enum CountRenderer {
    private static let height: CGFloat = 22
    private static let hPad: CGFloat = 3
    private static let dot: CGFloat = 5
    private static let gap: CGFloat = 3
    private static let groupGap: CGFloat = 7

    private static let titleFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    private static func groups(_ tally: CountItem.Tally) -> [(NSColor, Int)] {
        var out: [(NSColor, Int)] = []
        if tally.working > 0 { out.append((.systemGreen, tally.working)) }
        if tally.waiting > 0 { out.append((.systemOrange, tally.waiting)) }
        if tally.unknown > 0 { out.append((.systemBlue,tally.unknown)) }
        if tally.ended > 0 { out.append((.secondaryLabelColor, tally.ended)) }
        return out.isEmpty ? [(.tertiaryLabelColor, 0)] : out
    }

    static func image(_ tally: CountItem.Tally, appearance: NSAppearance,
                      scale: CGFloat) -> NSImage {
        let parts = groups(tally)
        let title = NSAttributedString(string: "AGENTS", attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55),
            .kern: 0.9,
        ])
        let countWidths = parts.map { measure("\($0.1)").width }
        let countsWidth = countWidths.reduce(0, +)
            + CGFloat(parts.count) * (dot + gap)
            + CGFloat(max(0, parts.count - 1)) * groupGap
        let width = max(title.size().width, countsWidth) + hPad * 2

        return Renderer.bitmap(size: NSSize(width: width, height: height),
                               scale: scale, appearance: appearance) {
            // Title on top, centred.
            title.draw(at: NSPoint(x: (width - title.size().width) / 2, y: height - 9.5))

            // Dot + count pairs beneath, centred as a block.
            var x = (width - countsWidth) / 2
            let midY: CGFloat = 5.5
            for (index, part) in parts.enumerated() {
                part.0.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: midY - dot / 2,
                                            width: dot, height: dot)).fill()
                x += dot + gap
                let text = NSAttributedString(string: "\(part.1)", attributes: [
                    .font: countFont, .foregroundColor: NSColor.labelColor,
                ])
                text.draw(at: NSPoint(x: x, y: midY - text.size().height / 2))
                x += countWidths[index] + groupGap
            }
        }
    }

    private static func measure(_ s: String) -> NSSize {
        NSAttributedString(string: s, attributes: [.font: countFont]).size()
    }
}
