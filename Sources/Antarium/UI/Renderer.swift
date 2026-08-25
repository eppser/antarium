import AppKit

/// Everything one menu bar item's image depends on. `Equatable` so the app can
/// skip re-rendering — and re-laying-out the menu bar — when nothing moved.
struct StatusRender: Equatable {
    struct Row: Equatable {
        /// 0...1 of the bar to light, already resolved for the meter mode.
        let fill: Double
        let percentText: String
        let resetText: String
        let severity: Severity
    }
    var agentID: String
    /// One or two rows. Providers with a single meaningful window get one.
    var rows: [Row]
    /// Drawn instead of the bars when there is no reading at all.
    var message: String?
    /// The numbers are real but no longer fresh.
    var stale: Bool = false

    static func rows(for snapshot: Snapshot) -> [Row] {
        let mode = Settings.meterMode
        return snapshot.gauges.prefix(2).map { g in
            Row(fill: mode == .used ? g.used : g.remaining,
                percentText: mode == .used ? g.usedPercentText : g.remainingPercentText,
                resetText: Format.shortCountdown(to: g.resetsAt),
                // Severity is headroom either way, so the colours never flip
                // meaning when the mode changes.
                severity: g.severity)
        }
    }
}

/// Draws one agent's gauge. Pure: no state, no side effects.
@MainActor
enum Renderer {

    // MARK: - Metrics
    //
    // The menu bar gives us 24pt; 22 leaves a hairline of breathing room top
    // and bottom. Everything else is derived from that so the layout scales
    // as one unit.

    private static let height: CGFloat = 22
    private static let rowHeight: CGFloat = 11
    private static let hPad: CGFloat = 3
    private static let gap: CGFloat = 4
    /// The reset time belongs to its bar, so it sits closer than the other gaps.
    private static let resetGap: CGFloat = 3
    /// The mark labels the numbers beside it — close, but the Claude burst
    /// radiates to the very edge of its box, so it needs a little air or its
    /// Breathing room between the mark and the first digit. Fixed rather than
    /// configurable: the setting outlived its control, and a stored 0 left the
    /// logo touching the numbers with no way to put it back.
    private static let glyphGap: CGFloat = 3
    private static let glyphSize: CGFloat = 15.5

    /// Narrow, tightly-spaced beams — the Little Snitch proportion. Beam count
    /// is configurable (`"beams"` in config.json) because density is taste.
    private static var segments: Int { Settings.beams }
    private static let segW: CGFloat = 3
    private static let segGap: CGFloat = 1.4
    private static var barW: CGFloat {
        CGFloat(segments) * segW + CGFloat(segments - 1) * segGap
    }
    private static let barH: CGFloat = 8.6
    private static let segRadius: CGFloat = 1.1

    // Type: one hero (the percentage) and one supporting weight, rather than
    // three shades of grey.
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    private static let contextFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    private static let messageFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    /// Floor for the percentage column: two digits. Sizing it to "100%" instead
    /// padded every ordinary two-digit reading with a dead digit's width, which
    /// is what pushed the mark away from the numbers. Sizing it to the actual
    /// text would jitter the menu bar every time a digit was gained or lost, so
    /// the floor keeps the common 10–99% range rock steady and only the rare
    /// "100%" / "<1%" widens it.
    private static let minPercentW: CGFloat = measure("99%", percentFont).width

    private static func percentW(for rows: [StatusRender.Row]) -> CGFloat {
        max(minPercentW, rows.map { measure($0.percentText, percentFont).width }.max() ?? 0)
    }
    private static let resetW: CGFloat = measure("59m", contextFont).width

    /// The supporting text sits at a fixed fraction of the label colour.
    /// `secondaryLabelColor` and below wash out badly against the menu bar's
    /// translucency, which is what made the old labels look muddy.
    private static let contextAlpha: CGFloat = 0.68

