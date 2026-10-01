import Foundation
import Testing
@testable import Antarium

/// The strict-concurrency audit has to actually audit.
///
/// It was two halves and neither checked. `verify.sh` greps the build's output and
/// fails on `warning:`, but reused `/tmp/antarium-strict` — and `swift build` only
/// emits diagnostics for the files it recompiles, so from the second run onwards it
/// reported warnings only in whatever had changed. A warning in an untouched file
/// was reported once and never again. CI built with the same flags in a fresh
/// checkout, so it compiled everything, and then read nothing: warnings do not fail
/// a build, so that step passed whatever it found.
///
/// Together they meant nothing reliably enforced strict concurrency. A `@MainActor`
/// isolation warning introduced during this audit was reported by the run that
/// recompiled the file and absent from a rebuild by hand, which nearly read as a
/// flaky gate rather than a real warning.
///
/// Source-read, as several checks here already are: the claim is about what the
/// scripts do, so the scripts are what is read.
@Suite("The strict-concurrency audit cannot quietly stop auditing")
struct StrictConcurrencyGateTests {

    private func repositoryFile(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The local gate builds from scratch, or it only sees what changed.
    ///
    /// Asked line by line. Asking it of the text between the clear and the build
    /// cannot work: the build's own `swift build` sits between them, on the line
    /// before its `--scratch-path`, so "no build in between" is true of no arrangement
    /// at all. The claim is that the clear is a *nearby preceding line*, and that is
    /// what is checked.
    @Test("verify.sh clears the strict scratch path before building")
    func verifyBuildsFromScratch() throws {
        let lines = try repositoryFile("verify.sh").split(separator: "\n",
                                                         omittingEmptySubsequences: false)
        let buildLine = try #require(lines.firstIndex { $0.contains("--scratch-path /tmp/antarium-strict") },
                                     "verify.sh no longer runs a strict build at that path")
        // Back over the invocation and its comment to find the clear.
        let window = lines[max(0, buildLine - 20)..<buildLine]
        #expect(window.contains { $0.trimmingCharacters(in: .whitespaces)
                    == "rm -rf /tmp/antarium-strict" },
                Comment(rawValue: "verify.sh reuses the strict scratch path, so it reports "
                        + "diagnostics only for files that changed since the last run"))
    }

    /// And it reads what the build said, which it always did.
    @Test("verify.sh fails on a strict warning")
    func verifyFailsOnWarning() throws {
        let script = try repositoryFile("verify.sh")
        #expect(script.contains("bad \"strict build reported diagnostics\""),
                "verify.sh no longer fails on a strict diagnostic")
        #expect(script.contains("grep -qE 'error:|warning:'"),
                "verify.sh no longer looks for warnings in the strict output")
    }

    /// The shared gate reads it too, which it did not.
    @Test("CI fails on a strict warning rather than only on an error")
    func ciFailsOnWarning() throws {
        let workflow = try repositoryFile(".github/workflows/ci.yml")
        let step = try #require(workflow.range(of: "Audit strict Swift concurrency"),
                                "CI no longer audits strict concurrency")
        // To the next step, so this is about that step rather than the file.
        let rest = workflow[step.upperBound...]
        let body = rest.range(of: "\n      - name:").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        // The grep itself, not the substring. A first version asked whether the step
        // mentioned "warning:" anywhere, which the explanatory comment in the step
        // also does — so a mutation that stopped the grep looking for warnings left
        // the test passing. A claim about what a script does has to name the thing
        // that does it.
        #expect(body.contains("grep -qE 'error:|warning:'"),
                Comment(rawValue: "CI runs the strict build and never greps its output "
                        + "for warnings — warnings do not fail a build, so the step "
                        + "passes whatever it finds"))
        // And the branch that grep guards has to end the step.
        let afterGrep = try #require(body.range(of: "grep -qE 'error:|warning:'"))
        #expect(body[afterGrep.upperBound...].contains("exit 1"),
                "CI greps for a strict diagnostic and does not fail on finding one")
    }

    /// Both halves, stated as one claim: the audit is enforced in two places and
    /// neither may rest on the other. Either alone was how this went unnoticed.
    @Test("Both gates enforce it independently")
    func bothGatesEnforceIt() throws {
        let script = try repositoryFile("verify.sh")
        let workflow = try repositoryFile(".github/workflows/ci.yml")
        for (name, text) in [("verify.sh", script), ("ci.yml", workflow)] {
            #expect(text.contains("strict-concurrency=complete"),
                    Comment(rawValue: "\(name) does not build with strict concurrency"))
            #expect(text.contains("warn-concurrency"),
                    Comment(rawValue: "\(name) does not ask for concurrency warnings"))
        }
    }
}
