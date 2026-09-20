import Foundation
import Testing
@testable import Antarium

/// Sorting by the name the row shows, and the SSH-backed tmux source.
struct SortAndRemoteTmuxTests {

    private func row(_ cwd: String, _ state: AgentRow.State = .waiting,
                     activity: Date? = nil) -> AgentRow {
        var value = AgentRow(id: cwd, agentID: "test", name: "session",
                             cwd: cwd, state: state)
        value.lastActivity = activity
        return value
    }

    // MARK: - Sort by name

    @Test("Sorting by name orders on what the row actually displays")
    func nameSortUsesCoreName() {
        // Not the id and not `name` — `coreName`, which is what the dashboard
        // draws. Sorting on a field the user cannot see is indistinguishable
        // from not sorting at all.
        let sorted = AgentScan.sorted([
            row("/Users/x/work/zebra"),
            row("/Users/x/work/apple"),
            row("/Users/x/work/mango"),
        ], by: .name)
        #expect(sorted.map(\.coreName) == ["Apple", "Mango", "Zebra"])
    }

    @Test("Name sorting ignores case rather than pushing lowercase to the end")
    func nameSortIsCaseInsensitive() {
        // A plain `<` on Strings puts every capitalised name before every
        // lowercase one, which reads as a broken alphabet.
        let sorted = AgentScan.sorted([
            row("/w/ZeroDayClock"),
            row("/w/antarium"),
            row("/w/Beta"),
        ], by: .name)
        #expect(sorted.map(\.coreName) == ["Antarium", "Beta", "ZeroDayClock"])
    }

    @Test("Rows sharing a name fall back to status, then to recency")
    func nameSortBreaksTiesDeterministically() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        var working = row("/a/spicy", .working, activity: recent); working.id = "working"
        var waitingOld = row("/b/spicy", .waiting, activity: old); waitingOld.id = "waiting-old"
        var waitingNew = row("/c/spicy", .waiting, activity: recent); waitingNew.id = "waiting-new"

