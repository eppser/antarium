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
        "--demo-frames": "draws the README animation from an invented roster, same",
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

/// Every flag this file names is a flag something accepts.
///
/// Three — `--explorer`, `--analysis`, `--insights` — sat in a mutual-exclusion
/// group under a comment saying the groups "belong to modes that still exist".
/// None of the three was a mode or an option of one anywhere in the app. The set
/// `seen` only ever holds options the current mode declares, which is `--cloud`
/// or `--apply`, so that intersection was always empty and the check could not
/// fire. It read as a guard and was a comment.
///
/// The existing suites run the two directions that were checked: every documented
/// command is implemented, and every accepted-but-undocumented mode has a reason
/// written down. Neither could see a flag that is accepted by nothing, because
/// there was nothing to compare it against.
@Suite("No flag is named that nothing accepts")
struct DeadFlagTests {

    private var source: String {
        (try? SourceText.read("Sources/Antarium/Core/LaunchArguments.swift")) ?? ""
    }

    @Test("Every flag the validator mentions is a mode, an option, or documented")
    func noDeadFlagsAreNamed() throws {
        let text = source
        #expect(!text.isEmpty, "the validator could not be read")

        // Modes: the two declared sets and the dictionary keys. Read from the
        // whole declaration rather than line by line — both sets wrap, and the
        // first version of this called six real modes dead because their names
        // sat on a continuation line.
        var modes: Set<String> = []
        func flags(in fragment: String) -> [String] {
            fragment.components(separatedBy: "\"").enumerated()
                .filter { $0.offset % 2 == 1 && $0.element.hasPrefix("--") }
                .map(\.element)
        }
        for marker in ["let single:Set<String> = [", "let file:Set<String> = ["] {
            guard let start = text.range(of: marker) else { continue }
            let rest = text[start.upperBound...]
            let end = rest.firstIndex(of: "]") ?? rest.endIndex
            modes.formUnion(flags(in: String(rest[..<end])))
        }
        for line in text.split(separator: "\n") where line.contains("modes[") {
            modes.formUnion(flags(in: String(line)))
        }
        // Options belong to a mode and are named in the same place.
        var options: Set<String> = []
        for line in text.split(separator: "\n") where line.contains("options:[") {
            options.formUnion(flags(in: String(line)))
        }
        let accepted = modes.union(options).union(LaunchArguments.help.split(separator: " ")
            .map(String.init).filter { $0.hasPrefix("--") })

        // Every flag literal anywhere in the file, minus the ones accounted for.
        var named: Set<String> = []
        for line in text.split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
            named.formUnion(flags(in: code))
        }
        #expect(named.count >= 20,
                Comment(rawValue: "only \(named.count) flags were found, so this proved little"))
        let dead = named.subtracting(accepted).sorted()
        #expect(dead.isEmpty,
                Comment(rawValue: "named here and accepted by nothing: \(dead.joined(separator: ", "))"))
    }

    /// And the modes the validator knows are the ones `main.swift` dispatches or
    /// the internal list explains — which the suites above already hold. This
    /// only insists the set is not empty, so a rewrite of the parsing above
    /// cannot make the check vacuous by finding no modes at all.
    @Test("The validator still declares modes to check")
    func modesExist() {
        #expect(LaunchArguments.validate(["--status"]) == nil)
        #expect(LaunchArguments.validate(["--not-a-mode"]) != nil)
    }
}
