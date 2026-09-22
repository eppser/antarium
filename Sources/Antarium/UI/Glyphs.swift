import AppKit

/// Monochrome agent marks, drawn as vectors so they stay crisp at 14pt and
/// adopt the menu bar's own label colour like every other status item.
///
/// Deliberately simplified: at this size a faithful logo turns to mud, so each
/// mark keeps only the silhouette that makes it recognisable.
@MainActor
enum Glyphs {

    /// Masks extracted from the installed apps by `tools/extract-icons.sh`.
    private static var cache: [String: NSImage?] = [:]
    /// Every other cache in the app is locked; this one is reached only from
    /// the main thread today, and a lock costs nothing next to decoding a PNG.
    private static let lock = NSLock()

    /// Harnesses that are the same product wearing a different hat, and so
    /// carry the same mark: Cursor's CLI and its editor, Codex's CLI and the
    /// desktop app inside ChatGPT.
    static let alias = ["cursor-cli": "cursor", "codex-desktop": "codex"]

    /// A descriptor may name its mark, so a contributed harness can wear an
    /// existing icon without a code change.
    ///
    /// Three answers in order, and the order is the whole of it: a mark the
    /// descriptor declares, then the alias table for the harnesses that are
    /// one product wearing two hats, then the agent's own id. Getting it
    /// wrong puts another agent's logo beside a row, which is a misstatement
    /// rather than a cosmetic slip — the icon is how a glance tells two rows
    /// apart.
    ///
    /// The catalogue is a parameter so the order can be checked without the
    /// harness folder on this Mac deciding the answer.
    static func markName(_ agentID: String,
                         in descriptors: [HarnessDescriptor] = HarnessDescriptor.all()) -> String {
        if let declared = descriptors.first(where: { $0.id == agentID })?.resolvedMark {
            return declared
        }
        return alias[agentID] ?? agentID
    }

    private static func mark(for agentID: String) -> NSImage? {
        lock.lock()
        if let hit = cache[agentID] { lock.unlock(); return hit }
        lock.unlock()

        let file = markName(agentID)
        let url = AppResources.bundle.url(
            forResource: file, withExtension: "png", subdirectory: "marks")
        let image = url.flatMap { NSImage(contentsOf: $0) }

        lock.lock(); cache[agentID] = image; lock.unlock()
        return image
    }

    /// Standalone tinted image, for SwiftUI and menus.
    static func image(_ agentID: String, size: CGFloat, color: NSColor,
                      appearance: NSAppearance, scale: CGFloat = 2) -> NSImage {
        Renderer.bitmap(size: NSSize(width: size, height: size), scale: scale,
                        appearance: appearance) {
            draw(agentID, in: NSRect(x: 0, y: 0, width: size, height: size), color: color)
        }
    }

    static func draw(_ agentID: String, in rect: NSRect, color: NSColor) {
        // Real logo if we have one; the drawn fallbacks below cover agents
        // whose app isn't installed on this Mac.
        if let mask = mark(for: agentID) {
            NSGraphicsContext.saveGraphicsState()
            // Clip so `sourceAtop` can only tint this glyph, never earlier art.
            NSBezierPath(rect: rect).setClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            // sourceIn, not sourceAtop: the mask is white, and sourceAtop would
            // let that white bleed through a partly transparent tint — which
            // left the mark looking bright when the reading had gone stale.
            rect.fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        color.setFill()
        color.setStroke()
        switch markName(agentID) {
        case "claude-code": burst(in: rect)
        case "codex":       rosette(in: rect)
        default:            initialLetter(fallbackLabel(agentID), in: rect, color: color)
        }
    }

    /// Claude — a radiating burst.
    private static func burst(in rect: NSRect) {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.48
        let inner = outer * 0.30
        let path = NSBezierPath()
        path.lineWidth = max(1.1, outer * 0.30)
        path.lineCapStyle = .round
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            path.move(to: NSPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            path.line(to: NSPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
        }
        path.stroke()
    }

    /// ChatGPT — the six-lobed knot, built from three crossed ellipses.
    /// Six separate circles turn to mush at 14pt; three strokes hold up.
    private static func rosette(in rect: NSRect) {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) * 0.46
        for i in 0..<3 {
            let transform = NSAffineTransform()
            transform.translateX(by: c.x, yBy: c.y)
            transform.rotate(byDegrees: CGFloat(i) * 60)
            let ellipse = NSBezierPath(ovalIn: NSRect(x: -r, y: -r * 0.52,
                                                      width: r * 2, height: r * 1.04))
            ellipse.transform(using: transform as AffineTransform)
            ellipse.lineWidth = max(1.0, r * 0.21)
            ellipse.stroke()
        }
    }


    /// Fallback for an agent with no mark of its own.
    /// The letters drawn for an agent whose artwork this app does not ship.
    ///
    /// It was the first letter of the id, which put an identical "O" in the
    /// menu bar for openclaw, opencode, openrouter and orca, and a shared
    /// letter on six others. A user with two of them enabled saw two items
    /// that differ only by their figures.
    ///
    /// The display name's capitals come first, because a vendor's own styling
    /// is where the distinction already lives — OpenRouter is OR and MiniMax
    /// is MM. A name with no second capital falls back to its first two
    /// letters, and a one-letter label is kept only where the name gives
    /// nothing more.
    ///
    /// Two characters is the ceiling: a 14pt glyph holds no more, and three
    /// would not help — Herdr and Hermes differ at their fourth letter.
    /// Three pairs still share a label, and the tests name them, so a new
    /// harness landing on a taken one is a decision rather than a surprise.
    /// Every item also carries the provider's name as its tooltip and its
    /// accessibility label, which is what actually tells two apart.
    static func fallbackLabel(_ agentID: String,
                              in descriptors: [HarnessDescriptor]
                                  = HarnessDescriptor.all()) -> String {
        let name = descriptors.first { $0.id == agentID }?.name ?? agentID
        let capitals = name.filter(\.isUppercase)
        if capitals.count >= 2 { return String(capitals.prefix(2)) }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return (String(a) + String(b)).uppercased()
        }
        let letters = name.filter(\.isLetter)
        return String(letters.prefix(2)).uppercased()
    }

    /// The face a drawn label is set in.
    ///
    /// Two characters need a smaller one than a single letter to sit in the
    /// same box — at the one-letter size they run past it. Separate so the
    /// fit can be measured rather than eyeballed.
    static func labelFont(for label: String, in height: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: height * (label.count > 1 ? 0.52 : 0.72), weight: .bold)
    }

    private static func initialLetter(_ letter: String, in rect: NSRect, color: NSColor) {
        let font = labelFont(for: letter, in: rect.height)
        let s = NSAttributedString(string: letter,
                                   attributes: [.font: font, .foregroundColor: color])
        let size = s.size()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
