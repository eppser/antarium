import AppKit
import Foundation
import Testing
@testable import Antarium

/// Colours named in config.json.
///
/// `rowColors` and `accent` are the two settings a user writes by hand rather
/// than clicks, so the parser behind them reads text nobody validated. It had
/// no tests at all. What matters is not the arithmetic — it is that a value
/// this cannot read is refused, because every caller already falls back to a
/// colour that works, and a silently misread value is a colour nobody asked
/// for.
@Suite("Colours named in the config file")
struct AccentAndRowColorTests {

    private func rgb(_ color: NSColor?) -> (Int, Int, Int)? {
        guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
        return (Int((srgb.redComponent * 255).rounded()),
                Int((srgb.greenComponent * 255).rounded()),
                Int((srgb.blueComponent * 255).rounded()))
    }

    @Test("A six-digit hex reads as itself, with or without the hash")
    func ordinaryHex() {
        #expect(rgb(AgentStyle.color(hex: "#1E7FC2")).map { $0 == (30, 127, 194) } == true)
        #expect(rgb(AgentStyle.color(hex: "1E7FC2")).map { $0 == (30, 127, 194) } == true)
        #expect(rgb(AgentStyle.color(hex: "  #1E7FC2  ")).map { $0 == (30, 127, 194) } == true)
        // Case is not significance.
        #expect(rgb(AgentStyle.color(hex: "#1e7fc2")) ?? (0, 0, 0)
                == rgb(AgentStyle.color(hex: "#1E7FC2")) ?? (1, 1, 1))
    }

    @Test("The ends of the range are read, not clipped")
    func extremes() {
        #expect(rgb(AgentStyle.color(hex: "#000000")).map { $0 == (0, 0, 0) } == true)
        #expect(rgb(AgentStyle.color(hex: "#FFFFFF")).map { $0 == (255, 255, 255) } == true)
    }

    /// The one that was wrong. `UInt32(_:radix:)` accepts a leading sign, so
    /// "#+FFFFF" is six characters, parses as 0x0FFFFF, and became a colour
    /// nobody wrote — a misreading rather than a refusal.
    @Test("A value that is not six hex digits is refused",
          arguments: ["#+FFFFF", "#-FFFFF", "#12345", "#1234567", "", "#", "#GGGGGG",
                      "#12 456", "rebeccapurple", "#12345\u{200B}"])
    func malformedIsRefused(raw: String) {
        #expect(AgentStyle.color(hex: raw) == nil,
                Comment(rawValue: "\(raw) was read as a colour"))
    }

    /// Two rows exist, and the config may name fewer colours than that — or
    /// more, or none.
    @Test("A row past the end of the palette reuses its last colour")
    func rowsBeyondThePalette() {
        let one = ["#FF0000"]
        #expect(rgb(AgentStyle.rowColor(0, colors: one))
                ?? (0, 0, 0) == rgb(AgentStyle.rowColor(1, colors: one)) ?? (1, 1, 1))
        let two = ["#FF0000", "#00FF00"]
        #expect(rgb(AgentStyle.rowColor(0, colors: two))
                ?? (0, 0, 0) != rgb(AgentStyle.rowColor(1, colors: two)) ?? (0, 0, 0))
        #expect(rgb(AgentStyle.rowColor(5, colors: two))
                ?? (0, 0, 0) == rgb(AgentStyle.rowColor(1, colors: two)) ?? (1, 1, 1))
    }

    /// A negative index used to walk the array backwards, which is a crash
    /// rather than a wrong colour.
    @Test("A negative row is the first row, not a crash")
    func negativeRow() {
        #expect(rgb(AgentStyle.rowColor(-3, colors: ["#FF0000", "#00FF00"]))
                ?? (0, 0, 0) == rgb(AgentStyle.rowColor(0, colors: ["#FF0000", "#00FF00"]))
                ?? (1, 1, 1))
        #expect(rgb(AgentStyle.rowColor(-1, colors: [])) != nil,
                "an empty palette and a negative row together produced nothing")
    }

    /// A palette full of nonsense falls back rather than failing: the row has
    /// to be drawn in something.
    @Test("An unreadable palette entry falls back to the shipped colour")
    func unreadableEntryFallsBack() throws {
        // Both sides through `rowColor`, so both get the same appearance
        // treatment. Comparing the drawn colour against the raw hex asserted
        // that `adaptive` is the identity, which it is on a dark menu bar and
        // is not on a light one — so this passed where it was written and
        // failed in continuous integration, on a machine whose appearance
        // nobody chose.
        let fallback = try #require(rgb(AgentStyle.rowColor(0, colors: ["not a colour"])),
                                    "a palette of nonsense produced no colour at all")
        let shipped = try #require(
            rgb(AgentStyle.rowColor(0, colors: [AgentStyle.defaultRowColors[0]])))
        #expect(fallback == shipped,
                Comment(rawValue: "nonsense drew \(fallback), the shipped colour is \(shipped)"))
    }

    /// Every shipped accent has to be readable, or the preset list offers a
    /// colour the parser rejects.
    @Test("Every preset accent parses")
    func presetsParse() {
        #expect(Accents.all.count >= 6)
        for accent in Accents.all {
            #expect(AgentStyle.color(hex: accent.hex) != nil,
                    Comment(rawValue: "\(accent.id) names \(accent.hex), which is not a colour"))
            #expect(Accents.named(accent.id)?.hex == accent.hex)
        }
        #expect(Accents.named("no-such-accent") == nil)
    }
}