    static func width(for render: StatusRender) -> CGFloat {
        var w = hPad + glyphSize + glyphGap
        if let message = render.message {
            return w + measure(message, messageFont).width + hPad
        }
        w += percentW(for: render.rows) + gap
        w += barW + resetGap + resetW
        return w + hPad
    }

    /// Rendered at the given backing scale so beams stay crisp on Retina and
    /// on a 1x external display.
    static func image(_ render: StatusRender, appearance: NSAppearance, scale: CGFloat) -> NSImage {
        let size = NSSize(width: width(for: render), height: height)
        return bitmap(size: size, scale: scale, appearance: appearance) {
            draw(render, in: NSRect(origin: .zero, size: size))
        }
    }

    // MARK: - Drawing

    private static func draw(_ render: StatusRender, in bounds: NSRect) {
        // Always full strength. A dimmed item reads as "broken" from the menu
        // bar, and a refresh that failed still shows numbers that were true —
        // how old they are belongs in the tooltip, not in the contrast.
        let alpha: CGFloat = 1.0
        let glyphRect = NSRect(x: bounds.minX + hPad, y: bounds.midY - glyphSize / 2,
                               width: glyphSize, height: glyphSize)
        // The mark stays monochrome — colour belongs to the bars alone.
        Glyphs.draw(render.agentID, in: glyphRect,
                    color: NSColor.labelColor.withAlphaComponent(0.85 * alpha))

        let contentX = glyphRect.maxX + glyphGap
        if let message = render.message {
            let s = NSAttributedString(string: message, attributes: [
                .font: messageFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(contextAlpha),
            ])
            s.draw(at: NSPoint(x: contentX, y: bounds.midY - s.size().height / 2))
            return
        }

        // One row centres; two rows stack.
        let rows = Array(render.rows.prefix(2))
        for (i, row) in rows.enumerated() {
            let y = rows.count == 1
                ? bounds.midY - rowHeight / 2
                : bounds.maxY - CGFloat(i + 1) * rowHeight
            draw(row, alpha: alpha, agentID: render.agentID, index: i,
                 percentW: percentW(for: rows),
                 in: NSRect(x: contentX, y: y, width: bounds.maxX - contentX, height: rowHeight))
        }
    }

    private static func draw(_ row: StatusRender.Row, alpha: CGFloat,
                             agentID: String, index: Int, percentW: CGFloat,
                             in rect: NSRect) {
        var x = rect.minX
        let context = NSColor.labelColor.withAlphaComponent(contextAlpha * alpha)

        if true {
            text(row.percentText, font: percentFont,
                 color: NSColor.labelColor.withAlphaComponent(alpha),
                 at: x, width: percentW, align: .right, in: rect)
            x += percentW + gap
        }

        drawBar(fill: row.fill, severity: row.severity, agentID: agentID, row: index,
                alpha: alpha, in: NSRect(x: x, y: rect.midY - barH / 2, width: barW, height: barH))
        x += barW + resetGap

        // Always shown: with no 5H/7D label, "2h" versus "6d" is what tells the
        // two windows apart.
        text(row.resetText, font: contextFont, color: context,
             at: x, width: resetW, align: .left, in: rect)
    }

    /// Lights `fill` of the bar — consumption or headroom, per the meter mode.
    private static func drawBar(fill: Double, severity: Severity, agentID: String, row: Int,
                                alpha: CGFloat, in rect: NSRect) {
        let tint = color(for: severity, agentID: agentID, row: row).withAlphaComponent(alpha)
        // The reference meter keeps its unlit beams clearly visible rather than
        // near-invisible, which also makes the bar's length readable at a glance.
        let track = NSColor.labelColor.withAlphaComponent(0.26 * alpha)
        // Every lit beam is the same solid colour — no half-lit boundary beam.
        // Any nonzero usage lights at least one, so "barely started" still reads
        // as started rather than as empty.
        let lit = litCount(fill)
        for i in 0..<segments {
            let seg = NSRect(x: rect.minX + CGFloat(i) * (segW + segGap),
                             y: rect.minY, width: segW, height: rect.height)
            (i < lit ? tint : track).setFill()
            NSBezierPath(roundedRect: seg, xRadius: segRadius, yRadius: segRadius).fill()
        }
    }

