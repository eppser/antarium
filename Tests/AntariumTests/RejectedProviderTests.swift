import Foundation
import Testing
@testable import Antarium

/// Providers this project looked at and did not write, and why.
///
/// `docs/ECOSYSTEM.md` names them and gives a reason for each: the endpoint
/// is known and the response shape is not, so a mapping would be a guess
/// about somebody else's product and the fixture beside it would prove only
/// that the guess is self-consistent.
///
/// Two things can go wrong with a list like that, and neither is visible.
/// One of them can ship, leaving the document asserting something untrue of
/// the thing it sits beside. Or the reason can be repeated after it stops
/// being the reason — which is what "Chutes was not re-checked" was, for a
/// while: an entry carried forward on its own say-so.
@Suite("The providers we turned down are still turned down")
struct RejectedProviderTests {

    /// Named here as well as in the document, so neither can quietly lose one.
    private let rejected = ["Chutes", "DeepInfra", "Antigravity", "Codebuff", "Poe"]

    private func ecosystem() throws -> String {
        try SourceText.read("docs/ECOSYSTEM.md")
    }

    /// The section that makes the claim, not the document. Asking whether a
    /// name appears anywhere is satisfied by a mention in passing — the
    /// first version of this passed while the sentence explaining why Chutes
    /// was not written had lost the word "Chutes".
    private func turnedDownSection() throws -> String {
        let text = try ecosystem()
        let start = try #require(text.range(of: "Five more were looked at and not written"),
                                 "the section recording what was turned down is gone")
        let rest = text[start.lowerBound...]
        let end = rest.range(of: "\n## ")
        return String(end.map { rest[..<$0.lowerBound] } ?? rest)
    }

    @Test("Each one is named where the reason is given", arguments:
            ["Chutes", "DeepInfra", "Antigravity", "Codebuff", "Poe"])
    func namedInTheDocument(name: String) throws {
        #expect(try turnedDownSection().contains(name),
                Comment(rawValue: "\(name) is not named in the section that says why it "
                        + "was not written"))
    }

    /// And none of them ships. A descriptor added without updating the
    /// document leaves it stating the opposite of what is in the folder
    /// beside it.
    @Test("None of them ships as a harness", arguments:
            ["chutes", "deepinfra", "antigravity", "codebuff", "poe"])
    func noneShips(id: String) {
        let ids = Set(HarnessCLI.bundledDescriptors().map(\.id))
        #expect(!ids.contains(id),
                Comment(rawValue: "\(id) ships and ECOSYSTEM.md still says it was turned down"))
    }

    /// The reason each was turned down is a claim about somebody else's
    /// documentation, and that changes. Every verdict carries the day it was
    /// established, so a reader can tell a checked entry from a remembered
    /// one.
    @Test("Every verdict says when it was established")
    func verdictsAreDated() throws {
        let text = try ecosystem()
        let section = try SourceText.block("Five more were looked at and not written",
                                           in: text)
        #expect(!section.isEmpty)
        // The paragraphs that record a re-check name their date.
        let dated = text.components(separatedBy: "2026-").count - 1
        #expect(dated >= 2,
                Comment(rawValue: "only \(dated) verdicts carry a date, so a reader cannot "
                        + "tell which were checked from which were repeated"))
    }

    /// The one that is closest to being writable is marked as such, because
    /// the next person to look should start there rather than re-reading all
    /// five.
    @Test("The nearest miss is identified")
    func nearestMissIsMarked() throws {
        let text = try ecosystem()
        #expect(text.contains("most worth revisiting"),
                "nothing says which of the five is closest to being written")
    }
}
