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
          arguments: [4, 99, -1])
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


/// The two operations this fold used to ignore.
///
/// VS Code's log is not only initial-set-push. A push may carry `i`, which
/// truncates the array before appending, and a `kind` 3 line deletes what its
/// path names. Both remove content, and a fold that skips them keeps content
/// the session does not have — for a chat transcript that means the tokens of
/// a request the user retried or took back were still counted, alongside the
/// request that replaced it.
@Suite("A fold removes what the session removed")
struct JournalRemovalTests {

    private let snapshot: [String: Any] = [
        "kind": 0,
        "v": ["title": "Real",
              "requests": [["promptTokens": 10], ["promptTokens": 20]]],
    ]

    private func requests(_ document: [String: Any]) -> [[String: Any]] {
        ((document["v"] as? [String: Any])?["requests"] as? [[String: Any]])
            ?? (document["requests"] as? [[String: Any]]) ?? []
    }

    /// A retry: the second request is replaced rather than joined.
    @Test("A push truncates the array where the log says to")
    func pushTruncates() {
        let folded = Journal.fold([snapshot,
                                   ["kind": 2, "k": ["requests"], "i": 1,
                                    "v": [["promptTokens": 99]]]])
        let got = requests(folded).compactMap { $0["promptTokens"] as? Int }
        #expect(got == [10, 99],
                Comment(rawValue: "the array folded to \(got)"))
    }

    /// A push with no index still appends, which is the ordinary case and
    /// must not become a truncation to nothing.
    @Test("A push with no index appends")
    func pushWithoutIndexAppends() {
        let folded = Journal.fold([snapshot,
                                   ["kind": 2, "k": ["requests"],
                                    "v": [["promptTokens": 99]]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [10, 20, 99])
    }

    /// An index past the end truncates nothing.
    @Test("A push whose index is past the end keeps what is there")
    func indexPastTheEnd() {
        let folded = Journal.fold([snapshot,
                                   ["kind": 2, "k": ["requests"], "i": 9,
                                    "v": [["promptTokens": 99]]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [10, 20, 99])
    }

    /// And an index of nought empties it, which is a session cleared rather
    /// than a session whose figures should survive.
    @Test("A push whose index is nought replaces the array")
    func indexOfNought() {
        let folded = Journal.fold([snapshot,
                                   ["kind": 2, "k": ["requests"], "i": 0,
                                    "v": [["promptTokens": 99]]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [99])
    }

    @Test("A delete removes an element, and the ones after it move up")
    func deleteRemovesAnElement() {
        let folded = Journal.fold([snapshot, ["kind": 3, "k": ["requests", 0]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [20])
    }

    @Test("A delete removes a key")
    func deleteRemovesAKey() {
        let folded = Journal.fold([snapshot, ["kind": 3, "k": ["title"]]])
        #expect(folded["title"] == nil && (folded["v"] as? [String: Any])?["title"] == nil,
                "the title survived a delete")
    }

    /// A delete naming something absent is not an error: the document already
    /// agrees with what the log is asking for.
    @Test("A delete of something absent changes nothing else")
    func deleteOfSomethingAbsent() {
        let folded = Journal.fold([snapshot, ["kind": 3, "k": ["nothing", "here"]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [10, 20])
    }

    /// And an element past the end of the array. `Array.remove(at:)` traps
    /// rather than shrugging, so this is the difference between a fold that
    /// ignores a stale line and one that takes the app down on a file it was
    /// only reading — which is the shape of every other bound in this
    /// codebase.
    @Test("A delete past the end of an array is ignored, not fatal",
          arguments: [2, 9, 10_000])
    func deletePastTheEnd(index: Int) {
        let folded = Journal.fold([snapshot, ["kind": 3, "k": ["requests", index]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [10, 20],
                Comment(rawValue: "deleting element \(index) changed the array"))
    }

    /// A negative index names nothing either, and is the one an off-by-one in
    /// somebody else's writer would produce.
    @Test("A delete of a negative index is ignored")
    func deleteOfNegativeIndex() {
        let folded = Journal.fold([snapshot, ["kind": 3, "k": ["requests", -1]]])
        #expect(requests(folded).compactMap { $0["promptTokens"] as? Int } == [10, 20])
    }
}

/// A patch whose path disagrees with the document's shape.
///
/// Found by coverage: `write` had no type guard where `remove` in the same file
/// has always had one, so a delete refused to reshape the document and a set was
/// free to. A patch naming `["requests", 0]` where the snapshot put an *object*
/// at `requests` discarded that object and built an array in its place — and a
/// descriptor's `requests[].promptTokens` then summed figures over a structure
/// the file never contained.
///
/// The safe answer is the one the rest of this file already gives: the patch is
/// skipped and the fields it would have set are absent, which every reader
/// downstream has an answer for. Creating what is *absent* is the ordinary case
/// and is a different thing — the snapshot is written when the session is empty,
/// so nearly every path in a folded document was built by a patch.
@Suite("A patch does not reshape what the document already holds")
struct JournalShapeTests {

    @Test("An index naming an object leaves the object alone")
    func indexAgainstObject() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": ["a": 1]]],
            ["kind": 1, "k": ["requests", 0, "tokens"], "v": 5],
        ])
        let requests = folded["requests"] as? [String: Any]
        #expect(requests?["a"] as? Int == 1, "the object the snapshot held was discarded")
        #expect(folded["requests"] as? [Any] == nil, "an array was built where an object was")
    }

    @Test("A key naming an array leaves the array alone")
    func keyAgainstArray() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [["tokens": 1]]]],
            ["kind": 1, "k": ["requests", "total"], "v": 99],
        ])
        let requests = folded["requests"] as? [Any]
        #expect(requests?.count == 1, "the array the snapshot held was discarded")
        #expect((folded["requests"] as? [String: Any])?["total"] == nil)
    }

    @Test("A key naming a number leaves the number alone")
    func keyAgainstScalar() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["total": 7]],
            ["kind": 1, "k": ["total", "inner"], "v": 5],
        ])
        #expect(folded["total"] as? Int == 7, "a number was replaced by an object")
    }

    /// The ordinary case, which must keep working: the snapshot is written when
    /// the session is empty, so the array the tokens live in is created by the
    /// first patch that names it.
    @Test("A patch still creates what the document does not hold")
    func absentIsStillCreated() {
        let folded = Journal.fold([
            ["kind": 0, "v": [:] as [String: Any]],
            ["kind": 1, "k": ["requests", 0, "tokens"], "v": 5],
        ])
        let requests = try? #require(folded["requests"] as? [Any])
        #expect(requests?.count == 1)
        #expect(((requests?.first as? [String: Any])?["tokens"]) as? Int == 5)
    }

    /// A nested *object* path, which no other case reached: every one of them
    /// arrives at a dictionary or an array first, so building an object over
    /// nothing was never exercised. Its mutation survived until this existed.
    @Test("A patch creates a nested object the document does not hold")
    func absentObjectIsCreated() {
        let folded = Journal.fold([
            ["kind": 0, "v": [:] as [String: Any]],
            ["kind": 1, "k": ["usage", "input"], "v": 42],
        ])
        #expect((folded["usage"] as? [String: Any])?["input"] as? Int == 42,
                "a nested object path was not built over an absent node")
    }

    /// And deeper, so the recursion is the thing under test rather than one
    /// level of it.
    @Test("A patch creates a nested object several levels down")
    func deeplyAbsentObjectIsCreated() {
        let folded = Journal.fold([
            ["kind": 1, "k": ["a", "b", "c"], "v": "found"],
        ])
        let a = folded["a"] as? [String: Any]
        let b = a?["b"] as? [String: Any]
        #expect(b?["c"] as? String == "found")
    }

    @Test("A push still creates the array it appends to")
    func pushCreatesTheArray() {
        let folded = Journal.fold([
            ["kind": 0, "v": [:] as [String: Any]],
            ["kind": 2, "k": ["requests"], "v": [["tokens": 5]] as [Any]],
        ])
        #expect((folded["requests"] as? [Any])?.count == 1)
    }

    /// And a push onto something that is not an array leaves it alone, rather
    /// than replacing it with the pushed elements.
    @Test("A push onto an object leaves the object alone")
    func pushAgainstObject() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": ["a": 1]]],
            ["kind": 2, "k": ["requests"], "v": [["tokens": 5]] as [Any]],
        ])
        #expect((folded["requests"] as? [String: Any])?["a"] as? Int == 1,
                "an object was replaced by the elements pushed at it")
    }

    /// A delete already behaved this way, which is how the inconsistency was
    /// noticed. Asserted here too so the two halves are held together.
    @Test("A delete naming the wrong shape already left it alone")
    func deleteAgainstWrongShape() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": ["a": 1]]],
            ["kind": 3, "k": ["requests", 0]],
        ])
        #expect((folded["requests"] as? [String: Any])?["a"] as? Int == 1)
    }
}

