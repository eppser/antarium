import Foundation
import Testing
@testable import Antarium

/// Every command this application can launch.
///
/// SECURITY.md says "Bundled harness commands are covered by an explicit test
/// allowlist", and they are — a suite lists the three a shipped descriptor
/// may run, so adding one is a decision. That covers descriptors and stops
/// there. The native providers launch their own CLIs, and the remote feature
/// launches ssh and the keychain tool, and none of those was in any list:
/// somebody reading the trust model to decide whether to install this cannot
/// tell from it what the app may execute.
///
/// This is the rest of the sentence. Together the two suites account for
/// every `Shell.execute` in the project.
@Suite("Only known commands are launched")
struct LaunchedCommandsTests {

    /// Literal executables, each with why it is run.
    private static let allowed: [String: String] = [
        "/usr/bin/security": "reads a stored credential, and removes one the user deletes",
        "/usr/bin/ssh": "the remote tmux inventory, on a host the user named",
        "sshpass": "the same, when the user's host needs a password rather than a key",
        "amp": "`amp usage --no-color`, which is how Amp reports its own figures",
        "kiro-cli": "Kiro reports usage through its CLI and no endpoint",
        "gemini": "run so the CLI refreshes its own credential, rather than this app writing one",
    ]

    /// Files where the executable is a variable because it came from a
    /// descriptor, and is therefore covered by the harness allowlist.
    private static let fromDescriptors: Set<String> = [
        "HarnessEngine.swift",      // source.command
        "SessionSelection.swift",   // selection.command
        "Focus.swift",              // focus.command
        "DescriptorProvider.swift", // quota.command and credential.command
        "ClaudeCredentials.swift",  // /usr/bin/security, resolved once
        "GeminiProvider.swift", "AmpProvider.swift", "KiroProvider.swift",
        "RemoteTmux.swift",
    ]

    @Test("Every launch is either allowlisted or comes from a descriptor")
    func everyLaunchIsAccountedFor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        var launches = 0, unaccounted: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("Shell.execute(") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                launches += 1
                // A literal executable must be named; anything else must sit
                // in a file whose executable came from a descriptor.
                if let open = code.range(of: "Shell.execute(") {
                    let rest = code[open.upperBound...]
                    if rest.hasPrefix("\"") {
                        let literal = String(rest.dropFirst().prefix { $0 != "\"" })
                        if Self.allowed[literal] == nil {
                            unaccounted.append("\(url.lastPathComponent): \(literal)")
                        }
                        continue
                    }
                }
                if !Self.fromDescriptors.contains(url.lastPathComponent) {
                    unaccounted.append("\(url.lastPathComponent): \(code.prefix(60))")
                }
            }
        }
        #expect(launches >= 10, "only \(launches) launches were seen, so this proved little")
        #expect(unaccounted.isEmpty,
                Comment(rawValue: "commands launched from nowhere accounted for: "
                        + unaccounted.joined(separator: " | ")))
    }

    /// Named executables that are not resolved on PATH are absolute, so a
    /// directory earlier in somebody's PATH cannot stand in for the keychain
    /// tool or ssh.
    @Test("The security and ssh tools are absolute paths")
    func systemToolsAreAbsolute() {
        for tool in ["/usr/bin/security", "/usr/bin/ssh"] {
            #expect(Self.allowed[tool] != nil)
            #expect(tool.hasPrefix("/usr/bin/"), "\(tool) would be resolved on PATH")
        }
        // The vendors' own CLIs are resolved on PATH on purpose — they are
        // installed wherever the user installed them — so the check is on
        // the source, not on this list. Asking the list whether its own
        // entries are absolute is a question it answers about itself: the
        // first version did that, and changing a call site to resolve
        // /opt/homebrew/bin/amp survived it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var absolute: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n")
            where line.contains("CommandPath.resolve(\"") {
                guard let open = line.range(of: "CommandPath.resolve(\"") else { continue }
                let name = String(line[open.upperBound...].prefix { $0 != "\"" })
                if name.hasPrefix("/") { absolute.append("\(url.lastPathComponent): \(name)") }
            }
        }
        #expect(absolute.isEmpty,
                Comment(rawValue: "resolved as an absolute path, which misses a normal "
                        + "install: \(absolute.joined(separator: ", "))"))
    }

    /// Each entry says why, so removing a command is as deliberate as adding
    /// one.
    @Test("Every allowed command has a reason")
    func reasonsAreGiven() {
        #expect(Self.allowed.count >= 6)
        for (command, reason) in Self.allowed {
            #expect(!reason.isEmpty, Comment(rawValue: "\(command) is allowed with no reason"))
        }
    }
}
