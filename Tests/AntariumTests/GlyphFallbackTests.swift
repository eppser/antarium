import AppKit
import Foundation
import Testing
@testable import Antarium

/// The letters drawn for an agent whose artwork this app does not ship.
///
/// Nine of the twenty-five harnesses have a real mark. The rest draw a
/// label, and it used to be the first letter of the id — which put an
/// identical "O" in the menu bar for openclaw, opencode, openrouter and
/// orca, and a shared letter on six others. Ten of the sixteen were
/// indistinguishable from at least one neighbour.
///
/// Extracted vendor artwork is not something this repository carries, so a
/// drawn label is the answer and the question is only how well it
/// distinguishes.
@Suite("An agent without artwork still looks like itself", .serialized)
@MainActor
struct GlyphFallbackTests {

    private var descriptors: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    /// Agents drawn from a vector rather than from a label. These two are
    /// the whole of what this app ships as artwork.
    ///
    /// `Resources/marks/*.png` is in .gitignore. The README beside it says
    /// why: third-party application artwork is not distributed, the PNGs are
    /// for local development only, and the app falls back to a vector or a
    /// letter when one is absent. So on anybody's install but a developer's,
    /// twenty-three of the twenty-five harnesses draw a label.
    ///
    /// The first version of this suite asked the resource bundle which marks
    /// existed, which on this machine answered "nine" and in a fresh checkout
    /// answered "none" — so the suite passed here and failed everywhere else,
    /// and every mutation run in a throwaway checkout was reported as caught
    /// on the strength of it.
    private let vectorDrawn: Set<String> = ["claude-code", "codex"]

    /// Everything else, which is nearly everything.
    private var drawn: [HarnessDescriptor] {
        descriptors.filter { !vectorDrawn.contains($0.id) }
    }

    @Test("The two vector marks are the only artwork that ships")
    func artworkIsNotDistributed() throws {
        let ignore = try SourceText.read(".gitignore")
        #expect(ignore.contains("Resources/marks/*.png"),
                "agent artwork is being distributed, so this suite is about the wrong set")
        for id in vectorDrawn {
            #expect(descriptors.contains { $0.id == id },
                    Comment(rawValue: "\(id) no longer ships, so its vector is unreachable"))
        }
    }

    /// Nearly every agent draws one, and the tests below iterate that set —
    /// an empty one would satisfy all of them. This guard was written, lost
    /// in a rewrite, and is back.
    @Test("Nearly every agent draws a label")
    func thereAreSubjects() {
        #expect(drawn.count == descriptors.count - vectorDrawn.count,
                Comment(rawValue: "\(drawn.count) of \(descriptors.count) draw a label"))
        #expect(drawn.count >= 20,
                Comment(rawValue: "only \(drawn.count) harnesses draw a label"))
    }

    @Test("Every drawn label is one or two upper-case characters")
    func labelsAreShort() {
        for descriptor in drawn {
            let label = Glyphs.fallbackLabel(descriptor.id, in: descriptors)
            #expect(!label.isEmpty,
                    Comment(rawValue: "\(descriptor.id) draws nothing at all"))
            #expect(label.count <= 2,
                    Comment(rawValue: "\(descriptor.id) draws \(label), which will not fit"))
            #expect(label == label.uppercased(),
                    Comment(rawValue: "\(descriptor.id) draws \(label) in mixed case"))
        }
    }

    /// The vendor's own styling is where the distinction already lives.
    @Test("A name with two capitals is drawn as those capitals",
          arguments: [("openrouter", "OR"), ("minimax", "MM"), ("deepseek", "DS")])
    func capitalsAreUsed(id: String, expected: String) throws {
        try #require(descriptors.contains { $0.id == id }, "\(id) no longer ships")
        #expect(Glyphs.fallbackLabel(id, in: descriptors) == expected,
                Comment(rawValue: "\(id) draws "
                        + "\(Glyphs.fallbackLabel(id, in: descriptors))"))
    }

    /// Every label fits the box it is drawn in.
    ///
    /// A two-character label set at the single-letter size runs past the
    /// glyph, into the figures beside it. The catalogue carried an entry for
    /// that and it was not covered: reported as caught while the suite was
    /// failing for an unrelated reason, and surviving once the baseline was
    /// clean again.
    @Test("Every drawn label fits inside the glyph")
    func labelsFitTheGlyph() {
        // The menu bar's own glyph box, which is the smallest this is drawn in.
        let box = Renderer.glyphSize
        for descriptor in drawn {
            let label = Glyphs.fallbackLabel(descriptor.id, in: descriptors)
            let font = Glyphs.labelFont(for: label, in: box)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= box,
                    Comment(rawValue: "\(descriptor.id) draws \(label) at \(width)pt in a "
                            + "\(box)pt glyph"))
        }
    }

    /// And the smaller face is only for the longer label, or every glyph
    /// shrinks to fit the worst case.
    @Test("A single letter is not shrunk to fit two")
    func oneLetterKeepsItsSize() {
        let one = Glyphs.labelFont(for: "O", in: Renderer.glyphSize).pointSize
        let two = Glyphs.labelFont(for: "OR", in: Renderer.glyphSize).pointSize
        #expect(two < one,
                Comment(rawValue: "two characters are set at \(two)pt and one at \(one)pt"))
        #expect(one > Renderer.glyphSize * 0.6,
                "a single letter is being drawn smaller than it needs to be")
    }

    /// What is left. Named exactly, so a new harness that lands on a taken
    /// label fails here instead of shipping as somebody else's twin — and so
    /// that fixing one of these is visible as a change rather than as a test
    /// quietly passing.
    @Test("Only the recorded pairs share a label")
    func collisionsAreTheRecordedOnes() {
        var byLabel: [String: [String]] = [:]
        for descriptor in drawn {
            byLabel[Glyphs.fallbackLabel(descriptor.id, in: descriptors), default: []]
                .append(descriptor.id)
        }
        let shared = byLabel.filter { $0.value.count > 1 }
            .mapValues { $0.sorted() }
        let recorded = ["CC": ["commandcode", "copilot-cli", "cursor-cli"],
                        "HE": ["herdr", "hermes"],
                        "OR": ["openrouter", "orca"]]
        #expect(shared == recorded,
                Comment(rawValue: "the labels sharing a glyph are now "
                        + "\(shared.mapValues { $0.joined(separator: "+") })"))
    }

    /// And a shared glyph is not the only thing telling two items apart: the
    /// menu bar item carries the provider's name for the pointer and for a
    /// screen reader, which a drawn letter cannot supply.
    @Test("A menu bar item names its provider to accessibility")
    func itemsAreNamed() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/AgentItem.swift"), encoding: .utf8)
        #expect(source.contains("setAccessibilityLabel(provider.displayName)"),
                "the item is identified only by a glyph a screen reader cannot read")
        #expect(source.contains("toolTip = tooltip()"),
                "the item no longer names itself to the pointer either")
    }
}
