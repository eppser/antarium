import Foundation
import Testing
@testable import Antarium

/// Folding VS Code's append-only chat log back into one document.
///
/// The ordinary path had a test. Every edge of it did not, and this reads a
/// file another application writes — the threat model this whole app is built
/// around. A patch can name an array element that does not exist, name one a
/// billion elements away, name a negative one, or name nothing at all, and
/// each of those was a crash, an allocation, or a silently wrong document
/// with nothing objecting.
@Suite("Folding a journal")
struct JournalFoldTests {

    @Test("A snapshot is the document it describes")
    func snapshotIsTheDocument() {
        let folded = Journal.fold([["kind": 0, "v": ["title": "one"]]])
        #expect(folded["title"] as? String == "one")
    }

    @Test("A later snapshot replaces what came before it")
    func laterSnapshotReplaces() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["title": "one", "gone": true]],
            ["kind": 1, "k": ["title"], "v": "edited"],
            ["kind": 0, "v": ["title": "two"]],
        ])
        #expect(folded["title"] as? String == "two")
        #expect(folded["gone"] == nil, "a fresh snapshot kept a field it does not have")
    }

    /// The bound that matters. A patch naming an element a billion away would
    /// otherwise fill the array up to it, one empty dictionary at a time,
    /// from a file this app did not write.
    @Test("A patch naming an absurd element is ignored rather than allocated",
          arguments: [10_000, 100_000, 999_999_999, Int.max])
    func absurdIndexIsIgnored(_ index: Int) {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [] as [Any]]],
            ["kind": 1, "k": ["requests", index, "tokens"], "v": 5],
        ])
        let requests = folded["requests"] as? [Any] ?? []
        #expect(requests.isEmpty,
                "an element \(index) deep was allocated from another app's file")
    }

    /// And a negative one, which indexes an array backwards and traps.
    @Test("A patch naming a negative element is ignored rather than trapping",
          arguments: [-1, -1_000, Int.min])
    func negativeIndexIsIgnored(_ index: Int) {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [] as [Any]]],
            ["kind": 1, "k": ["requests", index], "v": ["tokens": 5]],
        ])
        #expect((folded["requests"] as? [Any])?.isEmpty == true)
    }

    /// Just inside the bound still works: the limit is a ceiling on
    /// absurdity, not a reason to drop an ordinary session's twentieth turn.
    @Test("An element just inside the bound is still reachable")
    func insideTheBoundWorks() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [] as [Any]]],
            ["kind": 1, "k": ["requests", 9_999, "tokens"], "v": 5],
        ])
        #expect((folded["requests"] as? [Any])?.count == 10_000)
    }

    /// A patch can name an element the snapshot never carried — VS Code
    /// writes the snapshot when the session is empty, so this is the ordinary
    /// case rather than a malformed one.
    @Test("A patch reaches an element the snapshot never had")
    func patchCreatesTheElement() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [] as [Any]]],
            ["kind": 1, "k": ["requests", 2, "tokens"], "v": 7],
        ])
        let requests = try? #require(folded["requests"] as? [Any])
        #expect(requests?.count == 3)
        #expect(((requests?[2] as? [String: Any])?["tokens"]) as? Int == 7)
        // The elements it had to invent are empty, not absent.
        #expect((requests?[0] as? [String: Any])?.isEmpty == true)
    }

    /// A patch with no path has nothing to address. Applying it at the root
    /// would replace the whole session with whatever that line carried.
    @Test("A patch with no path changes nothing")
    func emptyPathChangesNothing() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["title": "kept"]],
            ["kind": 1, "k": [] as [Any], "v": ["title": "replaced"]],
        ])
        #expect(folded["title"] as? String == "kept",
                "a patch addressing nothing replaced the whole document")
    }

    /// A patch whose path component is neither a key nor an index — a
    /// boolean, a nested array — leaves the document alone rather than
    /// guessing what was meant.
    @Test("A patch with an unusable path component changes nothing")
    func unusablePathChangesNothing() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["title": "kept"]],
            ["kind": 1, "k": [true], "v": "replaced"],
        ])
        #expect(folded["title"] as? String == "kept")
    }

    /// Setting an element to nothing keeps what was there. A journal line
    /// with no value is a line we could not read, and dropping the turn it
    /// names would lose the tokens already counted against it.
    @Test("A patch carrying no value leaves the element alone")
    func nilValueKeepsTheElement() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [["tokens": 11]] as [Any]]],
            ["kind": 1, "k": ["requests", 0]],
        ])
        let requests = folded["requests"] as? [Any]
        #expect(((requests?.first as? [String: Any])?["tokens"]) as? Int == 11,
                "an unreadable patch erased a turn that had already been counted")
    }

    @Test("An empty journal folds to an empty document")
    func emptyJournal() {
        #expect(Journal.fold([]).isEmpty)
    }

    /// A file that begins mid-stream, with patches and no snapshot, still
    /// produces what it can rather than nothing.
    @Test("Patches with no snapshot still build a document")
    func patchesWithoutSnapshot() {
        let folded = Journal.fold([["kind": 1, "k": ["title"], "v": "late"]])
        #expect(folded["title"] as? String == "late")
    }
}

