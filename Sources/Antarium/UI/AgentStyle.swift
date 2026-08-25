import AppKit

/// A named accent. One colour for every agent, so the row of items reads as a
/// single instrument rather than a paint chart.
struct Accent {
    let id: String
    let title: String
    let hex: String
}

enum Accents {
    /// Default. Deep enough to hold up on a light menu bar, bright enough on a
    /// dark one, and far from the amber and red used for the warning steps.
    static let ocean = Accent(id: "ocean", title: "Ocean Blue", hex: "#1E7FC2")

    static let all: [Accent] = [
        ocean,
        Accent(id: "deepsea",  title: "Deep Sea",  hex: "#0E6E8C"),
        Accent(id: "teal",     title: "Teal",      hex: "#12907F"),
        Accent(id: "clay",     title: "Clay",      hex: "#D87352"),
        Accent(id: "violet",   title: "Violet",    hex: "#7B5CFF"),
        Accent(id: "graphite", title: "Graphite",  hex: "#6E7781"),
    ]

    static func named(_ id: String) -> Accent? { all.first { $0.id == id } }
}

enum AgentStyle {
    /// Row colours for the vivid palette, sampled from the reference meter:
    /// a bright orchid over an azure. Override in config.json with
    /// `"rowColors": ["#RRGGBB", "#RRGGBB"]`.
    static let defaultRowColors = ["#E77DF9", "#389FF9"]

    static func rowColor(_ index: Int) -> NSColor {
        let hexes = Settings.rowColors
        let hex = hexes.isEmpty ? defaultRowColors[min(index, 1)]
                                : hexes[min(index, hexes.count - 1)]
        let base = color(hex: hex) ?? color(hex: defaultRowColors[min(index, 1)])!
        return adaptive(base)
    }

    /// Vivid colours are picked against a dark menu bar; the same hue washes
    /// out on a light one. Deepen and saturate it there so both read equally
    /// strongly, without shifting the hue.
    static func adaptive(_ base: NSColor) -> NSColor {
        guard let srgb = base.usingColorSpace(.sRGB) else { return base }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        let onLight = NSColor(hue: h,
                              saturation: min(sat * 1.25, 1),
                              brightness: max(b * 0.78, 0.30), alpha: a)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? srgb : onLight
        }
    }

    /// The accent in use: a preset id, or any hex the config file names.
    static var accent: NSColor {
        let raw = Settings.accent
        if let preset = Accents.named(raw), let c = color(hex: preset.hex) { return adaptive(c) }
        if let custom = color(hex: raw) { return adaptive(custom) }
        return color(hex: Accents.ocean.hex) ?? .systemBlue
    }

    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Which colour system the bars use.
enum Palette: String, CaseIterable {
    /// A colour per row — the short window and the long window each keep their
    /// own hue, the way a network meter distinguishes up from down. Same two
    /// colours for every agent, so the row of items still reads as one thing.
    /// Only a spent window overrides them, and only to red.
    case vivid
    /// One accent colour while there's room; amber, then red, as it runs out.
    case accent
    /// Apple's semantic green / amber / red throughout.
    case semantic

    var title: String {
        switch self {
        case .vivid: return "Vivid"
        case .accent: return "Accent"
        case .semantic: return "Semantic"
        }
    }
    var subtitle: String {
        switch self {
        case .vivid:    return "A colour per window, red when spent"
        case .accent:   return "One accent while there is headroom"
        case .semantic: return "Green, amber, red for every agent"
        }
    }
}
