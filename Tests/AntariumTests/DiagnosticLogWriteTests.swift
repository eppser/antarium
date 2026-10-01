import Darwin
import Foundation
import Testing
@testable import Antarium

/// Writing the diagnostic log, which is a file this app creates in a place
/// anything else on the machine can also write to.
///
/// The reader had tests. The writer had none, and it is the half carrying the
/// hardening: a line that cannot forge another, a path that will not follow a
/// link, a mode reasserted on every append, and a rotation that cannot loop.
@Suite("Writing a diagnostic log", .serialized)
struct DiagnosticLogWriteTests {

    private func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString)")
    }

    private func lines(_ directory: URL) throws -> [String] {
        let file = directory.appendingPathComponent("antarium.log")
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber).intValue
    }

    /// A logged string can carry anything: an agent's name from a descriptor,
    /// a host from the remote settings, a line of somebody else's error
    /// output. A newline in one of those would end the entry and begin a new
    /// one that nothing wrote — a forged diagnostic, in the file a person
    /// reads to work out what went wrong.
    @Test("A newline in a logged value cannot forge a second entry")
    func newlineCannotForgeAnEntry() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLogFile(directory: directory)
        #expect(log.append("host=\nFATAL forged entry"))
        let written = try lines(directory)
        #expect(written.count == 1, "one call wrote \(written.count) entries")
        #expect(written[0].contains("FATAL forged entry"),
                "the forged text should still be readable, just not on its own line")
    }

    /// Carriage returns overwrite a terminal line, and an escape sequence can
    /// repaint one. Anything in the control range becomes a space.
    @Test("Control characters become spaces", arguments: [
        "\r", "\u{1B}[2K", "\u{0}", "\u{7}", "\u{8}",
    ])
    func controlCharactersAreNeutralised(_ control: String) throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLogFile(directory: directory)
        #expect(log.append("before\(control)after"))
        let written = try lines(directory)
        #expect(written.count == 1)
        for scalar in try #require(written.first).unicodeScalars {
            #expect(!CharacterSet.controlCharacters.contains(scalar),
                    "a control character reached the log")
        }
    }

    /// The path is opened `O_NOFOLLOW`. Without it, anything that can create
    /// a name in the log directory can point this app's writes at a file of
    /// its choosing.
    @Test("A log file that is a symlink is refused rather than followed")
    func symlinkedFileIsRefused() throws {
        let directory = folder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("elsewhere.txt")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("antarium.log"), withDestinationURL: target)

        let log = DiagnosticLogFile(directory: directory)
        #expect(log.append("should not arrive") == false, "the write followed a link")
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
        #expect(log.lastFailure?.hasPrefix("open") == true)
    }

    /// And the directory itself, which is the same attack one level up.
    @Test("A log directory that is a symlink is refused")
    func symlinkedDirectoryIsRefused() throws {
        let root = folder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let log = DiagnosticLogFile(directory: link)
        #expect(log.append("should not arrive") == false, "the directory link was followed")
        #expect(log.lastFailure?.hasPrefix("parent") == true)
    }

    /// The mode is set when the file is created and reasserted on every
    /// append, because something else may have widened it in between.
    @Test("A log left readable by others is narrowed on the next append")
    func permissionsAreReasserted() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLogFile(directory: directory)
        #expect(log.append("first"))
        let file = directory.appendingPathComponent("antarium.log")
        #expect(try mode(file) == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        #expect(log.append("second"))
        #expect(try mode(file) == 0o600, "a widened log stayed readable by other users")
    }

    /// Rotation happens once. A line larger than the whole budget would
    /// otherwise rotate, find the fresh file still too small, and rotate
    /// again for ever.
    @Test("A line too large for the budget rotates once and stops")
    func rotationCannotLoop() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLogFile(directory: directory, maximumBytes: 1_024)
        #expect(log.append(String(repeating: "a", count: 400)))
        // Now over the budget: this one rotates, and the retry must not.
        _ = log.append(String(repeating: "b", count: 900))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("antarium.1.log").path),
                "nothing was rotated")
        // Whatever it decided, it returned rather than recursing.
        #expect(Bool(true))
    }

    /// The ordinary case, so none of the above passes by refusing everything.
    @Test("An ordinary line is written, and appended to")
    func ordinaryAppend() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLogFile(directory: directory)
        #expect(log.append("one"))
        #expect(log.append("two"))
        #expect(try lines(directory) == ["one", "two"])
        #expect(log.lastFailure == nil)
    }
}
