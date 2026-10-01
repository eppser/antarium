import Foundation
import Testing
@testable import Antarium

/// What this app can ask another machine to do.
///
/// It reaches one place outside this Mac: an ssh to a host the user named,
/// to list tmux panes. The command it sends is a constant in this repository.
/// There is no path by which a caller supplies one — and there was, in a
/// function nothing called.
///
/// `executeReadOnly(host:command:input:)` ran an arbitrary command on a
/// remote host, retried it with a password from the keychain, and had no
/// callers anywhere: not in the app, not in the tests, not in the tools. A
/// capability nothing uses is still a capability the security model has to
/// account for, and SECURITY.md describes what this app can do.
@Suite("The remote command is fixed")
struct RemoteCommandTests {

    private func source() throws -> String {
        try SourceText.read("Sources/Antarium/Core/RemoteTmux.swift")
    }

    /// Every ssh launch sends the one command this repository holds.
    @Test("Nothing sends a command that did not come from this file")
    func everyLaunchUsesTheFixedCommand() throws {
        let text = try source()
        var launches = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("Shell.execute(") else { continue }
            guard line.contains("ssh") || line.contains("sshpass") else { continue }
            launches += 1
        }
        #expect(launches >= 2,
                Comment(rawValue: "only \(launches) ssh launches were found, so this proved "
                        + "little"))
        // The argument lists that reach ssh, and the command each ends with.
        #expect(text.contains("\"--\", host, remoteCommand]"),
                "an ssh argument list ends with something other than the fixed command")
        let fixed = text.components(separatedBy: "\"--\", host, remoteCommand]").count - 1
        #expect(fixed == launches,
                Comment(rawValue: "\(launches) ssh launches and \(fixed) of them send the "
                        + "fixed command"))
    }

    /// And no function takes a command to run remotely. This is the shape
    /// that was removed; it is worth saying so rather than trusting that
    /// nobody writes it again.
    @Test("No remote call takes a command from its caller")
    func noCallerSuppliedCommand() throws {
        let text = try source()
        #expect(!text.contains("command: String"),
                "a remote call takes a command from its caller again")
        #expect(!text.contains("executeReadOnly"),
                "the unreferenced remote-execution function is back")
    }

    /// The destination is still checked, which is the other half: ssh takes
    /// options and the destination from one list, so a host beginning with a
    /// dash is an option — and `-oProxyCommand=…` runs a command on *this*
    /// Mac, every scan.
    @Test("A destination that is really an option is refused",
          arguments: ["-oProxyCommand=x", "--", "-l", "a b", "a;b", "a|b", "a$b",
                      "a`b`", "a\"b", "a'b", "", "host\n", "host\u{0}"])
    func unsafeHostsAreRefused(host: String) {
        #expect(!RemoteTmux.isSafeHost(host),
                Comment(rawValue: "\"\(host)\" was accepted as a destination"))
    }

    @Test("An ordinary destination is still accepted",
          arguments: ["example.com", "user@example.com", "10.0.0.2", "build-box",
                      "user@10.0.0.2", "my-host.local"])
    func ordinaryHostsAreAccepted(host: String) {
        #expect(RemoteTmux.isSafeHost(host),
                Comment(rawValue: "\"\(host)\" was refused"))
    }

    /// Surrounding space is acceptable input rather than a rejected host:
    /// this is asked while somebody is still typing, and a button that greys
    /// out over a trailing space explains nothing. What matters is that the
    /// value checked and the value sent are the same one — the list is
    /// normalised on the way in and on the way out, so everything downstream
    /// sees the trimmed form.
    @Test("Surrounding space is accepted as input and removed before use")
    func hostsAreNormalisedBeforeUse() {
        #expect(RemoteTmux.isSafeHost("  example.com  "),
                "a host with surrounding space is rejected while it is being typed")
        #expect(RemoteTmux.normalizedHosts(["  example.com  "]) == ["example.com"])
        #expect(RemoteTmux.normalizedHosts(["a", "a", " a "]) == ["a"],
                "the same host twice, once with space, is two hosts")
        #expect(RemoteTmux.normalizedHosts(["", "   "]).isEmpty)
    }

    /// And both ends of the setting normalise, or a host written into
    /// config.json by hand reaches ssh exactly as typed.
    @Test("The host list is normalised reading and writing")
    func settingsNormaliseBothWays() throws {
        let text = try SourceText.read("Sources/Antarium/UI/Settings.swift")
        let block = try SourceText.block("static var remoteTmuxHosts", in: text)
        #expect(block.components(separatedBy: "normalizedHosts").count - 1 == 2,
                Comment(rawValue: "the host list is normalised on only one side: \(block)"))
    }

    /// The argument list stops option parsing a second way, so a host that
    /// slipped the check above is still a destination rather than a flag.
    @Test("The argument list separates options from the destination")
    func argumentsUseTheSeparator() {
        let arguments = RemoteTmux.sshArguments(host: "example.com")
        let separator = try? #require(arguments.firstIndex(of: "--"))
        #expect(separator != nil, "the argument list no longer stops option parsing")
        if let separator, let host = arguments.firstIndex(of: "example.com") {
            #expect(separator < host, "the destination comes before the separator")
        }
    }
}
