import Foundation
import Testing
@testable import Antarium

@Suite("Command-line validation before application startup")
struct LaunchArgumentsTests {
    @Test("Unknown, incomplete or conflicting diagnostics cannot fall through to normal startup")
    func invalid() {
        for args in [["--activity-presentation-soak","60"],["--soak-activity-ui"],
            ["--migrate-harness","fixture.json"],["--agents","--once"],
            ["--model"],["--status","--typo"],["--activity-demo"],["--soak-activity","60"],["--log","-1"],["--log","1001"],
            ] {
            #expect(LaunchArguments.validate(args) != nil)
        }
    }
    @Test("Known diagnostics preserve their documented argument shapes")
    func valid() {
        for args in [["--migrate-harness","input.json","output.json"],["--agents","--cloud"],
            ["--remote-tmux","fixture-one","fixture-two"],["--log"],["--log","0"],
            ["--once","synthetic"],["--help"]] {
            #expect(LaunchArguments.validate(args) == nil)
        }
    }
    @Test("Normal and recognized macOS launches remain valid, without accepting arbitrary options")
    func platform() {
        #expect(LaunchArguments.validate([]) == nil)
        #expect(LaunchArguments.validate(["-psn_0_12345"]) == nil)
        #expect(LaunchArguments.validate(["-NSDocumentRevisionsDebugMode","YES"]) == nil)
        #expect(LaunchArguments.validate(["-psn_not-a-number"]) != nil)
        #expect(LaunchArguments.validate(["-UnknownStartupOption","YES"]) != nil)
    }
    @Test("Child wrapper flags cannot be intercepted as Antarium help")
    func childHelp() {
        let args = ["run","--","synthetic-command","--help"]
        #expect(LaunchArguments.validate(args) == nil)
        #expect(!LaunchArguments.requestsHelp(args))
        #expect(LaunchArguments.requestsHelp(["--help"]))
    }

}

/// Every command `--help` offers is a command that exists.
///
/// Seven did not. A whole "Synthetic activity validation" section listed
/// modes that no file outside this one mentioned — so `--help` advertised
/// them, the validator accepted them, and main.swift matched none of them,
/// which meant running one silently launched the menu bar app. An unknown
/// flag gets "Unknown command. Use --help for supported modes."; a
/// documented one got a GUI, which is worse, because the user has reason to
/// believe it worked.
@Suite("Every documented command is implemented")
struct DocumentedCommandsExistTests {

    private var sources: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            // The help text and the validator name every mode by definition;
            // the question is whether anything else does.
            .filter { $0.lastPathComponent != "LaunchArguments.swift" } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    /// Flags as `--help` writes them, which is where a reader gets them.
    private var documented: [String] {
        var found: [String] = []
        for line in LaunchArguments.help.split(separator: "\n") {
            for word in line.split(whereSeparator: { " |[]<>".contains($0) })
            where word.hasPrefix("--") {
                found.append(String(word))
            }
        }
        return Array(Set(found)).sorted()
    }

    @Test("Each flag in the help text is handled somewhere")
    func documentedFlagsAreHandled() {
        #expect(documented.count > 15, "only \(documented.count) flags were read from the help")
        let code = sources
        var orphaned: [String] = []
        for flag in documented where !code.contains("\"\(flag)\"") {
            orphaned.append(flag)
        }
        #expect(orphaned.isEmpty,
                Comment(rawValue: "the help offers these and nothing implements them: "
                        + orphaned.joined(separator: ", ")))
    }

    /// And the check would notice: asked of a flag that is deliberately not
    /// in the help, it finds nothing.
    @Test("The check can tell an unimplemented flag from an implemented one")
    func theCheckWouldNotice() {
        #expect(!sources.contains("\"--no-such-mode\""),
                "the probe flag exists, so this proves nothing")
        #expect(sources.contains("\"--status\""),
                "a flag that is certainly implemented was not found, so the check is blind")
    }
}
