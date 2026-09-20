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

    // MARK: - Credentials

    /// The password stored for `host`, if the user set one. Absent means key
    /// authentication, which is the normal case and needs nothing from us.
    private static func password(for host: String) -> String? {
        let out = Shell.execute("/usr/bin/security",
                                ["find-generic-password", "-s", keychainService,
                                 "-a", host, "-w"],
                                timeout: 10)
        guard out.succeeded else { return nil }
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
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        // A destination is user@host, an address, or an ssh_config alias.
        // None of them contain whitespace or a shell metacharacter.
        return !trimmed.contains(where: { $0.isWhitespace })
            && trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "$`\\\"';&|<>()")) == nil
    }

    // MARK: - Scanning

    /// What one host produced, so a failure can be shown as a failure instead
    /// of as an empty list that looks like "no agents running".
    struct Result {
        var rows: [AgentRow] = []
        /// Why this host contributed nothing, when that is knowable.
        var issue: String?
    }

    /// The command run on the far side. One round trip: tmux's pane table and
    /// the process table, which is everything needed to place an agent in a
    /// pane. `ps` is asked for argv as well as comm because an agent running
    /// under an interpreter is only identifiable from argv[0].
    static var remoteCommand: String {
        "tmux list-panes -a -F "
            + "'#{pane_pid}\t#{session_name}:#{window_id}.#{pane_id}\t#{pane_current_path}' "
            + "2>/dev/null"
            + "; echo \"__ANTARIUM\"\"_PS__\""
            + "; ps -eo pid=,ppid=,comm=,args= 2>/dev/null"
            + "; echo \"__ANTARIUM\"\"_EXE__\""
            // Executable paths, which `ps` does not give and which several
            // harnesses are identified by — Claude Code's binary is called
            // "2.1.241" and is only recognisable from the directory above it.
            // Linux only; on anything without /proc this prints nothing and
            // the comm field is used instead.
            + "; for d in /proc/[0-9]*; do e=$(readlink \"$d/exe\" 2>/dev/null);"
            + " [ -n \"$e\" ] && echo \"${d##*/} $e\"; done 2>/dev/null"
    }

    /// Results from the concurrent sweep, keyed by the host's position.
    ///
    /// A captured `var` array mutated from `concurrentPerform` is a strict
    /// concurrency warning even when a lock guards every write, because the
    /// compiler cannot see the guarantee. Same shape as `Shell.CapturedData`:
    /// the synchronisation lives inside the object, and the unchecked
    /// annotation is where that promise is recorded.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var byIndex: [Int: HostResult] = [:]

        func set(_ result: HostResult, at index: Int) {
            lock.lock(); byIndex[index] = result; lock.unlock()
        }

        func ordered(count: Int) -> [HostResult] {
            lock.lock(); defer { lock.unlock() }
            return (0..<count).compactMap { byIndex[$0] }
        }
    }

    /// One host's outcome, kept separate from every other host's.
    ///
    /// The whole sweep used to be flattened into a single `[AgentRow]`, which
    /// threw away which machine produced what. That is fine with one host and
    /// wrong with two: the caller could only apply one retention rule to the
    /// pooled result, so a single failing machine either erased the rows of
    /// the healthy ones or froze theirs alongside its own.
    struct HostResult {
        let host: String
        var rows: [AgentRow] = []
        /// `nil` means the host answered. An answer of zero agents is a fact
        /// about that machine, not a failure, and the two must not be merged.
        var issue: String?

        var answered: Bool { issue == nil }
    }

    /// Every host at once, each reported on its own terms.
    ///
    /// Serially, an unreachable machine costs its full 20-second timeout
    /// before the next one is even asked, so four dead hosts meant eighty
    /// seconds — well past the interval at which the next sweep would be due.
    /// In parallel the whole sweep costs roughly the slowest host.
    static func scanAll(hosts: [String] = Settings.remoteTmuxHosts) -> [HostResult] {
        let targets = hosts.map { $0.trimmingCharacters(in: .whitespaces) }
                           .filter { !$0.isEmpty }
        // A host listed twice would produce two identical rows per pane and
        // then be de-duplicated downstream under a renamed id, which reads as
        // a second machine that never has anything on it.
        var seen = Set<String>()
        let unique = targets.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }

        let collected = Collected()
        DispatchQueue.concurrentPerform(iterations: unique.count) { i in
            let host = unique[i]
            guard isSafeHost(host) else {
                Log.warn(tag, "\(host): rejected — not a usable ssh destination")
                collected.set(HostResult(host: host,
                                         issue: "not a usable ssh destination"), at: i)
                return
            }
            let result = scan(host: host)
            // Log the good case too. A host that is quietly contributing
            // nothing looks exactly like one that is not being asked, and the
            // onboarding help sends people here to tell those apart.
            Log.info(tag, "\(host): \(result.issue ?? "\(result.rows.count) agent(s)")")
            collected.set(HostResult(host: host, rows: result.rows, issue: result.issue), at: i)
        }
        // Order follows the configured host list, not completion order, so the
        // list does not reshuffle when one machine happens to answer first.
        return collected.ordered(count: unique.count)
    }

    /// Flattened rows, for callers that do not care which machine each came
    /// from. Retention decisions must use `scanAll` instead.
    static func scan(hosts: [String] = Settings.remoteTmuxHosts) -> [AgentRow] {
        scanAll(hosts: hosts).flatMap(\.rows)
    }

    static func scan(host: String) -> Result {
        guard isSafeHost(host) else {
            return Result(issue: "not a usable ssh destination")
        }
        let attempt = run(host: host)
        guard let output = attempt.output else {
            return Result(issue: attempt.issue ?? "could not be reached")
        }
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
    private static func run(host: String) -> (output: String?, issue: String?) {
        let keyed = Shell.execute("/usr/bin/ssh", sshArguments(host: host),
                                  timeout: 20, outputLimit: outputLimit)
        if usable(keyed) { return (keyed.stdout, nil) }
        if keyed.timedOut { return (nil, "timed out after 20s") }
        if let truncated = truncation(keyed) { return (nil, truncated) }

        guard let password = password(for: host) else {
            Log.info(tag, "\(host): key auth failed and no stored password — \(keyed.stderr.prefix(160))")
            // The stderr line ssh printed is the actual reason — a refused
            // key, an unknown host, a closed port. Saying only "could not be
            // reached" for all of them sends people to the wrong fix.
            return (nil, sshReason(keyed.stderr) ?? "could not be reached")
        }
        guard let sshpass = sshpassPath() else {
            Log.info(tag, "\(host): password stored but sshpass is not installed")
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
                                environment: ["SSHPASS": password])
        guard usable(out) else {
            Log.info(tag, "\(host): password auth failed — \(out.stderr.prefix(160))")
            return (nil, sshReason(out.stderr) ?? "password was not accepted")
        }
        return (out.stdout, nil)
    }

    /// The one line of ssh's stderr worth showing. ssh is chatty about host
    /// keys and config; the reason is the line naming the failure.
    static func sshReason(_ stderr: String) -> String? {
        // `isNewline`, not a comparison against "\n" and "\r": ssh writes CRLF
        // when it has a tty on the far side, and Swift treats "\r\n" as one
        // Character, so neither literal matches it. Without this the whole of
        // stderr stays a single "line" and a host-key warning gets reported as
        // the reason a password was rejected.
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // ssh is chatty about host keys and config on the way to the real
            // failure; a warning is never the reason.
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning:") }
        for line in lines.reversed() {
            let lower = line.lowercased()
            guard lower.contains("permission denied") || lower.contains("could not resolve")
                    || lower.contains("connection refused") || lower.contains("connection timed out")
                    || lower.contains("no route to host") || lower.contains("host key")
            else { continue }
            // Drop ssh's "host:" prefix; the caller already prints the host.
            return line.hasPrefix("ssh: ") ? String(line.dropFirst(5)) : line
        }
        return nil
    }

    /// `ps` on a large host is the bulk of the reply, and `Shell` keeps the
    /// *suffix* when output exceeds its cap — which for this command would
    /// discard the pane table and the marker at the top, the two things the
    /// parser needs. A real host with ~600 processes produced ~106KB, but a
    /// server with thousands of processes and long command lines can reach
    /// megabytes, so the cap is raised well clear of that rather than left at
    /// the default and silently mistaken for an unreachable machine.
    static let outputLimit = 32 * 1_024 * 1_024

    /// Output arrived, but not the start of it. Saying "could not be reached"
    /// here would be false: the host answered, we just could not read what it
    /// said, and those are different problems with different fixes.
    static func truncation(_ result: Shell.Result) -> String? {
        guard result.launchError == nil, !result.timedOut,
              !result.stdout.isEmpty, !result.stdout.contains(psSeparator)
        else { return nil }
        return "replied, but the output was not readable (\(result.stdout.count) bytes, no marker)"
    }

    /// Judged on the marker, not the exit status.
    ///
    /// The command is a pipeline of best-effort probes: the /proc loop fails
    /// on a BSD host, `tmux` exits non-zero with no server running. The last
    /// of those sets the status, so requiring exit 0 threw away complete,
    /// correct output — which it did, until a run against a real machine
    /// showed the scan reporting failure while holding every pane it needed.
    private static func usable(_ result: Shell.Result) -> Bool {
        result.launchError == nil && !result.timedOut
            && result.stdout.contains(psSeparator)
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
    static func parse(_ output: String, host: String) -> [AgentRow] {
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

        var parents: [Int32: Int32] = [:]
        var processes: [Int32: Processes.Info] = [:]
        for line in psText.split(separator: "\n") {
            guard let head = process(from: String(line)) else { continue }
            let info = exePaths[head.pid].map {
                Processes.Info(pid: head.pid, ppid: head.ppid, path: $0,
                               name: head.name, argv0: head.argv0, rss: 0)
            } ?? head
            parents[info.pid] = info.ppid
            processes[info.pid] = info
        }

        let descriptors = HarnessDescriptor.all()
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
                               state: .waiting)
            row.isRemote = true
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
                              name: comm, argv0: head, rss: 0)
    }


}