/// The push index, where `i` is not a sensible splice point.
@Suite("A push index that makes no sense is no index")
struct JournalPushIndexTests {

    private func pushed(_ i: Any?) -> [Any]? {
        var push: [String: Any] = ["kind": 2, "k": ["requests"],
                                   "v": [["tokens": 9]] as [Any]]
        if let i { push["i"] = i }
        return Journal.fold([
            ["kind": 0, "v": ["requests": [["tokens": 1], ["tokens": 2]] as [Any]]],
            push,
        ])["requests"] as? [Any]
    }

    /// A negative `i` is not a splice point. Treated as no index, which appends
    /// and keeps what is there; read as a position it would either trap or wipe
    /// the array, and the tokens of two real requests would go with it.
    @Test("A negative index appends rather than truncating", arguments: [-1, -1_000, Int.min])
    func negativeIndexAppends(i: Int) {
        #expect(pushed(i)?.count == 3,
                Comment(rawValue: "i: \(i) left \(pushed(i)?.count ?? -1) elements"))
    }

    @Test("An index that is not a number is no index")
    func nonNumericIndex() {
        #expect(pushed("two")?.count == 3)
        #expect(pushed(1.5)?.count == 3)
    }

    /// And the real thing still truncates, or the cases above would be
    /// satisfied by ignoring `i` entirely.
    @Test("A real index still truncates")
    func realIndexTruncates() {
        #expect(pushed(1)?.count == 2, "one kept plus one pushed")
        #expect(pushed(0)?.count == 1, "the array replaced by what was pushed")
        #expect(pushed(nil)?.count == 3, "no index appends")
    }

    /// A push carrying something that is not a list of elements adds nothing,
    /// rather than adding the value itself as one element.
    @Test("A push carrying no list adds nothing")
    func pushWithoutAList() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["requests": [["tokens": 1]] as [Any]]],
            ["kind": 2, "k": ["requests"], "v": ["tokens": 9]],
        ])
        #expect((folded["requests"] as? [Any])?.count == 1,
                "an object pushed as if it were a list of elements was added")
    }
}
