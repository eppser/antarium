import Foundation
import Testing
@testable import Antarium

/// A subprocess that will not stop must not be able to wedge the caller.
///
/// Two places here run one. `Shell` has escalated from SIGTERM to SIGKILL
/// since it was written. `ClaudeCredentials.runSecurity` says of itself that
/// it "runs `/usr/bin/security` with a watchdog, so a stuck authorisation
/// dialog can never wedge the refresh loop" — and sent SIGTERM once, which a
/// process sitting on a modal dialog is free to ignore. The read below it
/// blocks until the pipe closes, so ignoring it wedges exactly the loop the
/// watchdog exists to protect.
///
/// The behaviour is checked against a real process that ignores SIGTERM,
/// because a source rule would only say the call is written down.
@Suite("A process that ignores being asked to stop is stopped anyway")
struct SubprocessWatchdogTests {

    /// Traps SIGTERM and sleeps. `Shell` must still return, and quickly.
    private let deaf = ["-c", "trap '' TERM; sleep 30"]

    @Test("Shell gives up on a process that ignores SIGTERM")
    func shellEscalates() throws {
        let began = Date()
        let result = Shell.execute("/bin/sh", deaf, timeout: 1, outputLimit: 4_096)
        let waited = Date().timeIntervalSince(began)
        #expect(result.timedOut, "the run did not report a timeout")
        #expect(waited < 10,
                Comment(rawValue: "waited \(String(format: "%.1f", waited))s for a process "
                        + "that ignores SIGTERM"))
        // Returning promptly is not the same as stopping it, and the first
        // version of this test only checked the former — which holds whether
        // the process is killed or merely abandoned. A status exists only
        // once the process is reaped, so this is the half that needs SIGKILL.
        #expect(result.exitCode != nil,
                "the process was left running after the timeout, holding whatever it held")
    }

    /// And the credential reader escalates too, which is the half it was
    /// missing. Checked in the source: the only way to exercise it is a
    /// keychain prompt on whoever is running the suite.
    @Test("The credential reader escalates as well")
    func credentialReaderEscalates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Providers/ClaudeCredentials.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "private static func runSecurity"),
                                 "the credential reader was renamed")
        let body = String(text[start.lowerBound...].prefix(2_200))
        #expect(body.contains("terminate()"), "nothing asks the process to stop")
        #expect(body.contains("SIGKILL"),
                "a process that ignores SIGTERM still wedges the refresh loop")
        #expect(body.contains("force.cancel()"),
                "the kill is scheduled and never cancelled, so it outlives the call")
    }
}
