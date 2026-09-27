import Foundation
import Testing
@testable import Antarium

/// The mutation catalogue cannot quietly become empty.
///
/// `check-mutations.py` reported "0 mutations still apply" for an empty file and
/// exited zero, so an emptied or truncated `mutations.txt` passed the gate. That is
/// the shape this project has already been bitten by once: a test file truncated to
/// nothing compiled, and the suite ran green with seven tests missing.
///
/// Guarded in two places on purpose. The checker refuses a catalogue below a floor,
/// which is what `verify.sh` runs; this asks the same of the file itself, which is
/// what `./test.sh` runs — and a developer reaches for the suite far more often than
/// for the gate.
@Suite("The mutation catalogue is a catalogue")
struct CatalogueFloorTests {

    /// The fewest entries the catalogue may hold. Matches the floor in
    /// `tools/check-mutations.py`, and the test below holds the two together so they
    /// cannot drift.
    static let minimum = 1_000

    private func catalogue() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("mutations.txt"),
                             encoding: .utf8)
        // Blank lines and `#` comments are ignored, which the file's own header
        // says and `check-mutations.py` implements. A first version of this counted
        // them and reported the header as twenty malformed entries.
        return text.split(separator: "\n").map(String.init).filter {
            !$0.isEmpty && !$0.hasPrefix("#")
        }
    }

    @Test("It holds more entries than the floor")
    func aboveTheFloor() throws {
        let entries = try catalogue()
        #expect(entries.count >= Self.minimum,
                Comment(rawValue: "the catalogue holds \(entries.count) entries, fewer than "
                        + "the \(Self.minimum) expected — emptied or truncated?"))
    }

    /// Every line is an entry, so the count above is a count of entries rather than
    /// of whatever happens to be in the file.
    @Test("Every line is a name, a file and an expression")
    func everyLineIsAnEntry() throws {
        var malformed: [String] = []
        for line in try catalogue() where line.split(separator: "|").count < 3 {
            malformed.append(String(line.prefix(60)))
        }
        #expect(malformed.isEmpty,
                Comment(rawValue: "malformed entries: \(malformed.joined(separator: " / "))"))
    }

    /// Names are distinct, because a mutation run reports by name and two entries
    /// sharing one makes the report unreadable — and hid an entry that had never
    /// compiled, once.
    @Test("Every entry has its own name")
    func namesAreDistinct() throws {
        let names = try catalogue().compactMap {
            $0.split(separator: "|").first?.trimmingCharacters(in: .whitespaces)
        }
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty,
                Comment(rawValue: "shared names: \(duplicates.keys.sorted().joined(separator: ", "))"))
    }

    /// The floor here and the floor in the checker are the same number. Two
    /// guards are worth having; two *different* guards would be a way of arguing
    /// with yourself.
    @Test("The checker and this test agree on the floor")
    func floorsAgree() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: root
            .appendingPathComponent("tools/check-mutations.py"), encoding: .utf8)
        #expect(script.contains("MINIMUM_ENTRIES = 1_000"),
                "the checker's floor is not the one this test asserts")
        #expect(Self.minimum == 1_000)
    }

    /// The checker itself, run on a catalogue that is not one.
    ///
    /// The floor lives in a script `verify.sh` runs, so removing it is invisible to
    /// `./test.sh` — and a mutation run judges by the suite, so that guard survived
    /// its own catalogue entry until this existed. Running the script is the only way
    /// to see what it decides.
    @Test("The checker refuses a catalogue below the floor", arguments: [
        "", "a name | Sources/Antarium/Core/FieldPath.swift | s%enum%enum%\n",
    ])
    func checkerRefusesASmallCatalogue(contents: String) throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try #require(FileManager.default.isExecutableFile(atPath: python.path),
                     "this project's tooling is python3, and it is not here")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = python
        process.arguments = [root.appendingPathComponent("tools/check-mutations.py").path,
                             temporary.path]
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0,
                Comment(rawValue: "a catalogue of \(contents.isEmpty ? 0 : 1) entries was "
                        + "reported as healthy"))
    }

    /// And the real one passes, or the check above would be satisfied by a checker
    /// that refuses everything.
    @Test("The checker accepts the real catalogue")
    func checkerAcceptsTheRealOne() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try #require(FileManager.default.isExecutableFile(atPath: python.path))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = python
        process.arguments = [root.appendingPathComponent("tools/check-mutations.py").path,
                             root.appendingPathComponent("mutations.txt").path]
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0,
                "the shipped catalogue has entries that no longer apply")
    }

    /// And the file ends with a newline, which has bitten three times: appending to
    /// a file without one merges the new entry into the last, and both are lost.
    @Test("The file ends with a newline")
    func endsWithNewline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("mutations.txt"),
                             encoding: .utf8)
        #expect(text.hasSuffix("\n"),
                "an entry appended to this would merge into the last line")
    }
}