/// Lines whose operation the fold does not understand.
///
/// VS Code writes these files and is free to change them. What matters is
/// what happens to a line this cannot read: applying it as something else
/// puts figures into the folded document that were never in the file, and
/// the reader has no way to tell afterwards.
@Suite("A journal line nothing understands is skipped")
struct JournalUnknownKindTests {

    private let snapshot: [String: Any] = ["kind": 0, "v": ["title": "Real", "tokens": 10]]

    private func title(_ folded: [String: Any]) -> String? { folded["title"] as? String }

    /// The format omits `kind` on the first line, so absent still means
    /// snapshot — the case the old default existed for.
    @Test("A line with no kind at all is still a snapshot")
    func absentKindIsASnapshot() {
        let folded = Journal.fold([["v": ["title": "Real"]]])
        #expect(title(folded) == "Real")
    }

    /// A kind that is not a number was read as zero, which is the most
    /// destructive reading available: it replaced everything folded so far
    /// with the patch's own payload.
    @Test("A kind that is not a number does not replace the document",
          arguments: [["kind": "1", "v": ["title": "Wrong"]] as [String: Any],
                      ["kind": true, "v": ["title": "Wrong"]],
                      ["kind": 1.5, "v": ["title": "Wrong"]],
                      ["kind": NSNull(), "v": ["title": "Wrong"]]])
    func malformedKindIsSkipped(line: [String: Any]) {
        let folded = Journal.fold([snapshot, line])
        #expect(title(folded) == "Real",
                Comment(rawValue: "\(line["kind"] ?? "nil") overwrote the document"))
    }

    /// A kind VS Code adds later must not be applied as one this happens to
    /// know. It used to fall through to the `set` path and write the value.
    @Test("A kind this version does not know is skipped, not guessed at",
          arguments: [3, 4, 99, -1])
    func unknownKindIsSkipped(kind: Int) {
        let folded = Journal.fold([snapshot,
                                   ["kind": kind, "k": ["title"], "v": "Wrong"]])
        #expect(title(folded) == "Real",
                Comment(rawValue: "kind \(kind) was applied as something else"))
    }

    /// And the three it does know still work, or the guard above would be a
    /// way of ignoring the whole file.
    @Test("The kinds it knows are still applied")
    func knownKindsStillApply() {
        let set = Journal.fold([snapshot, ["kind": 1, "k": ["title"], "v": "Patched"]])
        #expect(title(set) == "Patched")

        let appended = Journal.fold([
            ["kind": 0, "v": ["items": ["a"]]],
            ["kind": 2, "k": ["items"], "v": ["b", "c"]],
        ])
        #expect((appended["items"] as? [Any])?.count == 3)

        let replaced = Journal.fold([snapshot, ["kind": 0, "v": ["title": "Second"]]])
        #expect(title(replaced) == "Second")
    }
}
