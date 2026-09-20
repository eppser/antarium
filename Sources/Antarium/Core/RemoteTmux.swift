import Foundation

/// Agents running under tmux on another machine, reached over SSH.
///
/// The design goal is that adding a machine costs one line: a hostname. SSH
/// already knows how to reach it — `~/.ssh/config`, the agent, the key — and
/// duplicating any of that here would be a second place to get it wrong. So a
/// host is stored as the string you would type after `ssh`, nothing more, and
/// key authentication needs no further configuration at all. A password is the
/// exception, and it lives in the Keychain rather than the config file.
///
/// Rows are tagged `tmux-remote` in `hostApp`, which is what tells them apart
/// from local tmux rows everywhere else in the app — the dashboard, sorting by
/// App, and the focus path that must not try to drive a local tmux server with
/// a remote pane id.
enum RemoteTmux {

    /// What `hostApp` is set to. Local tmux rows say "tmux"; these say this.
    static let tag = "tmux-remote"

    /// Where a host's password lives when it has one. Keys need no entry.
    static let keychainService = "Antarium tmux-remote"

    /// Separate the three sections of the one remote command we run per host.
    ///
    /// Split in the command text — `"__ANTARIUM""_PS__"` — so the marker is
    /// assembled by the remote shell and printed whole, but never appears
    /// whole in the command line itself. It has to: `ps` reports our own ssh
    /// command among the processes, so a marker written plainly would come
    /// back inside the very output it is supposed to delimit, and the section
    /// would be cut at the wrong place. This cost a scan that found nothing.
    static let psSeparator = "__ANTARIUM_PS__"
    static let exeSeparator = "__ANTARIUM_EXE__"
    static let statusSeparator = "__ANTARIUM_STATUS__"
    static let completionMarker = "__ANTARIUM_DONE__"

    // MARK: - Credentials

