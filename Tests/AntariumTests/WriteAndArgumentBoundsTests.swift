import Foundation
import Testing
@testable import Antarium

@Suite("Private writes refuse an unsafe destination")
struct PrivateWriteTests {

    // Not tested, deliberately: the temporary file is opened with O_NOFOLLOW
    // as well. Its name is a fresh UUID in a directory already held open by
    // descriptor, so observing that flag would mean winning a race against the
    // write — it is defence in depth against a TOCTOU, not a behaviour. The
    // destination check below is the observable guard and the one that
    // matters: it refuses a symlink someone left in place.

    @Test("A symlink at the destination is refused, and not written through")
    func symlinkDestinationIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Something else on the machine, which must not be touched.
        let elsewhere = root.appendingPathComponent("elsewhere.txt")
        try Data("original".utf8).write(to: elsewhere)

        let destination = root.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)

        #expect(throws: PrivateFile.WriteError.self) {
            try PrivateFile.write(Data("replacement".utf8), to: destination)
        }
        // A write that followed the link would let anything able to create it
        // choose what gets overwritten.
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "original")
    }

    @Test("A destination that is a directory is refused")
    func nonRegularDestinationIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-write2-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: PrivateFile.WriteError.self) {
            try PrivateFile.write(Data("x".utf8), to: directory)
        }
    }

    @Test("An ordinary write replaces the file and leaves it private")
    func ordinaryWriteSucceeds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-write3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.json")
        try PrivateFile.write(Data("first".utf8), to: file)
        try PrivateFile.write(Data("second".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "second")
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }
}

/// Command-line arguments reach a menu bar app from macOS as well as from a
/// terminal. The bounds exist so a malformed or hostile invocation is refused
/// before anything parses it.
@Suite("Launch argument bounds")
struct LaunchArgumentBoundTests {

    @Test("Too many arguments are refused by the count bound, not by luck")
    func argumentCountIsBounded() {
        #expect(LaunchArguments.validate(["--status"]) == nil)
        // Asserting only "not nil" passes without the bound: two thousand
        // unknown flags are refused as an unknown command instead. The message
        // is what distinguishes the two.
        let many = (0..<2_000).map { "--arg\($0)" }
        #expect(LaunchArguments.validate(many) == "Command-line arguments exceed supported limits.")
        // And a valid command with too many operands is refused the same way,
        // before the mode that would otherwise bound them is consulted.
        let hosts = ["--remote-tmux"] + (0..<2_000).map { "host\($0)" }
        #expect(LaunchArguments.validate(hosts) == "Command-line arguments exceed supported limits.")
    }

    @Test("An absurdly long argument is refused")
    func argumentLengthIsBounded() {
        #expect(LaunchArguments.validate(["--check", String(repeating: "a", count: 100_000)]) != nil)
    }

    @Test("An argument containing a NUL byte is refused")
    func nulBytesAreRefused() {
        // A NUL truncates a C string, so an argument carrying one can mean a
        // different thing to the parser than to anything it is handed to.
        #expect(LaunchArguments.validate(["--check", "file.json\u{0}rest"]) != nil)
    }

    @Test("Ordinary invocations still pass")
    func ordinaryInvocationsPass() {
        for arguments in [["--status"], ["--once", "copilot"], ["--bench"],
                          ["--detect-agents", "--apply"], ["--check", "x.json"], []] {
            #expect(LaunchArguments.validate(arguments) == nil,
                    "rejected a valid invocation: \(arguments)")
        }
    }
}
