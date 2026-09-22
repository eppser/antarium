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

    /// The ones that fall through to a drawn label.
    private var drawn: [HarnessDescriptor] {
        descriptors.filter {
            AppResources.bundle.url(forResource: Glyphs.markName($0.id, in: descriptors),
                                    withExtension: "png", subdirectory: "marks") == nil
        }
    }

    @Test("There are agents without artwork")
    func thereAreSubjects() {
        #expect(drawn.count >= 10,
                Comment(rawValue: "only \(drawn.count) harnesses draw a label"))
    }

    /// A 14pt glyph holds two characters. Three would not help anyway —
    /// Herdr and Hermes differ at their fourth letter.
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
        let recorded = ["CC": ["commandcode", "copilot-cli"],
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
