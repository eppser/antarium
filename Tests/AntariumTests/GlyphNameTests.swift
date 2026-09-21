import Foundation
import Testing
@testable import Antarium

/// Which logo sits beside which agent.
///
/// Cosmetic only until it is wrong: the mark is how a glance tells two rows
/// apart, so another agent's logo beside a row is a misstatement rather than
/// a slip. Three answers in a fixed order decide it, and none of the three
/// had a test — the function was private and read the harness folder on this
/// Mac, so whatever it answered was the right answer by definition.
@Suite("Agent marks resolve in a fixed order")
@MainActor
struct GlyphNameTests {

    private func descriptor(_ id: String, mark: String?) throws -> HarnessDescriptor {
        var object: [String: Any] = [
            "formatVersion": 1, "id": id, "name": id, "process": [:],
            "source": ["kind": "none", "path": ""],
        ]
        if let mark { object["mark"] = mark }
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    @Test("A descriptor that names its mark wears that one")
    func declaredWins() throws {
        #expect(Glyphs.markName("contributed",
                                in: [try descriptor("contributed", mark: "claude-code")])
                == "claude-code")
    }

    /// And it wins over the alias table, or a contributed harness could not
    /// override anything this app already believes.
    @Test("A declared mark beats the alias table")
    func declaredBeatsAlias() throws {
        #expect(Glyphs.alias["cursor-cli"] == "cursor", "the alias under test is gone")
        #expect(Glyphs.markName("cursor-cli", in: [try descriptor("cursor-cli", mark: "kiro")])
                == "kiro")
    }

    /// Two harnesses that are one product wearing two hats.
    @Test("An aliased harness wears the mark of the product it is",
          arguments: [("cursor-cli", "cursor"), ("codex-desktop", "codex")])
    func aliasApplies(id: String, expected: String) {
        #expect(Glyphs.markName(id, in: []) == expected)
    }

    @Test("An agent with nothing declared wears its own name")
    func fallsBackToTheID() {
        #expect(Glyphs.markName("zai", in: []) == "zai")
    }

    /// A descriptor for a different agent must not lend its mark, which is
    /// the shape a first/any mix-up would take.
    @Test("Another agent's descriptor does not supply the mark")
    func wrongDescriptorIsIgnored() throws {
        #expect(Glyphs.markName("zai", in: [try descriptor("codex", mark: "claude-code")])
                == "zai")
    }

    /// A descriptor with no mark of its own falls through rather than
    /// blocking the two answers behind it.
    @Test("A descriptor that declares no mark does not shadow the alias")
    func silentDescriptorFallsThrough() throws {
        #expect(Glyphs.markName("cursor-cli", in: [try descriptor("cursor-cli", mark: nil)])
                == "cursor")
    }
}
