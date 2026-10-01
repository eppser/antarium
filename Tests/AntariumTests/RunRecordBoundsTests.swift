import Foundation
import Testing
@testable import Antarium

/// The run-record folder was the one place in the app with no bound on how
/// many objects it holds.
///
/// `antarium run <agent>` writes a small JSON record per invocation, and
/// nothing reads them back — they are there to be looked at. So nothing
/// noticed that a year of wrapping every invocation is a folder with tens of
/// thousands of files in it. `docs/TECHNICAL.md` states the rule as bounding
/// objects rather than only bytes, and each record being a few hundred bytes
/// is precisely why the bytes rule would not have caught it.
@Suite("Run records are bounded by count")
struct RunRecordBoundsTests {

    private func names(_ stamps: [Int]) -> [String] {
        stamps.map { "\($0)-1234.json" }
    }

    @Test("A folder under the limit loses nothing")
    func underLimitKeepsEverything() {
        #expect(RunWrapper.doomed(names([1, 2, 3]), keeping: 10).isEmpty)
        #expect(RunWrapper.doomed([], keeping: 10).isEmpty)
    }

    @Test("Exactly at the limit is still nothing")
    func atLimitKeepsEverything() {
        #expect(RunWrapper.doomed(names(Array(1...10)), keeping: 10).isEmpty)
    }

    @Test("One past the limit drops the oldest, and only that one")
    func onePastDropsTheOldest() {
        let dropped = RunWrapper.doomed(names(Array(1...11)), keeping: 10)
        #expect(dropped == ["1-1234.json"])
    }

    @Test("The newest are the ones kept")
    func newestSurvive() {
        let dropped = Set(RunWrapper.doomed(names(Array(1...100)), keeping: 10))
        for stamp in 91...100 {
            #expect(!dropped.contains("\(stamp)-1234.json"),
                    "a recent record was dropped")
        }
        #expect(dropped.count == 90)
    }

    /// The names are epoch seconds. Compared as text, a nine-digit stamp
    /// sorts after a ten-digit one while being years earlier — so a
    /// lexical sort would keep 2001 and throw away last week. Every name
    /// written since 2001 has ten digits, which is exactly why nobody would
    /// notice.
    @Test("Ordering is numeric, not lexical")
    func orderingIsNumeric() {
        let dropped = RunWrapper.doomed(names([999_999_999, 1_700_000_000]), keeping: 1)
        #expect(dropped == ["999999999-1234.json"],
                "the older record survived because its name is shorter")
    }

    /// Two runs can start in the same second. The answer must not depend on
    /// the order the filesystem happened to list them in.
    @Test("Records from the same second break their tie on the whole name")
    func tiesAreStable() {
        let same = ["1700000000-300.json", "1700000000-100.json", "1700000000-200.json"]
        let first = RunWrapper.doomed(same, keeping: 1)
        #expect(first == ["1700000000-100.json", "1700000000-200.json"])
        #expect(RunWrapper.doomed(same.reversed(), keeping: 1) == first)
    }

    /// A name that is not a record at all sorts as the oldest thing there and
    /// is dropped first, which is the right end for something nobody wrote.
    @Test("A name with no timestamp does not upset the ordering")
    func unparseableNameIsOldest() {
        let mixed = ["notes.json", "1700000000-1.json", "1700000001-1.json"]
        #expect(RunWrapper.doomed(mixed, keeping: 2) == ["notes.json"])
    }

    /// And the whole thing against a real folder, because the pure rule says
    /// nothing about whether anything is actually deleted.
    @Test("Pruning a real folder leaves the newest records and nothing else")
    func prunesOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("runs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for stamp in 1...25 {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("\(stamp)-1.json"))
        }
        // Something that is not a record, which must be left alone.
        try Data("keep".utf8).write(to: folder.appendingPathComponent("README.txt"))

        RunWrapper.prune(folder, keeping: 5)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left.contains("README.txt"), "pruning removed something it did not write")
        #expect(left.filter { $0.hasSuffix(".json") }.count == 5)
        for stamp in 21...25 { #expect(left.contains("\(stamp)-1.json")) }
    }

    @Test("The shipped limit is a number somebody chose")
    func shippedLimitIsSane() {
        #expect(RunWrapper.maxRecords == 500)
    }
}

/// Saving a record prunes.
///
/// Checked in the source, because `save` is private and writes into the real
/// configuration directory — a test that exercised it would either touch the
/// user's folder or prove something about a copy of the code. The pure rule
/// above says which records to drop; this says the rule is applied at all,
/// which is the half that was missing for the life of the feature.
@Suite("Writing a record prunes the folder")
struct RunRecordPruneCallContractTests {

    @Test("save prunes after it writes")
    func saveCallsPrune() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Core/RunWrapper.swift"), encoding: .utf8)
        let save = try #require(text.range(of: "private static func save("),
                                "the record writer was renamed")
        let body = text[save.lowerBound...].prefix(700)
        let write = try #require(body.range(of: ".write(to: directory"),
                                 "save no longer writes a record")
        let prune = try #require(body.range(of: "prune(directory)"),
                                 "a record is written and the folder never pruned")
        #expect(write.lowerBound < prune.lowerBound,
                "the folder is pruned before the new record is in it")
    }
}
