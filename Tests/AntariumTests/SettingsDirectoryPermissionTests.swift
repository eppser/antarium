import Foundation
import Testing
@testable import Antarium

/// The settings directory holds credentials, so it is not a settings
/// directory any more.
///
/// `~/.antarium` was created at 0755. On macOS every local account is in
/// `staff` and a home directory at 0750 is traversable by all of them, so a
/// key written there with a default umask would be readable by any other user
/// of the Mac. That was tolerable while the folder held preferences; it
/// stopped being so the moment a descriptor named a key file inside it —
/// which is a thing this app started doing, so this is its own mess.
@Suite("The settings directory is private to its owner")
struct SettingsDirectoryPermissionTests {

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-\(UUID().uuidString)")
    }

    @Test("A directory that does not exist is created private")
    func createsPrivate() throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Config.secure(url))
        #expect(try mode(url) & 0o077 == 0, "created readable by other users")
        #expect(try mode(url) & 0o700 == 0o700, "the owner cannot use it")
    }

    /// The case that was actually wrong on disk. An existing open directory
    /// has to be closed, or the fix only helps installations made after it.
    @Test("An existing directory that is open is tightened", arguments: [
        0o755, 0o750, 0o777, 0o705,
    ])
    func tightensExisting(_ start: Int) throws {
        let url = temporary()
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: start])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Config.secure(url))
        #expect(try mode(url) & 0o077 == 0, "0\(String(start, radix: 8)) was left open")
        // The owner's own access is untouched: tightening must not lock the
        // user out of their own settings.
        #expect(try mode(url) & 0o700 == start & 0o700)
    }

    /// Only tightened, never loosened, and never rewritten when it is already
    /// right — a chmod every launch is a change of mtime every launch.
    @Test("A directory that is already private is left exactly as it is")
    func leavesPrivateAlone() throws {
        let url = temporary()
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date
        #expect(Config.secure(url))
        #expect(try mode(url) == 0o700)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date
        #expect(before == after, "an already-private directory was rewritten")
    }

    /// Nested creation, because the keys directory is inside the settings one
    /// and a fresh install has neither.
    @Test("A keys directory under a missing parent is still created private")
    func createsNested() throws {
        let parent = temporary()
        defer { try? FileManager.default.removeItem(at: parent) }
        let keys = parent.appendingPathComponent("keys")
        #expect(Config.secure(keys))
        #expect(try mode(keys) & 0o077 == 0)
    }

    @Test("The keys directory is inside the settings directory")
    func keysLiveUnderSettings() {
        #expect(Config.keysDirectory.deletingLastPathComponent().path
                == Config.directory.path)
        #expect(Config.keysDirectory.lastPathComponent == "keys")
    }

    /// And the descriptors that name a key file name that directory, rather
    /// than each choosing somewhere of its own.
    @Test("Every key path a shipped descriptor names is under the keys directory")
    func shippedKeyPathsAgree() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard let credential = descriptor.quota?.credential,
                  let path = credential.path, path.contains("/keys/") else { continue }
            #expect(path.hasPrefix("~/.antarium/keys/"),
                    Comment(rawValue: "\(descriptor.id) keeps its key at \(path)"))
            checked += 1
        }
        #expect(checked >= 4, "only \(checked) descriptors name a key file")
    }
}

/// Securing the directories happens before any entry point uses them.
///
/// It used to happen in `start()`, which is the menu bar app and nothing
/// else. A folder that did not exist yet was created private and so looked
/// right; one that already existed — made by a version predating the
/// securing, or by hand — stayed exactly as it was through every command
/// line run, and the setup hints send people to put keys in it.
///
/// Checked in the source because the alternative is launching the app. The
/// rule above says what a private directory is; this says it is applied at
/// all, to both, and before anything dispatches.
@Suite("Every entry point secures the directories before using them")
struct SecureAtStartupContractTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Both directories are secured before any command is dispatched")
    func mainSecuresBoth() throws {
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/main.swift"), encoding: .utf8)
        let settings = try #require(text.range(of: "Config.secure(Config.directory)"),
                                    "the settings directory is left however it was made")
        let keys = try #require(text.range(of: "Config.secure(Config.keysDirectory)"),
                                "keys are written into a directory nobody made private")

        // Before the first thing that reads or writes the folder. `--run` is
        // the earliest dispatch and writes its own records in there.
        let firstCommand = try #require(text.range(of: "RunWrapper.run("),
                                        "the first command dispatch is gone")
        #expect(settings.lowerBound < firstCommand.lowerBound,
                "a command runs before the directory is made private")
        #expect(keys.lowerBound < firstCommand.lowerBound)
    }

    /// And it is not left behind in the app as well, where it would be the
    /// only copy that ever ran for somebody who uses the menu bar and a
    /// second copy that never runs for anybody else.
    @Test("The app no longer keeps its own copy of the rule")
    func appDoesNotDuplicateIt() throws {
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/AppController.swift"), encoding: .utf8)
        #expect(!text.contains("Config.secure("),
                "the securing is in two places, and only one of them runs for a command")
    }
}

/// A harness file is not a place to keep a credential, and no shipped note
/// may suggest it is.
///
/// Three of them said "paste the key straight into this file". Nothing reads
/// a key pasted into a descriptor — there is no literal credential kind — so
/// the instruction achieved exactly nothing except putting a secret in a file
/// that ships in this repository, is seeded into every install, and whose
/// edited copies stop receiving fixes.
@Suite("No harness tells anyone to keep a key in a harness file")
struct CredentialAdviceTests {

    private var shipped: [HarnessDescriptor] {
        get throws {
            let urls = try #require(AppResources.bundle.urls(
                forResourcesWithExtension: "json", subdirectory: "harnesses"))
            return try urls.sorted { $0.path < $1.path }.map {
                try HarnessDocument.decode(Data(contentsOf: $0)).descriptor
            }
        }
    }

    @Test("No note suggests putting a key in the descriptor")
    func noNoteSuggestsPastingAKey() throws {
        var checked = 0
        for descriptor in try shipped {
            let text = ((descriptor.note ?? "") + " "
                        + (descriptor.quota?.setupHint ?? "")).lowercased()
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            checked += 1
            for phrase in ["paste the key", "paste your key",
                           "key straight into this file", "key into this file"] {
                #expect(!text.contains(phrase), Comment(rawValue:
                    "\(descriptor.id) says \"\(phrase)\" — nothing reads a key kept there, "
                    + "and an edited descriptor stops receiving fixes"))
            }
        }
        #expect(checked >= 15, "only \(checked) descriptors carry text")
    }

    /// And the advice that is given names the file the credential actually
    /// reads, which is the same rule the env-hint test applies one level out.
    ///
    /// Compared as a whole word rather than as a substring. The first version
    /// used `note.contains(path)`, which a longer path sharing the prefix
    /// satisfies — a note pointing at `keys/minimax-api` while the credential
    /// reads `keys/minimax` passed, and the mutation that made exactly that
    /// change survived.
    @Test("A note naming a key file names the one the credential reads")
    func noteNamesTheRightFile() throws {
        var checked = 0
        for descriptor in try shipped {
            guard let note = descriptor.note, note.contains("~/.antarium/keys/"),
                  let path = descriptor.quota?.credential?.path else { continue }
            let named = note
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()")) }
            #expect(named.contains(path), Comment(rawValue:
                "\(descriptor.id) points at a key file its credential does not read: "
                + "the note names \(named.filter { $0.hasPrefix("~/.antarium/keys/") }) "
                + "and the credential reads \(path)"))
            checked += 1
        }
        #expect(checked >= 3, "only \(checked) notes name a key file")
    }
}