        let sorted = AgentScan.sorted([working, waitingOld, waitingNew], by: .name)
        // Same name for all three, so status decides first (waiting outranks
        // working), then the more recent of the two waiting rows.
        #expect(sorted.map(\.id) == ["waiting-new", "waiting-old", "working"])
    }

    @Test("Name is a first-class sort option and status is no longer one")
    func nameReplacedStatusInTheSortOptions() {
        #expect(AgentSort.allCases.contains(.name))
        #expect(AgentSort(rawValue: "name") == .name)
        #expect(AgentSort(rawValue: "status") == nil)
        #expect(AgentSort.name.title == "Name")
    }

    // MARK: - Remote tmux

    /// One pane running Codex directly, one running Claude Code under node
    /// two processes deep, and a pane with nothing of interest.
    private var sample: String {
        """
        910\tquibus-1:@1.%1\t/srv/checkout/apple
        920\tquibus-1:@2.%2\t/srv/checkout/mango
        930\tquibus-2:@1.%3\t/srv/idle
        \(RemoteTmux.psSeparator)
        910 1 bash -bash
        911 910 codex /home/se/.codex/packages/standalone/releases/1.2.3/bin/codex
        920 1 bash -bash
        921 920 sh /bin/sh -c npm start
        922 921 node node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js --serve
        930 1 bash -bash
        931 930 vim vim /home/se/.codex/notes.md
        """
    }

    @Test("Remote panes are matched to the agents running inside them")
    func parsePlacesAgentsInPanes() {
        let rows = RemoteTmux.parse(sample, host: "quibus")
        let byAgent = Dictionary(grouping: rows, by: \.agentID).mapValues(\.count)
        #expect(byAgent["codex"] == 1)
        // Found only by walking up sh -> node, which is the whole point of the
        // parent walk: the agent is rarely the pane's own child.
        #expect(byAgent["claude-code"] == 1)
        #expect(rows.count == 2)
        #expect(rows.first { $0.agentID == "codex" }?.cwd == "/srv/checkout/apple")
        #expect(rows.first { $0.agentID == "claude-code" }?.coreName == "Mango")
    }

    @Test("A command that merely mentions an agent's directory is not an agent")
    func parseDoesNotClaimUnrelatedCommands() {
        // `vim /home/se/.codex/notes.md` sits in a pane of its own. Matching
        // the whole command line would have turned the editor into a session.
        let rows = RemoteTmux.parse(sample, host: "quibus")
        #expect(!rows.contains { $0.cwd == "/srv/idle" })
    }

    @Test("Remote rows are tagged, marked remote, and carry no local tmux target")
    func parseTagsRowsAndWithholdsTheLocalFocusTarget() {
        let rows = RemoteTmux.parse(sample, host: "quibus")
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(row.hostApp == RemoteTmux.tag)
            #expect(row.hostApp == "tmux-remote")
            #expect(row.isRemote)
            // The hazard this guards: `tmuxTarget` drives the *local* focus
            // path, so a remote pane id there would make a click act on
            // whatever shares that id on this Mac.
            #expect(row.tmuxTarget == nil)
            #expect(row.id.hasPrefix("tmux-remote:quibus:"))
            #expect(row.note?.contains("quibus") == true)
        }
    }

    @Test("Row ids are stable across scans so the list does not churn")
    func parseProducesStableIdentity() {
        let first = RemoteTmux.parse(sample, host: "quibus").map(\.id).sorted()
        let again = RemoteTmux.parse(sample, host: "quibus").map(\.id).sorted()
        #expect(first == again)
        #expect(Set(first).count == first.count)
    }

    @Test("One pane yields one row even when the agent has forked")
    func parseKeepsOnePaneToOneRow() {
        let forked = """
            910\tquibus-1:@1.%1\t/srv/checkout/apple
            \(RemoteTmux.psSeparator)
            910 1 bash -bash
            911 910 codex /home/se/.codex/packages/standalone/releases/1.2.3/bin/codex
            912 911 codex /home/se/.codex/packages/standalone/releases/1.2.3/bin/codex
            """
        #expect(RemoteTmux.parse(forked, host: "quibus").count == 1)
    }

    @Test("Output that is not the expected two halves yields nothing")
    func parseRejectsUnusableOutput() {
        // A host that answered with an error, or where tmux was not running,
        // must produce no rows rather than half-read ones.
        #expect(RemoteTmux.parse("", host: "quibus").isEmpty)
        #expect(RemoteTmux.parse("ssh: connect to host quibus port 22: refused",
                                 host: "quibus").isEmpty)
        #expect(RemoteTmux.parse(RemoteTmux.psSeparator + "\n910 1 bash -bash", host: "q").isEmpty)
    }

    @Test("A ps line becomes a process observation the shared matcher can read")
    func processLineParsing() {
        let info = RemoteTmux.process(from: "922 921 node node /usr/lib/cli.js --serve")
        #expect(info?.pid == 922)
        #expect(info?.ppid == 921)
        #expect(info?.name == "node")
        // Two arguments, so an interpreter-hosted agent is still identifiable,
        // but the trailing flags cannot drag in a false match.
        #expect(info?.argv0 == "node /usr/lib/cli.js")
        #expect(RemoteTmux.process(from: "") == nil)
        #expect(RemoteTmux.process(from: "not a process line") == nil)
    }

    @Test("The remote command asks for every table in one round trip")
    func remoteCommandIsASingleRoundTrip() {
        // Several SSH connections per host per scan would multiply the cost of
        // the slowest thing the dashboard does.
        let command = RemoteTmux.remoteCommand
        #expect(command.contains("tmux list-panes -a"))
        #expect(command.contains("ps -eo"))
        #expect(command.contains("/proc/"))
    }

    @Test("The section markers never appear whole in the command that prints them")
    func markersAreNotSelfMatching() {
        // `ps` reports our own ssh command among the processes, so a marker
        // written plainly comes back inside the output it is meant to split.
        // It must be assembled by the remote shell instead.
        #expect(!RemoteTmux.remoteCommand.contains(RemoteTmux.psSeparator))
        #expect(!RemoteTmux.remoteCommand.contains(RemoteTmux.exeSeparator))
    }

    @Test("A marker echoed back inside ps output does not truncate the section")
    func parseSplitsOnTheFirstMarkerOnly() {
        // The exact shape that made a real scan return nothing: a process
        // whose command line contains the marker, listed after the real one.
        let output = """
            910\tquibus-1:@1.%1\t/srv/checkout/apple
            \(RemoteTmux.psSeparator)
            910 1 bash -bash
            999 1 sh sh -c echo \(RemoteTmux.psSeparator)
            911 910 codex /home/se/.codex/packages/standalone/releases/1.2.3/bin/codex
            """
        let rows = RemoteTmux.parse(output, host: "quibus")
        // The agent is listed *after* the stray marker, so a split on the last
        // or on every occurrence loses it.
        #expect(rows.count == 1)
        #expect(rows.first?.agentID == "codex")
    }

    @Test("An agent identified only by its executable path is found via /proc")
    func parseUsesExecutablePathsWhenTheFarSideProvidesThem() {
        // Claude Code declares no process name — its binary is called
        // "2.1.241" and only the directory above it identifies the harness.
        // `ps` cannot show that, so without the /proc section a remote Claude
        // Code session is invisible.
        let output = """
            910\tquibus-1:@1.%1\t/srv/checkout/apple
            \(RemoteTmux.psSeparator)
            910 1 bash -bash
            911 910 claude claude --dangerously-skip-permissions
            \(RemoteTmux.exeSeparator)
            911 /home/se/.local/share/claude/versions/2.1.241
            """
        let rows = RemoteTmux.parse(output, host: "quibus")
        #expect(rows.count == 1)
        #expect(rows.first?.agentID == "claude-code")
    }

    @Test("A host with no /proc still resolves the agents ps can identify")
    func parseWorksWithoutAnExecutableSection() {
        // BSD and macOS hosts print nothing for the /proc loop. Anything a
        // harness names outright is still found.
        let output = """
            910\tquibus-1:@1.%1\t/srv/checkout/apple
            \(RemoteTmux.psSeparator)
            910 1 bash -bash
            911 910 codex /home/se/.codex/packages/standalone/releases/1.2.3/bin/codex
            \(RemoteTmux.exeSeparator)
            """
        #expect(RemoteTmux.parse(output, host: "quibus").first?.agentID == "codex")
    }

    // Deliberately no test writes `remoteTmuxHosts` or `includeRemoteTmux`.
    // `Config` is a single file at a fixed path with no injectable location,
    // so a round-trip test of those settings edits the running user's real
    // configuration — which it did, once, before this note existed. The
    // defaults they would assert are a plain `?? []` and `?? false` in
    // Settings; the behaviour worth testing is the parsing above.

    @Test("A host that ssh would parse as an option is refused")
    func hostsCannotSmuggleSshOptions() {
        // Verified against the real ssh: passing "-oProxyCommand=/usr/bin/touch …"
        // as the destination ran that command on the local machine. The host
        // list is a hand-editable JSON file, so this is reachable without the
        // UI, and the scan repeats it every 30 seconds.
        #expect(!RemoteTmux.isSafeHost("-oProxyCommand=/usr/bin/touch /tmp/pwned"))
        #expect(!RemoteTmux.isSafeHost("-F/tmp/evil_config"))
        #expect(!RemoteTmux.isSafeHost(""))
        #expect(!RemoteTmux.isSafeHost("   "))
        #expect(!RemoteTmux.isSafeHost("host with spaces"))
        #expect(!RemoteTmux.isSafeHost("host;touch /tmp/pwned"))
        #expect(!RemoteTmux.isSafeHost("host`id`"))
        #expect(!RemoteTmux.isSafeHost("host$(id)"))
        #expect(!RemoteTmux.isSafeHost("host|id"))

        // The destinations people actually use still pass.
        #expect(RemoteTmux.isSafeHost("quibus"))
        #expect(RemoteTmux.isSafeHost("10.0.0.4"))
        #expect(RemoteTmux.isSafeHost("deploy@quibus"))
        #expect(RemoteTmux.isSafeHost("build-box.internal.example.com"))
        #expect(RemoteTmux.isSafeHost("2001:db8::1"))
    }

    @Test("A refused host is reported, not silently skipped")
    func unsafeHostGivesAReason() {
        let result = RemoteTmux.scan(host: "-oProxyCommand=/usr/bin/touch /tmp/pwned")
        #expect(result.rows.isEmpty)
        #expect(result.issue == "not a usable ssh destination")
    }

    @Test("The ssh argument list ends option parsing before the destination")
    func sshArgumentsStopOptionParsing() {
        // Belt and braces alongside isSafeHost: "--" makes ssh treat whatever
        // follows as the destination even if it begins with a dash.
        #expect(RemoteTmux.sshArguments(host: "quibus").contains("--"))
        let args = RemoteTmux.sshArguments(host: "quibus")
        let dashDash = args.firstIndex(of: "--")
        let hostAt = args.firstIndex(of: "quibus")
        #expect(dashDash != nil && hostAt != nil && dashDash! < hostAt!)
        // Unknown host keys must not be auto-accepted: that is trust-on-first-use,
        // and the onboarding step is to run ssh once by hand precisely so the
        // key is verified by a human.
        #expect(!args.contains { $0.contains("StrictHostKeyChecking") })
    }

    @Test("A tmux session name cannot reach the shell that Terminal starts")
    func attachScriptQuotesTheSessionName() {
        // tmux accepts a session name of "$(touch /tmp/x)" — verified against
        // the real tmux. The old escaping handled AppleScript only, leaving
        // the name inside double quotes in the shell, where it would run.
        let hostile = Focus.attachScript(session: "$(touch /tmp/pwned)")
        #expect(hostile.contains("'$(touch /tmp/pwned)'"))
        #expect(!hostile.contains("\"$(touch /tmp/pwned)\""))

        // Backticks are the same hazard by another spelling.
        #expect(Focus.attachScript(session: "`id`").contains("'`id`'"))

        // A quote in the name must not break out of the single-quoted string.
        // Raw literal: the value carries a backslash of its own, because the
        // shell quoting runs first and AppleScript escaping then doubles it.
        let quoted = Focus.attachScript(session: "it's")
        #expect(quoted.contains(#"'it'\\''s'"#))

        // Ordinary names still come out usable.
        #expect(Focus.attachScript(session: "unruly-6").contains("'unruly-6'"))
    }

    @Test("A host that answered unreadably is not called unreachable")
    func truncatedOutputIsItsOwnFailure() {
        // Shell keeps the tail when output exceeds its cap, and the marker and
        // pane table are at the head — so a very large host could answer fully
        // and still parse to nothing. Reporting that as "could not be reached"
        // would send someone to check the network instead of the output size.
        func result(stdout: String, timedOut: Bool = false,
                    launchError: String? = nil) -> Shell.Result {
            Shell.Result(stdout: stdout, stderr: "", exitCode: 0,
                         timedOut: timedOut, launchError: launchError)
        }
        #expect(RemoteTmux.truncation(result(stdout: "…tail of a huge ps dump…")) != nil)
        // Nothing came back at all: that is unreachable, not unreadable.
        #expect(RemoteTmux.truncation(result(stdout: "")) == nil)
        // The marker is present, so the output is usable — not a failure.
        #expect(RemoteTmux.truncation(result(stdout: RemoteTmux.psSeparator + "\n")) == nil)
        // A timeout and a launch failure already have their own reasons.
        #expect(RemoteTmux.truncation(result(stdout: "x", timedOut: true)) == nil)
        #expect(RemoteTmux.truncation(result(stdout: "x", launchError: "no ssh")) == nil)
    }

    @Test("The failure reason is the line naming the failure, not ssh's chatter")
    func sshReasonPicksTheActualFailure() {
        // ssh writes CRLF when the far side has a tty. Splitting on "\n" alone
        // left the whole of stderr as one line, so a host-key warning was
        // reported as the reason a password was rejected.
        let crlf = "Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.\r\n"
            + "Permission denied, please try again.\r\n"
        #expect(RemoteTmux.sshReason(crlf) == "Permission denied, please try again.")

        #expect(RemoteTmux.sshReason("ssh: Could not resolve hostname nope: nodename nor servname provided")
                == "Could not resolve hostname nope: nodename nor servname provided")
        #expect(RemoteTmux.sshReason("ssh: connect to host x port 22: Connection refused")?
            .contains("Connection refused") == true)
        // Nothing recognisable is not a reason; the caller has a better default.
        #expect(RemoteTmux.sshReason("") == nil)
        #expect(RemoteTmux.sshReason("some unrelated chatter") == nil)
        // A warning on its own is never the reason.
        #expect(RemoteTmux.sshReason("Warning: Permanently added 'h' to the list of known hosts.\r\n") == nil)
    }

    @Test("Shell can pass input on stdin without it reaching the argument list")
    func shellFeedsStdinWithoutExposingIt() {
        // This is the mechanism that keeps a Keychain password out of the
        // process table. Untested, the password-storing path rests on an
        // assumption about how Process wires up standardInput.
        let echoed = Shell.execute("/bin/cat", [], timeout: 10, input: "secret-value\n")
        #expect(echoed.succeeded)
        #expect(echoed.stdout == "secret-value\n")

        // Two lines, which is what `security -w` consumes: value then retype.
        let twice = Shell.execute("/bin/cat", [], timeout: 10, input: "a\na\n")
        #expect(twice.stdout == "a\na\n")

        // Without input the command still runs and simply reads nothing.
        #expect(Shell.execute("/bin/echo", ["plain"], timeout: 10).stdout == "plain\n")
    }

    @Test("Gauge badges shorten only when they have to")
    func gaugeBadgeDerivation() {
        // One rule, previously duplicated in two providers.
        #expect(Gauge.badge(from: "auto") == "AUTO")
        #expect(Gauge.badge(from: "chat") == "CHAT")
        #expect(Gauge.badge(from: "completions") == "COM")
        #expect(Gauge.badge(from: "gpt-4") == "GPT")
        #expect(Gauge.badge(from: "") == "")
    }

    // MARK: - Several machines at once

    private func remoteRow(_ host: String, _ project: String) -> AgentRow {
        var value = AgentRow(id: "tmux-remote:\(host):s:@1.%1", agentID: "codex",
                             name: "s", cwd: "/srv/\(project)", state: .waiting)
        value.isRemote = true
        value.hostApp = RemoteTmux.tag
        return value
    }

    @MainActor
    @Test("One failing machine does not erase another machine's agents")
    func aFailingHostDoesNotEraseAHealthyOne() {
        // The bug this rule replaces: results were pooled into one array, so
        // the store could only keep or replace the whole sweep. With two
        // hosts that is always wrong one way or the other.
        let current = ["alpha": [remoteRow("alpha", "one")],
                       "beta": [remoteRow("beta", "two")]]
        let sweep = [
            RemoteTmux.HostResult(host: "alpha", rows: [remoteRow("alpha", "one-updated")]),
            RemoteTmux.HostResult(host: "beta", rows: [], issue: "could not be reached"),
        ]
        let out = AgentStore.applyRemote(results: sweep, to: current, issues: [:],
                                         configured: ["alpha", "beta"])
        #expect(out.rows["alpha"]?.first?.cwd == "/srv/one-updated")
        // beta failed, so it keeps what it last showed rather than vanishing.
        #expect(out.rows["beta"]?.first?.cwd == "/srv/two")
        #expect(out.issues["beta"] == "could not be reached")
        #expect(out.issues["alpha"] == nil)
    }

    @MainActor
    @Test("A machine that answered with no agents is believed")
    func anEmptyAnswerIsAuthoritative() {
        // Distinct from a failure: the agents there really did end. Keeping
        // them would show finished sessions as live for as long as the host
        // stayed reachable and idle.
        let current = ["alpha": [remoteRow("alpha", "one")]]
        let sweep = [RemoteTmux.HostResult(host: "alpha", rows: [])]
        let out = AgentStore.applyRemote(results: sweep, to: current, issues: [:],
                                         configured: ["alpha"])
        #expect(out.rows["alpha"]?.isEmpty == true)
        #expect(out.issues["alpha"] == nil)
    }

    @MainActor
    @Test("Every machine failing does not freeze all of them forever")
    func allHostsFailingKeepsEachOnesLastKnownRows() {
        let current = ["alpha": [remoteRow("alpha", "one")],
                       "beta": [remoteRow("beta", "two")]]
        let sweep = [
            RemoteTmux.HostResult(host: "alpha", rows: [], issue: "timed out after 20s"),
            RemoteTmux.HostResult(host: "beta", rows: [], issue: "could not be reached"),
        ]
        let out = AgentStore.applyRemote(results: sweep, to: current, issues: [:],
                                         configured: ["alpha", "beta"])
        #expect(out.rows.count == 2)
        // Each is stale for its own stated reason, rather than the whole set
        // being frozen because the sweep as a whole came back empty.
        #expect(out.issues["alpha"] == "timed out after 20s")
        #expect(out.issues["beta"] == "could not be reached")
    }

    @MainActor
    @Test("A machine removed from settings leaves nothing behind")
    func removingAHostDropsItsRows() {
        let current = ["alpha": [remoteRow("alpha", "one")],
                       "beta": [remoteRow("beta", "two")]]
        let out = AgentStore.applyRemote(results: [], to: current,
                                         issues: ["beta": "could not be reached"],
                                         configured: ["alpha"])
        #expect(out.rows.keys.sorted() == ["alpha"])
        #expect(out.issues["beta"] == nil)
    }

    @Test("The same machine listed twice is asked once")
    func duplicateHostsAreCollapsed() {
        // Two identical entries would produce two rows per pane, deduplicated
        // downstream under a renamed id — which reads as a second machine
        // that never has anything running on it.
        let results = RemoteTmux.scanAll(hosts: ["-bad", "-bad"])
        #expect(results.count == 1)
        #expect(results.first?.answered == false)
    }

    @Test("Each machine is reported on its own terms")
    func scanAllReportsPerHost() {
        let results = RemoteTmux.scanAll(hosts: ["-oProxyCommand=x", "host with spaces"])
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.answered })
        #expect(results.map(\.host) == ["-oProxyCommand=x", "host with spaces"])
        // Order follows configuration, not completion.
        #expect(results.allSatisfy { $0.issue == "not a usable ssh destination" })
    }

    @Test("The onboarding help states the one prerequisite and the sshpass case")
    func helpExplainsOnboarding() {
        let help = SettingsView.remoteHelp
        #expect(help.contains("ssh"))
        #expect(help.contains("~/.ssh/config"))
        #expect(help.contains("sshpass"))
        #expect(help.contains("Keychain"))
        #expect(help.contains(RemoteTmux.tag))
    }
}
