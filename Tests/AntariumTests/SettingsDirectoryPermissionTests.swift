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

/// Securing the directories happens at startup, before anything is seeded
/// into them.
///
/// Checked in the source because `start()` builds menu bar items and a run
/// loop. The rule above says what a private directory is; this says it is
/// applied at all, and to both — the settings directory and the keys
/// directory inside it, which a fresh install has neither of.
@Suite("Startup secures the directories before it fills them")
struct SecureAtStartupContractTests {

    @Test("start() secures both directories, and does it before seeding")
    func startSecuresBoth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/AppController.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "func start() {"))
        let body = text[start.lowerBound...].prefix(900)

        let settings = try #require(body.range(of: "Config.secure(Config.directory)"),
                                    "the settings directory is left however it was made")
        let keys = try #require(body.range(of: "Config.secure(Config.keysDirectory)"),
                                "keys are written into a directory nobody made private")
        let seed = try #require(body.range(of: "HarnessDescriptor.seed()"),
                                "start() no longer seeds")
        #expect(settings.lowerBound < seed.lowerBound,
                "the directory is filled before it is made private")
        #expect(keys.lowerBound < seed.lowerBound)
    }
}