    /// The password stored for `host`, if the user set one. Absent means key
    /// authentication, which is the normal case and needs nothing from us.
    private static func password(for host: String, cancellation: @Sendable () -> Bool = { false }) -> String? {
        let out = Shell.execute("/usr/bin/security",
                                ["find-generic-password", "-s", keychainService,
                                 "-a", host, "-w"],
                                timeout: 10,outputLimit:4_096,cancellation:cancellation)
        guard out.completeOutput else { return nil }
        let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func setPassword(_ password: String, for host: String) -> Bool {
        // `-w` with no value makes `security` read the password from stdin —
        // twice, because it asks for a confirmation. That is the point: passed
        // as an argument instead, the password would sit in this machine's
        // process table for the lifetime of the command, which is exactly what
        // `sshpass -e` is used to avoid a few lines further down. It is not
        // worth being careful in one place and careless in the other.
        //
        // -U updates in place, so re-entering a password does not pile up
        // duplicate Keychain items that `find` would then pick between.
        let stored = Shell.execute("/usr/bin/security",
                                   ["add-generic-password", "-U", "-s", keychainService,
                                    "-a", host, "-w"],
                                   timeout: 10,
                                   input: "\(password)\n\(password)\n").succeeded
        forgetPresence(host)
        return stored
    }

    @discardableResult
    static func removePassword(for host: String) -> Bool {
        let removed = Shell.execute(
            "/usr/bin/security",
            ["delete-generic-password", "-s", keychainService, "-a", host],
            timeout: 10).succeeded
        forgetPresence(host)
        return removed
    }

    nonisolated(unsafe) private static var passwordPresence: [String: Bool] = [:]
    private static let presenceLock = NSLock()

    /// Whether a password is stored for `host`, remembered between calls.
    ///
    /// The settings panel asks this while drawing each host's row, to label it
    /// `key` or `password`. SwiftUI rebuilds a body whenever it likes, and the
    /// uncached answer forks `/usr/bin/security` every time — once per host per
    /// render, on the main thread. Only the presence is cached; the password
    /// itself is still read fresh at the moment it is used.
    static func hasPassword(for host: String) -> Bool {
        presenceLock.lock()
        if let hit = passwordPresence[host] { presenceLock.unlock(); return hit }
        presenceLock.unlock()
        let found = password(for: host) != nil
        presenceLock.lock(); passwordPresence[host] = found; presenceLock.unlock()
        return found
    }

    private static func forgetPresence(_ host: String) {
        presenceLock.lock(); passwordPresence[host] = nil; presenceLock.unlock()
    }

    /// `sshpass` is only needed for password hosts. Reporting its absence as a
    /// note on the host beats a scan that silently returns nothing.
    static func sshpassPath() -> String? {
        for path in ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass", "/usr/bin/sshpass"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Whether a configured host can be handed to `ssh` as a destination.
    ///
    /// `ssh` takes options and the destination from the same argument list, so
    /// a "host" beginning with `-` is parsed as an option — and
    /// `-oProxyCommand=…` runs an arbitrary command *on this Mac*, every scan.
    /// The host list is a hand-editable JSON file that Config's own
    /// documentation invites copying between machines, so this is reachable
    /// without ever touching the UI. Verified: the injected command ran.
    ///
    /// The `--` in the argument list stops the same thing a second way; a
    /// rejected host also gets a reason instead of a confusing ssh error.
    static func isSafeHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024, !trimmed.hasPrefix("-"),
              trimmed.rangeOfCharacter(from:.controlCharacters) == nil else { return false }
        // A destination is user@host, an address, or an ssh_config alias.
        // None of them contain whitespace or a shell metacharacter.
        return !trimmed.contains(where: { $0.isWhitespace })
            && trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "$`\\\"';&|<>()")) == nil
    }

    // MARK: - Scanning

    /// What one host produced, so a failure can be shown as a failure instead
    /// of as an empty list that looks like "no agents running".
    struct Result: Sendable {
        var rows: [AgentRow] = []
        /// Why this host contributed nothing, when that is knowable.
        var issue: String?
    }

    /// The command run on the far side. One round trip: tmux's pane table and
    /// the process table, which is everything needed to place an agent in a
    /// pane. `ps` is asked for argv as well as comm because an agent running
    /// under an interpreter is only identifiable from argv[0].
    static var remoteCommand: String {
        #"""
        command -v tmux >/dev/null 2>&1
        antarium_tmux_available=$?
        tmux list-panes -a -F '#{pane_pid}	#{session_name}:#{window_id}.#{pane_id}	#{pane_current_path}' 2>/dev/null
        antarium_pane_status=$?
        echo "__ANTARIUM""_PS__"
        ps -eo pid=,ppid=,comm=,args= 2>/dev/null
        antarium_ps_status=$?
        echo "__ANTARIUM""_EXE__"
        for d in /proc/[0-9]*; do
          e=$(readlink "$d/exe" 2>/dev/null)
          [ -n "$e" ] && echo "${d##*/} $e"
        done 2>/dev/null
        printf '\n__ANTARIUM''_STATUS__:%s:%s:%s\n' "$antarium_tmux_available" "$antarium_pane_status" "$antarium_ps_status"
        echo "__ANTARIUM""_DONE__"
        """#
    }

    /// One host's outcome, kept separate from every other host's.
    ///
    /// The whole sweep used to be flattened into a single `[AgentRow]`, which
    /// threw away which machine produced what. That is fine with one host and
    /// wrong with two: the caller could only apply one retention rule to the
    /// pooled result, so a single failing machine either erased the rows of
    /// the healthy ones or froze theirs alongside its own.
    struct HostResult: Sendable {
        let host: String
        var rows: [AgentRow] = []
        /// `nil` means the host answered. An answer of zero agents is a fact
        /// about that machine, not a failure, and the two must not be merged.
        var issue: String?

        var answered: Bool { issue == nil }
    }

    /// A bounded pass, with an explicit deferred state for unvisited machines.
    /// The live store uses scanSweep's nextIndex to rotate subsequent passes.
    static func scanAll(hosts:[String] = Settings.remoteTmuxHosts) -> [HostResult] {
        scanSweep(hosts:hosts).results
    }

    /// Flattened rows, for callers that do not care which machine each came
    /// from. Retention decisions must use `scanAll` instead.
    static func scan(hosts: [String] = Settings.remoteTmuxHosts) -> [AgentRow] {
        scanAll(hosts: hosts).flatMap(\.rows)
    }

    static func scan(host: String, cancellation: @Sendable () -> Bool = { false }) -> Result {
        guard !cancellation() else { return Result(issue:"Discovery cancelled.") }
        guard isSafeHost(host) else {
            return Result(issue: "not a usable ssh destination")
        }
        let attempt = run(host: host,cancellation:cancellation)
        guard let output = attempt.output else {
            return Result(issue: attempt.issue ?? "could not be reached")
        }
        guard !cancellation() else { return Result(issue:"Discovery cancelled.") }
        return Result(rows: parse(output, host: host))
    }

    /// The ssh invocation, as a value so the option ordering is testable.
    static func sshArguments(host: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", host, remoteCommand]
    }

    /// Key authentication first, always: `BatchMode=yes` makes ssh fail rather
    /// than block on a prompt, which is the difference between a scan that
    /// reports a problem and one that hangs the dashboard. Only if that fails
    /// and a password was stored do we spend the second attempt.
    private static func run(host: String, cancellation: @Sendable () -> Bool) -> (output: String?, issue: String?) {
        let keyed = Shell.execute("/usr/bin/ssh", sshArguments(host: host),
                                  timeout: 20, outputLimit: outputLimit,cancellation:cancellation)
        if usable(keyed) { return (keyed.stdout, nil) }
        if keyed.cancelled || cancellation() { return (nil,"Discovery cancelled.") }
        if keyed.timedOut { return (nil, "timed out after 20s") }
        if let replyIssue = discoveryReplyIssue(keyed) { return (nil,replyIssue) }
        guard shouldRetryWithPassword(keyed) else {
            return (nil,sshReason(keyed.stderr) ?? "SSH discovery failed before a complete reply was received.")
        }

        guard let password = password(for: host,cancellation:cancellation), !cancellation() else {
            Log.info(tag, "SSH key authentication unavailable; no stored password.")
            // The stderr line ssh printed is the actual reason — a refused
            // key, an unknown host, a closed port. Saying only "could not be
            // reached" for all of them sends people to the wrong fix.
            return (nil, sshReason(keyed.stderr) ?? "could not be reached")
        }
        guard let sshpass = sshpassPath() else {
            Log.info(tag, "SSH password authentication requires sshpass.")
            return (nil, "needs sshpass for password auth — brew install sshpass")
        }
        // -e reads the password from the environment. Passing it as an argument
        // would put it in this machine's process table for anyone to read.
        let out = Shell.execute(sshpass,
                                ["-e", "/usr/bin/ssh",
                                 "-o", "ConnectTimeout=5",
                                 "--", host, remoteCommand],
                                timeout: 20,
                                outputLimit: outputLimit,
                                environment: ["SSHPASS": password],cancellation:cancellation)
        guard usable(out) else {
            Log.info(tag, "SSH password authentication failed.")
            return (nil, discoveryReplyIssue(out) ?? sshReason(out.stderr) ?? "password was not accepted")
        }
        return (out.stdout, nil)
    }

    /// Used only by explicitly enabled trace observation. The bundled helper
    /// and request are separate values; request data travels on stdin. Existing
    /// host-key policy is preserved, and no interactive prompts are permitted.
    static func executeReadOnly(host: String, command: String, input: String,
                                cancellation: @Sendable () -> Bool) -> Shell.Result {
        guard isSafeHost(host), input.utf8.count <= 32_768 else {
            return .init(stdout: "", stderr: "", exitCode: nil, timedOut: false,
                         launchError: "Invalid remote observation request.")
        }
        let options = ["-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1",
                       "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=1"]
        let keyed = Shell.execute("/usr/bin/ssh", ["-o", "BatchMode=yes"] + options + ["--", host, command],
                                  timeout: 8, outputLimit: 131_072, input: input, cancellation: cancellation)
        guard shouldRetryWithPassword(keyed),
              let password = password(for: host,cancellation:cancellation), let sshpass = sshpassPath(), !cancellation() else { return keyed }
        var result = Shell.execute(sshpass, ["-e", "/usr/bin/ssh"] + options + ["--", host, command],
                                   timeout: 8, outputLimit: 131_072, environment: ["SSHPASS":password],
                                   input: input, cancellation: cancellation)
        if let first = keyed.childCPUSeconds, let second = result.childCPUSeconds { result.childCPUSeconds = first + second }
        else { result.childCPUSeconds = nil }
        return result
    }

    /// Translate recognized diagnostics into fixed messages. Hostnames, account
    /// names, paths, banners and arbitrary remote stderr never become log text.
    static func sshReason(_ stderr: String) -> String? {
        let lines = String(stderr.suffix(8_192)).split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            let lower = line.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            guard !lower.hasPrefix("warning:") else { continue }
            if lower.contains("permission denied") { return "Permission denied, please try again." }
            if lower.contains("too many authentication failures") { return "SSH authentication failed after too many key attempts." }
            if lower.contains("could not resolve") { return "Could not resolve the configured host." }
            if lower.contains("connection refused") { return "Connection refused by the configured host." }
            if lower.contains("connection timed out") || lower.contains("connection timeout") { return "Connection timed out." }
            if lower.contains("no route to host") { return "No route to the configured host." }
            if lower.contains("host key") { return "Host key verification failed. Verify this host in your SSH client." }
        }
        return nil
    }

    /// Four simultaneous readers retain at most 32 MiB of stdout. A clipped
    /// reply is an explicit failure even if its suffix contains valid markers.
    static let outputLimit = 8 * 1_024 * 1_024

    static func truncation(_ result:Shell.Result) -> String? {
        guard result.launchError == nil, !result.timedOut, !result.cancelled else { return nil }
        if result.stdoutTruncated { return "Reply exceeded the output limit; no agent state was updated." }
        guard !result.stdout.isEmpty, !result.stdout.contains(psSeparator) else { return nil }
        return "Replied, but the output was not readable (\(result.stdout.utf8.count) bytes, no marker)."
    }

    private static func replyStatus(_ text:String) -> (available:Int,panes:Int,processes:Int)? {
        let end = String(text.suffix(256)).split(whereSeparator:\.isNewline).suffix(2)
        guard end.count == 2, end.last == Substring(completionMarker), let line = end.first else { return nil }
        let fields = line.split(separator:":")
        guard fields.count == 4, fields[0] == Substring(statusSeparator),
              let available = Int(fields[1]),let panes = Int(fields[2]),let processes = Int(fields[3]),
              [available,panes,processes].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return (available,panes,processes)
    }
    static func usable(_ result:Shell.Result) -> Bool {
        guard result.completeOutput,
              result.stdout.contains(psSeparator), let status = replyStatus(result.stdout) else { return false }
        return status.available == 0 && status.panes == 0 && status.processes == 0
    }
    static func discoveryReplyIssue(_ result:Shell.Result) -> String? {
        if let issue = truncation(result) { return issue }
        if let status = replyStatus(result.stdout) {
            if status.available != 0 { return "tmux is not available on this host." }
            if status.panes != 0 { return "No tmux pane inventory was available. The server may be stopped or inaccessible." }
            if status.processes != 0 { return "The remote process inventory failed. Existing observations were retained." }
        } else if result.stdout.contains(psSeparator) {
            return "The remote discovery reply was incomplete. Existing observations were retained."
        }
        return nil
    }
    static func shouldRetryWithPassword(_ result:Shell.Result) -> Bool {
        guard result.exitCode == 255, !result.cancelled, !result.timedOut,
              result.launchError == nil, !result.stdoutTruncated, !result.stderrTruncated else { return false }
        let text = String(result.stderr.suffix(8_192)).lowercased()
        guard !text.contains("host key"), !text.contains("connection refused"),
              !text.contains("could not resolve"), !result.stdout.contains(psSeparator) else { return false }
        return text.contains("permission denied") || text.contains("too many authentication failures")
    }

    // MARK: - Parsing

    /// Splits on the *first* marker only. A later one is our own ssh command
    /// line coming back through `ps`, not a new section.
    private static func section(_ text: String, upTo marker: String) -> (String, String) {
        guard let range = text.range(of: marker) else { return (text, "") }
        return (String(text[text.startIndex..<range.lowerBound]),
                String(text[range.upperBound...]))
    }

    /// Pure, so the whole placement rule is testable without a network.
    /// The most rows one host may contribute.
    ///
    /// The reply is capped at eight megabytes and a truncated one updates
    /// nothing, so the transfer is bounded. What is built from a whole reply
    /// was not: eight megabytes of pane lines is tens of thousands of rows,
    /// each of which becomes a dashboard row and a sort key. A machine
    /// running more than this many agent panes is reporting something other
    /// than a fleet worth watching.
    static let maxRows = 256

    static func parse(_ output: String, host: String, descriptors load: () -> [HarnessDescriptor] = HarnessDescriptor.all) -> [AgentRow] {
        let (paneText, rest) = section(output, upTo: psSeparator)
        guard !rest.isEmpty else { return [] }
        let (psText, exeText) = section(rest, upTo: exeSeparator)

        // pid -> executable path, where the far side could tell us.
        var exePaths: [Int32: String] = [:]
        for line in exeText.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard f.count == 2, let pid = Int32(f[0]) else { continue }
            exePaths[pid] = String(f[1])
        }

        // pane pid -> (target, cwd)
        var panes: [Int32: (target: String, cwd: String)] = [:]
        for line in paneText.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2, let pid = Int32(f[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            panes[pid] = (f[1], f.count > 2 ? f[2] : "")
        }
        guard !panes.isEmpty else { return [] }
        // Bound the work here rather than at the end: every later table is
        // keyed off these pids, so capping them caps all of it.
        if panes.count > maxRows {
            for pid in panes.keys.sorted().dropFirst(maxRows) { panes[pid] = nil }
        }

        var parents: [Int32: Int32] = [:]
        var processes: [Int32: Processes.Info] = [:]
        for line in psText.split(separator: "\n") {
            guard let head = process(from: String(line)) else { continue }
            let info = exePaths[head.pid].map {
                Processes.Info(pid: head.pid, ppid: head.ppid, path: $0,
                               name: head.name, argv0: head.argv0, rss: nil)
            } ?? head
            parents[info.pid] = info.ppid
            processes[info.pid] = info
        }

        guard !processes.isEmpty else { return [] }
        let descriptors = load()
        var rows: [AgentRow] = []
        var claimed = Set<String>()

        for (pid, info) in processes.sorted(by: { $0.key < $1.key }) {
            guard let descriptor = descriptors.first(where: { $0.claims(info) }) else { continue }
            // Walk up to the pane that contains it. The agent is usually the
            // pane's own child, but a shell wrapper or `npx` puts it a level or
            // two deeper — the same walk the local scan does.
            var walk = pid
            var found: (target: String, cwd: String)?
            for _ in 0..<8 {
                if let pane = panes[walk] { found = pane; break }
                guard let parent = parents[walk], parent > 1 else { break }
                walk = parent
            }
            guard let pane = found else { continue }
            // One row per pane: an agent that spawns a copy of itself is still
            // one session in one pane, and two rows would double-count it.
            guard claimed.insert(pane.target).inserted else { continue }

            var row = AgentRow(id: "\(tag):\(host):\(pane.target)",
                               agentID: descriptor.id,
                               name: Focus.tmuxSession(pane.target),
                               cwd: pane.cwd,
                               state: .unobserved)
            row.remoteObservedAt = Date()
            row.isRemote = true
            row.remoteHost = host
            row.hostApp = tag
            row.pid = pid
            // Deliberately not `tmuxTarget`: that field drives the local focus
            // path, and handing it a remote pane id would make a click act on
            // whatever happens to share that id on this Mac.
            row.note = "\(host) · \(pane.target) — status and usage are not read over SSH"
            rows.append(row)
        }
        return rows
    }

    /// `12345 6789 node /usr/lib/@anthropic-ai/claude-code/cli.js --serve`
    /// → one process observation.
    ///
    /// Built as a `Processes.Info` on purpose: it then goes through exactly the
    /// same `claims` matcher as a local process, so a harness recognised here
    /// is recognised there, and the two cannot drift apart.
    ///
    /// The searchable part is the first two arguments rather than the first.
    /// Locally, `argv[0]` alone is enough because macOS reports the script path
    /// there for an interpreter-hosted agent; `ps` on the far side does not —
    /// it reports "node", and the path that identifies the harness is the next
    /// argument along. Stopping at two keeps a command that merely *mentions*
    /// an agent's directory, like an editor opened on its config, from being
    /// claimed as the agent itself.
    static func process(from line: String) -> Processes.Info? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: " ", maxSplits: 3,
                                   omittingEmptySubsequences: true)
        guard fields.count >= 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1])
        else { return nil }
        let comm = String(fields[2])
        let args = fields.count > 3 ? String(fields[3]) : comm
        let head = args.split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2).joined(separator: " ")
        return Processes.Info(pid: pid, ppid: ppid, path: head,
                              name: comm, argv0: head, rss: nil)
    }


}
