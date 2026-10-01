import Foundation
import Testing
@testable import Antarium

/// What the file signature must notice, stated as edits rather than as
/// fields.
///
/// `IdentityAndStampTests` already covers the components and records why they
/// cannot be isolated: the stamp is deliberately over-specified, and
/// `st_ctimespec` moves whenever size, content, inode or mtime does, so
/// removing any one of them changes nothing observable. That redundancy is
/// the point — ctime is not guaranteed on every filesystem a harness folder
/// might live on — and it is why a mutation deleting the nanoseconds or the
/// size survives without being a gap.
///
/// These are the edits themselves, which is the question a caller actually
/// has, plus the one distinction that is observable: a file that is missing
/// against one that cannot be read.
@Suite("Edits a file signature must notice")
struct FileStampEditTests {

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stamp-\(UUID().uuidString)")
    }

    private func write(_ url: URL, _ contents: String, at seconds: Double? = nil) throws {
        try Data(contents.utf8).write(to: url)
        if let seconds {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: url.path)
        }
    }

    /// A script can rewrite a file twice within one second. Second-resolution
    /// alone would call the second write no change at all.
    @Test("Two edits inside the same second are different")
    func subSecondEditsDiffer() throws {
        let file = temporary()
        defer { try? FileManager.default.removeItem(at: file) }
        try write(file, "one", at: 1_700_000_000.25)
        let first = FileStamp.of(file)
        try write(file, "two", at: 1_700_000_000.75)
        #expect(FileStamp.of(file) != first,
                "a rewrite within the same second read as no change")
    }

    /// And an edit that leaves the length alone — a flag flipped from true to
    /// fals… no, from 1 to 0 — at the same timestamp.
    @Test("An edit that changes neither length nor time is still caught")
    func sameLengthSameTimeDiffers() throws {
        let file = temporary()
        defer { try? FileManager.default.removeItem(at: file) }
        try write(file, "aaaa", at: 1_700_000_000)
        let first = FileStamp.of(file)
        try write(file, "bbbb", at: 1_700_000_000)
        // The content changed, the size did not, and the modification time was
        // forced back — only the inode's change time moved.
        #expect(FileStamp.of(file) != first,
                "an edit of the same length at the same time read as no change")
    }

    /// The size half, isolated: same timestamp, different length.
    @Test("An edit that changes the length is caught")
    func differentLengthDiffers() throws {
        let file = temporary()
        defer { try? FileManager.default.removeItem(at: file) }
        try write(file, "short", at: 1_700_000_000)
        let first = FileStamp.of(file)
        try write(file, "considerably longer", at: 1_700_000_000)
        #expect(FileStamp.of(file) != first)
    }

    @Test("An untouched file keeps its signature")
    func untouchedIsStable() throws {
        let file = temporary()
        defer { try? FileManager.default.removeItem(at: file) }
        try write(file, "one", at: 1_700_000_000)
        #expect(FileStamp.of(file) == FileStamp.of(file))
    }

    /// Missing and unreadable are different facts. A file that is there but
    /// cannot be read must not look like one that was deleted, or a
    /// permissions problem reads as an agent being uninstalled.
    @Test("A missing file is empty, and an unreadable one says so")
    func missingIsNotUnreadable() throws {
        #expect(FileStamp.of(temporary()).isEmpty)

        let folder = temporary()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let inside = folder.appendingPathComponent("hidden.json")
        try write(inside, "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: folder.path)
        let stamp = FileStamp.of(inside)
        // Root ignores the permission bits, so this only asserts when the
        // directory actually became unreadable.
        if !stamp.isEmpty || getuid() != 0 {
            #expect(stamp != "", "an unreadable file read as a deleted one")
            #expect(stamp.hasPrefix("unavailable:"))
        }
    }
}

/// The directory half: a folder of descriptors, where adding, deleting,
/// renaming and editing must each change the answer.
@Suite("A directory's change signature notices every kind of edit")
struct DirectoryStampTests {

    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirstamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: url.appendingPathComponent(name))
        }
        return url
    }

    @Test("Adding a descriptor changes the signature")
    func addingChangesIt() throws {
        let url = try folder(["a.json": "{}"])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileStamp.ofDirectory(url)
        try Data("{}".utf8).write(to: url.appendingPathComponent("b.json"))
        #expect(FileStamp.ofDirectory(url) != first)
    }

    @Test("Deleting a descriptor changes the signature")
    func deletingChangesIt() throws {
        let url = try folder(["a.json": "{}", "b.json": "{}"])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileStamp.ofDirectory(url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("b.json"))
        #expect(FileStamp.ofDirectory(url) != first)
    }

    /// The name is part of the signature, so a rename is an edit. Without it
    /// a descriptor renamed from `cursor.json` to `cursor.json.off` — the
    /// obvious way to turn one off — would go on being used.
    @Test("Renaming a descriptor changes the signature")
    func renamingChangesIt() throws {
        let url = try folder(["a.json": "{}"])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileStamp.ofDirectory(url)
        try FileManager.default.moveItem(at: url.appendingPathComponent("a.json"),
                                         to: url.appendingPathComponent("z.json"))
        #expect(FileStamp.ofDirectory(url) != first,
                "a renamed descriptor read as no change")
    }

    /// Only `.json` is listed by name, and that is what the extension filter
    /// is for: an editor's swap file being *edited* must not reparse every
    /// harness on the machine.
    ///
    /// Creating one still does, because the folder's own stamp is part of the
    /// signature and appears in it whatever the file is called. That is
    /// deliberate — it is what catches an addition on a filesystem whose
    /// listing might not — and the cost is a reparse at the moment somebody
    /// is editing a descriptor anyway. Both halves are asserted so neither
    /// reads as an accident.
    @Test("Editing a file that is not a descriptor does not change the signature")
    func editingOtherFilesIsIgnored() throws {
        let url = try folder(["a.json": "{}"])
        defer { try? FileManager.default.removeItem(at: url) }
        let scratch = url.appendingPathComponent("a.json.swp")
        try Data("scratch".utf8).write(to: scratch)

        let first = FileStamp.ofDirectory(url)
        try Data("a much longer scratch buffer".utf8).write(to: scratch)
        #expect(FileStamp.ofDirectory(url) == first,
                "editing an editor's scratch file reparsed every harness")
    }

    @Test("Creating any file changes the signature, descriptor or not")
    func creatingAnythingChangesIt() throws {
        let url = try folder(["a.json": "{}"])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileStamp.ofDirectory(url)
        try Data("scratch".utf8).write(to: url.appendingPathComponent("notes.txt"))
        #expect(FileStamp.ofDirectory(url) != first)
    }

    /// The order is the sort, not the filesystem's. Two runs over the same
    /// folder must agree, or every read looks like a change.
    @Test("The signature is stable across repeated reads")
    func orderIsStable() throws {
        let names = ["z.json", "m.json", "a.json", "b.json", "y.json",
                     "q.json", "c.json", "k.json"]
        let url = try folder(Dictionary(uniqueKeysWithValues: names.map { ($0, "{}") }))
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileStamp.ofDirectory(url)
        for _ in 0..<5 {
            #expect(FileStamp.ofDirectory(url) == first,
                    "the same folder produced two different signatures")
        }
    }

    @Test("A folder that is not there says so rather than looking empty")
    func missingFolder() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)")
        #expect(FileStamp.ofDirectory(url).hasPrefix("unavailable-directory:"))
    }
}
