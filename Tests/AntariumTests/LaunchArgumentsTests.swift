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

    /// Handled inside the validator itself, which this check excludes so it
    /// cannot agree with itself. `requestsHelp` answers these before any mode
    /// is matched, so no other file names them.
    private static let handledByTheValidator: Set<String> = ["--help", "-h"]

    @Test("Each flag in the help text is handled somewhere")
    func documentedFlagsAreHandled() {
        #expect(documented.count > 15, "only \(documented.count) flags were read from the help")
        let code = sources
        var orphaned: [String] = []
        for flag in documented where !code.contains("\"\(flag)\"")
            && !Self.handledByTheValidator.contains(flag) {
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

/// A mode the validator accepts is either documented or deliberately not.
///
/// Eight were accepted and absent from `--help` with nothing recording which
/// they were. Six are design harnesses that render a view to a file — useful
/// when working on this app, meaningless to anybody else — and two were
/// simply undocumented: the remote pair, one of which is now part of the
/// release gate. Left untracked, the next mode added quietly joins whichever
/// group nobody notices.
@Suite("Undocumented modes are a decision, not an oversight")
struct InternalModesAreListedTests {

    /// Accepted, deliberately absent from the help, and why.
    private static let internalModes: [String: String] = [
        "--preview": "renders a menu bar item to a file, for working on the drawing",
        "--dashboard": "renders the dashboard to a file, same",
        "--alert": "renders a notification banner to a file, same",
        "--settings": "renders the settings panel to a file, same",
        "--onboarding": "renders the first-run screen to a file, same",
        "--focus": "clicks a row from the terminal and reports what the click did",
    ]

    /// Flags named anywhere in the help text.
    private var documentedFlags: Set<String> {
        var found: Set<String> = []
        for line in LaunchArguments.help.split(separator: "\n") {
            for word in line.split(whereSeparator: { " |[]<>".contains($0) })
            where word.hasPrefix("--") {
                found.insert(String(word))
            }
        }
        return found
    }

    /// Every mode the validator accepts, read out of the validator.
    ///
    /// The first version drew its candidates from the help text and the
    /// internal list, which made it blind to exactly what it was looking
    /// for: a mode in neither was never probed, so adding one survived, and
    /// so did deleting a help line. A check that only looks where it already
    /// knows finds nothing new.
    private func acceptedModes() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Core/LaunchArguments.swift"), encoding: .utf8)
        let body = String(source[(source.range(of: "static func validate")?.lowerBound
                                  ?? source.startIndex)...])
        var found: Set<String> = []
        // `modes["--x"] = …` and the two sets it is seeded from.
        for pattern in [#"modes\["(--[a-z-]+)"\]"#, #""(--[a-z-]+)""#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let range = Range(match.range(at: 1), in: body) else { continue }
                let flag = String(body[range])
                // Options belong to a mode rather than being one, so ask.
                if LaunchArguments.validate([flag]) == nil
                    || LaunchArguments.validate([flag, "fixture"]) == nil {
                    found.insert(flag)
                }
            }
        }
        return found
    }

    @Test("Every accepted mode is documented or listed as internal")
    func modesAreAccountedFor() throws {
        let accepted = try acceptedModes()
        #expect(accepted.count > 15, "only \(accepted.count) modes were accepted")
        let unaccounted = accepted.subtracting(documentedFlags)
            .subtracting(Self.internalModes.keys)
        #expect(unaccounted.isEmpty,
                Comment(rawValue: "accepted, undocumented and unexplained: "
                        + unaccounted.sorted().joined(separator: ", ")))
    }

    /// And the list does not excuse modes that no longer exist.
    @Test("Every internal mode is still accepted")
    func internalModesStillExist() {
        for (mode, reason) in Self.internalModes {
            #expect(!reason.isEmpty)
            #expect(LaunchArguments.validate([mode]) == nil
                    || LaunchArguments.validate([mode, "fixture"]) == nil,
                    Comment(rawValue: "\(mode) is listed as internal and is not accepted"))
        }
    }
}
