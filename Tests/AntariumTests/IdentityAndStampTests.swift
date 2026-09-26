import Foundation
import Testing
@testable import Antarium

/// Two rows with the same id are one row. Identity decides which observations
/// are the same session across scans, so a collision merges two agents and a
/// spurious difference splits one into two rows that both look half-idle.
@Suite("Session identity")
struct AgentIdentityTests {

    @Test("A session id distinguishes two sessions in the same directory")
    func sessionIDSeparatesSessionsInOneProject() {
        let first = AgentIdentity.local(harness: "claude-code", sessionID: "aaa",
                                        cwd: "/Users/x/project", pid: 1)
        let second = AgentIdentity.local(harness: "claude-code", sessionID: "bbb",
                                         cwd: "/Users/x/project", pid: 1)
        #expect(first != second, "two conversations in one folder collapsed into one row")
        // And the same session keeps its identity across scans, whatever pid
        // it is attached to this time.
        #expect(first == AgentIdentity.local(harness: "claude-code", sessionID: "aaa",
                                             cwd: "/Users/x/project", pid: 999))
    }

    @Test("The same session id in different projects is different sessions")
    func projectIsPartOfIdentity() {
        let here = AgentIdentity.local(harness: "c", sessionID: "same", cwd: "/a", pid: nil)
        let there = AgentIdentity.local(harness: "c", sessionID: "same", cwd: "/b", pid: nil)
        #expect(here != there)
    }

    @Test("Two harnesses never share an identity")
    func harnessIsPartOfIdentity() {
        #expect(AgentIdentity.local(harness: "codex", sessionID: "s", cwd: "/a", pid: nil)
                != AgentIdentity.local(harness: "claude-code", sessionID: "s", cwd: "/a", pid: nil))
    }

    @Test("Equivalent paths are one project, and a pid is the last resort")
    func pathsAreNormalisedAndPidIsLast() {
        #expect(AgentIdentity.local(harness: "c", sessionID: nil, cwd: "/a/b", pid: nil)
                == AgentIdentity.local(harness: "c", sessionID: nil, cwd: "/a/./b", pid: nil))
        // With no session, no project and no record, the pid is all there is —
        // and it must not be mistaken for durable identity.
        let byPid = AgentIdentity.local(harness: "c", sessionID: nil, cwd: "", pid: 42)
        #expect(byPid.hasSuffix("-process-42"))
        #expect(byPid != AgentIdentity.local(harness: "c", sessionID: nil, cwd: "", pid: 43))
    }
}

/// The signature that decides whether a cached parse may be reused. Missing a
/// change means showing yesterday's numbers; the stamp is what stops that.
@Suite("Change detection", .serialized)
struct FileStampTests {

    // These pin what the stamp must notice, not which field notices it. No
    // single component can be isolated through this API: st_ctimespec moves
    // whenever size, content, inode or mtime does, so removing the inode, the
    // size, the modification nanoseconds, or all of dev/ino/size together
    // changes nothing observable. Measured, not assumed. The stamp is
    // deliberately over-specified — ctime is not guaranteed on every
    // filesystem the harness folder might live on — and the redundancy is the
    // point rather than an accident worth trimming.

    @Test("A file replaced with identical content still reads as changed")
    func replacementIsDetectedEvenWhenContentMatches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("harness.json")

        try Data("{}".utf8).write(to: file)
        let before = FileStamp.of(file)
        #expect(!before.isEmpty)
        #expect(FileStamp.of(file) == before, "an untouched file must read as unchanged")

        // Atomic saves write a new file and rename it over the old one, so the
        // inode changes while size and timestamps can match. Dropping the
        // inode from the stamp makes that replacement invisible.
        let replacement = root.appendingPathComponent("replacement.json")
        try Data("{}".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        #expect(FileStamp.of(file) != before, "a replaced file read as unchanged")
    }

    @Test("Two files made identical in every settable attribute still stamp apart")
    func stampIdentifiesTheFileNotItsShape() throws {
        // Replacing a file changes its timestamps as well as its inode, so a
        // replacement cannot isolate any single component. Two distinct files
        // can be made identical in content, mode and modification time — and
        // the stamp must still tell them apart, because that is the difference
        // between "this file" and "a file that looks like it".
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a.json")
        let b = root.appendingPathComponent("b.json")
        try Data("{}".utf8).write(to: a)
        try Data("{}".utf8).write(to: b)

        // Pin both to the same modification time to the nanosecond.
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
                     timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
        #expect(utimensat(AT_FDCWD, a.path, &times, 0) == 0)
        #expect(utimensat(AT_FDCWD, b.path, &times, 0) == 0)

        var infoA = stat(), infoB = stat()
        #expect(lstat(a.path, &infoA) == 0)
        #expect(lstat(b.path, &infoB) == 0)
        #expect(infoA.st_size == infoB.st_size)
        #expect(infoA.st_mtimespec.tv_sec == infoB.st_mtimespec.tv_sec)
        #expect(infoA.st_mtimespec.tv_nsec == infoB.st_mtimespec.tv_nsec)
        #expect(infoA.st_ino != infoB.st_ino, "the test needs two distinct inodes")

        #expect(FileStamp.of(a) != FileStamp.of(b),
                "two different files with matching content and times stamped the same")
    }

    @Test("A file that grows without its timestamp moving still reads as changed")
    func stampCoversSizeIndependently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampsize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.json")

        try Data("{}".utf8).write(to: file)
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0),
                     timespec(tv_sec: 1_700_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        let before = FileStamp.of(file)

        // Append, then put the modification time back. A transcript appended
        // to by a writer that also restores timestamps would otherwise look
        // untouched, and its new records would never be read.
        try Data("{\"x\":1}".utf8).write(to: file)
        #expect(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        #expect(FileStamp.of(file) != before, "a size change with a pinned mtime went unnoticed")
    }

    @Test("An absent file is empty, and unreadable is not the same as absent")
    func absenceIsDistinctFromFailure() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString)")
        #expect(FileStamp.of(missing) == "")
        // A directory stamp still answers for a directory that is not there,
        // rather than throwing away the question.
        #expect(FileStamp.ofDirectory(missing).hasPrefix("unavailable-directory:"))
    }

    @Test("Adding, renaming or editing a file changes the directory signature")
    func directorySignatureCoversItsContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = FileStamp.ofDirectory(root)
        try Data("{}".utf8).write(to: root.appendingPathComponent("a.json"))
        let withOne = FileStamp.ofDirectory(root)
        #expect(withOne != empty)

        try Data("{\"x\":1}".utf8).write(to: root.appendingPathComponent("a.json"))
        let edited = FileStamp.ofDirectory(root)
        #expect(edited != withOne, "an in-place edit went unnoticed")

        try FileManager.default.moveItem(at: root.appendingPathComponent("a.json"),
                                         to: root.appendingPathComponent("b.json"))
        #expect(FileStamp.ofDirectory(root) != edited, "a rename went unnoticed")
    }
}
