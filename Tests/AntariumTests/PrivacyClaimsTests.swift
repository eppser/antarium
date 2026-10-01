import Foundation
import Testing
@testable import Antarium

/// The claims the README makes about what this app does to your machine and
/// where it connects.
///
/// "It reads configured process and session metadata"; "the built-in
/// dashboard can focus sessions, but it does not terminate agents, terminal
/// applications, or tmux sessions"; "runs locally and has no telemetry".
/// SECURITY.md carries the same trust model. All of them held and none was
/// checked — and two rounds ago I added a SIGKILL to this codebase, which is
/// precisely the kind of change that erodes the second one without anybody
/// meaning to.
@Suite("What the README promises about signals and hosts")
struct PrivacyClaimsTests {

    private var sources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    }

    /// Every signal this app can send goes to a process it started itself.
    /// An agent's pid comes from scanning the machine, and nothing may send
    /// it anything — the dashboard raises a window, it does not close one.
    @Test("No signal is sent to a process this app did not start")
    func signalsOnlyReachOwnChildren() throws {
        var offenders: [String] = []
        var found = 0
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("kill(") {
                // A comment naming the call is not the call.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                found += 1
                guard code.contains("process.processIdentifier") else {
                    offenders.append("\(url.lastPathComponent): \(code)")
                    continue
                }
            }
        }
        #expect(found >= 2, "only \(found) signal calls were seen, so this proved little")
        #expect(offenders.isEmpty,
                Comment(rawValue: "these signal something this app did not start: "
                        + offenders.joined(separator: " | ")))
    }

    /// And `terminate()` likewise: it is a method on a `Process` the app
    /// owns, so the check is that no other kind of object gets one.
    /// Counted, like its two neighbours. This one was not: it asserted a
    /// property of every `.terminate()` line it found and never checked that
    /// it had found one. An empty `sources`, a renamed call, or a spelling
    /// this scan does not match would all leave it examining nothing and
    /// reporting that every termination is of the app's own child.
    @Test("Only a process this app started is asked to terminate")
    func terminateOnlyOwnChildren() throws {
        var found = 0
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains(".terminate()") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                found += 1
                #expect(code.contains("process.terminate()"),
                        Comment(rawValue: "\(url.lastPathComponent) terminates something "
                                + "other than its own child: \(code)"))
            }
        }
        #expect(found >= 2,
                Comment(rawValue: "only \(found) termination(s) were seen, so this proved little"))
    }

    /// Where this app is able to connect. Every host is a vendor whose usage
    /// the user asked for, plus the project's own repository, which is only
    /// ever opened in a browser.
    @Test("The only hosts named are the ones whose usage is being read")
    func noUnexpectedHosts() throws {
        let allowed: Set<String> = [
            "api.anthropic.com",        // Claude usage
            "api2.cursor.sh",           // Cursor usage
            "chatgpt.com",              // Codex usage
            "cli-chat-proxy.grok.com",  // Grok usage
            "cloudcode-pa.googleapis.com", // Gemini usage
            "github.com",               // the repository link, opened in a browser
        ]
        var seen: Set<String> = []
        let pattern = try NSRegularExpression(pattern: #"https?://([a-zA-Z0-9.-]+)"#)
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let host = String(text[range])
                // Descriptors carry their own endpoints and are data, not
                // code; example.invalid and the like are documentation.
                guard !host.hasSuffix(".invalid"), !host.hasSuffix(".example") else { continue }
                seen.insert(host)
            }
        }
        #expect(!seen.isEmpty, "no hosts were found at all, so this proved nothing")
        #expect(seen.subtracting(allowed).isEmpty,
                Comment(rawValue: "hosts appear in the sources that are not accounted for: "
                        + seen.subtracting(allowed).sorted().joined(separator: ", ")))
    }

    /// Remote tmux is the one outward connection to a machine the user
    /// names, and the README says it is off until they turn it on.
    @Test("Remote tmux is off unless it has been turned on")
    func remoteTmuxIsOptIn() {
        #expect(Settings.includeRemoteTmux == false || !Settings.remoteTmuxHosts.isEmpty,
                "remote tmux is on with no hosts configured, which the README does not describe")
        // The default with nothing recorded is the claim that matters.
        #expect(Config.bool("includeRemoteTmux") == nil || Settings.includeRemoteTmux
                == (Config.bool("includeRemoteTmux") ?? false))
    }
}