    /// How many beams to light for a 0...1 fill. Any nonzero usage lights at
    /// least one, so "barely started" reads as started rather than as empty.
    static func litCount(_ fill: Double, of count: Int? = nil) -> Int {
        let n = count ?? segments
        let clamped = max(0, min(1, fill))
        guard clamped > 0 else { return 0 }
        return max(1, min(n, Int((clamped * Double(n)).rounded())))
    }

    /// One accent for every agent while there's headroom; the warning steps are
    /// shared too, so "running out" looks the same wherever you see it.
    static func color(for severity: Severity, agentID: String, row: Int = 0) -> NSColor {
        switch Settings.palette {
        case .vivid:
            // The row keeps its hue until the window is actually spent; a bar
            // that has run out is the one state worth shouting about.
            return severity == .critical ? criticalRed : AgentStyle.rowColor(row)
        case .semantic:
            switch severity {
            case .normal:   return .systemGreen
            case .low:      return .systemOrange
            case .critical: return .systemRed
            }
        case .accent:
            break
        }
        switch severity {
        case .normal:   return AgentStyle.accent
        // Deliberately brighter and yellower than any accent, so the step away
        // from "healthy" is visible even for a warm accent like clay.
        case .low:      return NSColor(srgbRed: 0.949, green: 0.702, blue: 0.208, alpha: 1)
        case .critical: return criticalRed
        }
    }

    static let criticalRed = NSColor(srgbRed: 0.965, green: 0.271, blue: 0.361, alpha: 1)

    // MARK: - Primitives

    private enum Align { case left, right }

    private static func text(_ string: String, font: NSFont, color: NSColor,
                             at x: CGFloat, width: CGFloat, align: Align, in rect: NSRect) {
        let s = NSAttributedString(string: string,
                                   attributes: [.font: font, .foregroundColor: color])
        let size = s.size()
        let originX = align == .left ? x : x + width - size.width
        // draw(at:) takes the lower-left of the line box in an unflipped context.
        s.draw(at: NSPoint(x: originX, y: rect.midY - size.height / 2))
    }

    private static func measure(_ s: String, _ font: NSFont) -> NSSize {
        NSAttributedString(string: s, attributes: [.font: font]).size()
    }

    /// Renders into a bitmap at an explicit scale, with dynamic colours
    /// resolved against the appearance the menu bar is actually using.
    static func bitmap(size: NSSize, scale: CGFloat,
                       appearance: NSAppearance, _ body: () -> Void) -> NSImage {
        let px = max(1.0, scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * px).rounded()),
            pixelsHigh: Int((size.height * px).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: size) }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance(body)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}

// MARK: - Dropdown chips

extension Renderer {
    /// A standalone bar for a dropdown row, at menu scale.
    static func chip(fill: Double, severity: Severity, agentID: String, row: Int,
                     appearance: NSAppearance, scale: CGFloat) -> NSImage {
        let count = 8
        let w: CGFloat = 5, g: CGFloat = 2, h: CGFloat = 9
        let size = NSSize(width: CGFloat(count) * w + CGFloat(count - 1) * g, height: h)
        return bitmap(size: size, scale: scale, appearance: appearance) {
            let tint = color(for: severity, agentID: agentID, row: row)
            let track = NSColor.labelColor.withAlphaComponent(0.26)
            let lit = litCount(fill, of: count)
            for i in 0..<count {
                let seg = NSRect(x: CGFloat(i) * (w + g), y: 0, width: w, height: h)
                (i < lit ? tint : track).setFill()
                NSBezierPath(roundedRect: seg, xRadius: 1.4, yRadius: 1.4).fill()
            }
        }
    }
}

// MARK: - Menu swatches

extension Renderer {
}
