import Foundation
import Testing
@testable import Antarium

/// Static mutable state, and what makes each piece of it safe.
///
/// Swift 6 checks concurrency, and `nonisolated(unsafe)` is how a file opts
/// out of that check. It is the right tool for state guarded by a lock the
/// compiler cannot see — this app has a dozen such caches, each with its own
/// `NSLock`. It is the wrong tool for state that simply never leaves the
/// main actor, because then it asserts something the compiler was willing to
/// prove.
///
/// Neither case can be caught by running anything: an unguarded write races
/// only sometimes, and an unnecessary opt-out behaves identically. So they
/// are asserted here, against the source.
@Suite("Shared mutable state says how it is protected")
struct SharedStateTests {

    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
            }
    }

    /// Every file that opts out of the concurrency check holds a lock.
    ///
    /// Not proof that every access takes it — that needs reading — but a file
    /// with unsafe state and no lock in it has nothing that could.
    @Test("A file with unguarded shared state has a lock in it")
    func unsafeStateComesWithALock() throws {
        var checked = 0, missing: [String] = []
        for (name, text) in try sources() {
            guard text.contains("nonisolated(unsafe)") else { continue }
            // A `let` formatter or similar is shared but never written.
            let mutable = text.contains("nonisolated(unsafe) private static var")
                || text.contains("nonisolated(unsafe) static var")
                || text.contains("nonisolated(unsafe) private(set) static var")
            guard mutable else { continue }
            checked += 1
            let guarded = text.contains("NSLock") || text.contains("DispatchQueue")
                || text.contains("sig_atomic_t") || text.contains("os_unfair_lock")
            if !guarded { missing.append(name) }
        }
        #expect(checked >= 10,
                Comment(rawValue: "only \(checked) files carry unsafe shared state, so this "
                        + "is not looking at what it thinks it is"))
        #expect(missing.isEmpty,
                Comment(rawValue: "shared mutable state with nothing in the file that could "
                        + "guard it: \(missing.sorted().joined(separator: ", "))"))
    }

    /// A closed set the app defines answers every question for every case,
    /// by listing them rather than by defaulting.
    ///
    /// `default:` in a switch over one of our own enums is a decision made in
    /// advance for a case that does not exist yet. `AgentRow.State` had one:
    /// `rank` and `label` were exhaustive, so adding a state was a compile
    /// error in both and had to be thought about, while `isBusy` answered
    /// "not busy" for it silently — and a busy state reading as idle drives
    /// the "an agent finished" notification and the sort.
    ///
    /// A switch over somebody else's values — an HTTP status, a URLError
    /// code, a SQLite result — is the opposite case and keeps its default.
    @Test("The states and the errors answer for every case they have")
    func closedSetsAreExhaustive() throws {
        for (file, type) in [("Sources/Antarium/Core/AgentScan.swift", "enum State"),
                             ("Sources/Antarium/Core/UsageModel.swift", "enum ProviderError")] {
            let text = try SourceText.read(file)
            let block = try SourceText.block(type, in: text)
            let defaults = block.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("default:") }
            #expect(defaults.isEmpty,
                    Comment(rawValue: "\(type) answers a question by default, so a case "
                            + "added later gets that answer without anybody choosing it"))
            // And it is a real block with real switches, not an empty read.
            #expect(block.contains("switch self"),
                    Comment(rawValue: "\(type) has no switch in it, so this proved nothing"))
        }
    }

    /// The one that was the other kind. `LaunchAtLogin.refusal` records why
    /// the system refused to register a login item, and every surface that
    /// touches it is a menu handler or a settings view. It was marked unsafe,
    /// which asserted main-actor confinement instead of stating it — and the
    /// compiler was willing to prove it.
    ///
    /// Reverting that cannot be caught by running anything: the behaviour is
    /// identical and the difference is what the compiler will accept next
    /// time. So it is asserted here.
    @Test("The login refusal is confined rather than declared safe")
    func loginRefusalIsConfined() throws {
        let text = try SourceText.read("Sources/Antarium/Core/LaunchAtLogin.swift")
        #expect(text.contains("@MainActor private(set) static var refusal"),
                "the refusal is shared on trust again rather than confined")
        // Code, not prose: the comment above the declaration names the thing
        // it stopped being, and asking the whole file matched that.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("nonisolated(unsafe)"),
                "this file opts out of the concurrency check and has no lock to justify it")
        // And the writer is confined too, or the property's isolation is
        // just a compile error waiting at the next call site.
        #expect(text.contains("@MainActor static func set("),
                "the setter is no longer confined, so the property cannot be")
    }
}
