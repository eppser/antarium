import Foundation
import Darwin

/// One agent session, local or cloud.
struct AgentRow: Identifiable {
    enum State {
        /// A process may be known, but its current working/idle state is not.
        case unobserved
        /// Alive but not working — finished its turn, waiting for you.
        case waiting
        /// Alive and working.
        case working
        /// Alive, sitting in a shell command.
        case shell
        /// No live process; the session is over.
        case ended
        /// Running somewhere else entirely.
        case cloud(String)
        /// Between rounds of its own loop. Not idle and not waiting on you — it
        /// carries on by itself, which is why it reads green rather than orange.
        case looping

        /// Doing something right now, as opposed to waiting on you or finished.
        var isBusy: Bool {
            switch self {
            case .working, .shell: return true
            default: return false
            }
        }

        /// Sort weight: things you can act on come first, busy agents last.
        var rank: Int {
            switch self {
            case .waiting: return 0
            case .ended:   return 1
            case .cloud, .unobserved: return 2
            case .shell:   return 3
            // Above the "wants you" threshold: a loop pausing between rounds
            // has not stopped, and announcing it every iteration would be noise.
            case .looping: return 4
            case .working: return 5
            }
        }
        var label: String {
            switch self {
            case .unobserved: return "Unknown"
            case .waiting: return "Waiting"
            case .working: return "Working"
            case .looping: return "Looping"
            case .shell:   return "Shell"
            case .ended:   return "Ended"
            case .cloud(let s): return s.isEmpty ? "Cloud" : s.capitalized
            }
        }
        var isLive: Bool {
            if case .ended = self { return false }
            return true
        }
    }

    var id: String
    let agentID: String
    /// Claude Code's own derived session name, e.g. "spicy-c1".
    var name: String
    let cwd: String
    var state: State
    var model: String?
    var startedAt: Date?
    var lastActivity: Date?
    var contextTokens: Int?
    var contextWindow: Int?
    var toolCalls: Int?
    var costUSD: Double?
    var pid: Int32?
    var rssBytes: Int64?
    var isRemote: Bool = false
    /// Bound local trace source; activity analysis never guesses by project folder.
    var traceFile: String?
    var remoteHost: String?
    var remoteObservedAt: Date?
    var remoteObservationIssue: String?
    var localObservationIssue: String?
    /// Which app it is running inside — "tmux", "Terminal", "Warp".
    var hostApp: String?
    /// Why this row is sparse, when the reason is knowable. A session that
    /// publishes nothing looks exactly like one we failed to read, and the
    /// difference matters: one is a limit, the other a bug.
    var note: String?
    /// When the agent's own scheduling call says it wakes again, and whether
    /// that loop was stopped. Only harnesses that record their scheduling set
    /// these; nothing is inferred from timing.
    var loopWakeAt: Date?
    var loopStopped = false
    /// A loop the harness states outright, with no wake time — Codex's goals.
    var loopGoal: String?

    /// Working through a loop, rather than waiting on you.
    var isLooping: Bool {
        LoopWatch.isLooping(declared: loopGoal, wakeAt: loopWakeAt, stopped: loopStopped)
    }
    /// `session:@window.%pane` when the agent runs under tmux.
    var tmuxTarget: String?
    /// What this row's harness needs to bring the session to the front, when
    /// the harness owns its own windows and publishes a command for it.
    var focusTarget: String?
    /// The agent's own id for this conversation, where it has one.
    ///
    /// `id` already folds this in, but it folds in the project and the harness
    /// too, so it cannot be compared against an id a workspace manager
    /// publishes for the same session. This can.
    var sessionID: String?
    var context = ProjectContext()
    /// Assistant turns per 10-minute bucket over the last 6 hours.
    var activity: [Int] = []
    /// Whole-session traffic, shown as plain totals.
    var sentTokens: Int?
    var receivedTokens: Int?
    /// One figure covering everything, from a harness that reports no split.
    /// Shown instead of the two above, never alongside them.
    var totalTokens: Int?
    /// This row is withholding its figures because its history has not been
    /// read yet.
    ///
    /// A fact rather than a phrase. The dashboard's summary used to count
    /// rows whose note contained "still being read", which is business logic
    /// keyed on display text: two files produce that sentence, and rewording
    /// either — or writing a different note that happens to contain it —
    /// moves the count without touching anything that looks like a counter.
    var awaitingHistory = false
    /// Sub-agents this session spawned. Distinct from tool calls — Kimi's count
    /// was previously shown under the tool icon, which read as 11 tool calls.
    var subAgents: Int?
    /// Conversation turns. Cursor records these but not tool calls, and putting
    /// them under the hammer would repeat the same mislabelling.
    var turns: Int?
    /// Claude's own session name, e.g. "spicy-c1" — kept for the tooltip.
    var sessionName: String = ""

    /// A PID binding is a recent observation, not a permanent lease on a
    /// process number. Failed, missing, future or stale observations cannot
    /// authorize another trace lookup on that remote process.
    func hasFreshRemoteObservation(at now:Date) -> Bool {
        guard isRemote, remoteHost != nil, remoteObservationIssue == nil,
              let remoteObservedAt else { return false }
        let age = now.timeIntervalSince(remoteObservedAt)
        return age.isFinite && age >= 0 && age <= 120
    }
    var remoteObservationDetail: String? {
        guard isRemote, remoteHost != nil else { return nil }
        var detail = remoteObservationIssue ?? "Process discovery does not report working or idle state."
        if let remoteObservedAt, remoteObservedAt.timeIntervalSince1970.isFinite {
            detail += " Last observed: " + remoteObservedAt.formatted(date:.abbreviated,time:.standard) + "."
        } else { detail += " No recent process observation is available." }
        return detail
    }

    /// "Spicy" — the project, not the session instance.
    var coreName: String {
        guard !cwd.isEmpty else { return name }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "Home" }
        if cwd == "/" { return "Root" }
        let base = URL(fileURLWithPath: cwd).lastPathComponent
        guard !base.isEmpty, base != "/" else { return name }
        // Preserve existing capitalisation (ZeroDayClock, ARCAGI) and only
        // lift an all-lowercase directory name.
        return base == base.lowercased() ? base.capitalized : base
    }

    /// `~/shared/spicy`
    var displayPath: String {
        guard !cwd.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (state.isLive ? Date() : (lastActivity ?? Date())).timeIntervalSince(startedAt)
    }
    var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
}

/// How the dashboard orders its list.
enum AgentSort: String, CaseIterable {
    case name, harness, host, spend, activity

    var title: String {
        switch self {
        case .name:     return "Name"
        case .harness:  return "Agent"
        case .host:     return "App"
        case .spend:    return "Spend"
        case .activity: return "Last action"
        }
    }
    var symbol: String {
        switch self {
        case .name:     return "textformat"
        case .harness:  return "square.stack.3d.up"
        case .host:     return "macwindow"
        case .spend:    return "creditcard"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

/// Discovers every coding-agent session on this Mac (and, for Codex, in the
/// cloud). Everything here is read-only: session files, transcripts, `ps`.
enum AgentScan {
    struct Observation {
        var rows: [AgentRow]
        var unavailablePIDs: Set<Int32> = []
        var unavailableHarnesses: Set<String> = []
    }

    // MARK: - Entry point

    /// Runs off the main thread; can take a moment on a machine with many
    /// large transcripts.
    static func scan() throws -> [AgentRow] { try observe().rows }

    static func observe() throws -> Observation {
        let snapshot = try Processes.capture(measureIf:isAgent)
        let processes = snapshot.table
        var rows: [AgentRow] = []
        var unavailableHarnesses = Set<String>()
        if let claude = HarnessDescriptor.all().first(where: { $0.id == "claude-code" }) {
            do { rows = try claudeRows(claude,processes:processes,unavailablePIDs:snapshot.unavailablePIDs) }
            catch is CancellationError { throw CancellationError() }
            catch { unavailableHarnesses.insert(claude.id) }
        }
        rows += descriptorRows(processes: processes)

        // Where each agent is running. One sysctl for the whole table.
        let parents = Processes.parentMap()
        let paths = processes.mapValues(\.path)
        for i in rows.indices {
            if let pid = rows[i].pid {
                rows[i].hostApp = Processes.hostApp(of: pid, parents: parents, paths: paths)
            }
        }
        attachTmuxTargets(to: &rows, parents: parents, panes: Focus.tmuxPanesByPID)
        // Workspace managers last: they say how a session is raised, and the
        // rows they apply to have to exist first.
        for descriptor in HarnessDescriptor.all() where descriptor.contributesFocusOnly {
            attachWorkspaceTargets(to: &rows, panes: HarnessEngine.sessions(descriptor))
        }
        for i in rows.indices where !rows[i].cwd.isEmpty {
            rows[i].context = ProjectContext.scan(rows[i].cwd, agentID: rows[i].agentID)
        }
        try Task.checkCancellation()
        return Observation(rows:sorted(uniqued(rows)),unavailablePIDs:snapshot.unavailablePIDs,unavailableHarnesses:unavailableHarnesses)
    }

    /// Attaches every row to one coherent tmux snapshot. The previous scan
    /// queried tmux from inside the row loop, multiplying subprocess work and
    /// allowing different rows in one result to describe different instants.
    static func attachTmuxTargets(to rows: inout [AgentRow],
                                  parents: [Int32: Int32],
                                  panes load: () -> [Int32: String]) {
        guard rows.contains(where: {
            $0.tmuxTarget == nil && $0.hostApp == "tmux"
        }) else { return }
        let panes = load()
        Log.debug("tmux", "\(panes.count) pane(s) known")
        guard !panes.isEmpty else { return }
        for i in rows.indices where rows[i].tmuxTarget == nil {
            guard var walk = rows[i].pid else { continue }
            for _ in 0..<8 {
                if let target = panes[walk] {
                    rows[i].tmuxTarget = target
                    break
                }
                guard let parent = parents[walk], parent > 1 else { break }
                walk = parent
            }
        }
    }

    /// Combines independently sampled sources without inventing duplicate
    /// observations. A local row wins an impossible cross-source id collision
    /// because it carries actionable process attachment.
    static func merge(local: [AgentRow], cloud: [AgentRow]) -> [AgentRow] {
        var seen = Set<String>()
        var result: [AgentRow] = []
        for row in local + cloud where seen.insert(row.id).inserted {
            result.append(row)
        }
        return result
    }

    /// Guarantees every row has its own identity.
    ///
    /// The list is keyed by `id`, and duplicates make SwiftUI draw one row twice
    /// and drop another. One harness getting this wrong should not be able to
    /// corrupt the whole table, so the invariant is enforced here rather than
    /// trusted from each reader.
    static func uniqued(_ rows: [AgentRow]) -> [AgentRow] {
        var seen: Set<String> = [], out: [AgentRow] = []
        for var row in rows {
            if seen.contains(row.id) {
                var suffix = 2
                var candidate = "\(row.id)#\(suffix)"
                while seen.contains(candidate) { suffix += 1; candidate = "\(row.id)#\(suffix)" }
                Log.warn("scan", "Duplicate session identity detected; display identities were disambiguated.")
                row.id = candidate
            }
            seen.insert(row.id)
            out.append(row)
        }
        return out
    }

    /// What every order falls through to once its own key has run out.
    ///
    /// Swift's sort is not stable, so an order that stops at its first key
    /// lets equal rows swap on every scan — the list reshuffles under the
    /// pointer while nothing has changed. Four of the five orders already
    /// fell through to status and recency for this reason; `.spend` did not,
    /// and a machine where most rows carry no cost — which is most machines,
    /// since only some harnesses report one — put every costless row at the
    /// same value and reordered them each time.
    ///
    /// Ends at the id, which is the only field two rows cannot share. The
    /// same project open twice matches on everything a person can see.
    private static func settles(_ a: AgentRow, _ b: AgentRow) -> Bool {
        if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
        let left = a.lastActivity ?? .distantPast, right = b.lastActivity ?? .distantPast
        if left != right { return left > right }
        return a.id < b.id
    }

    static func sorted(_ rows: [AgentRow], by order: AgentSort = Settings.agentSort) -> [AgentRow] {
        switch order {
        case .name:
            // Alphabetical by the name the row actually shows, so the list
            // reads like an index. Two rows can carry the same project name —
            // a second checkout, or one repo open under tmux and in Warp — so
            // status and recency still break the tie, which also keeps the
            // order stable between scans rather than letting equal names swap.
            return rows.sorted {
                let a = $0.coreName, b = $1.coreName
                if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
                return settles($0, $1)
            }
        case .harness:
            // Group by agent, then by the status order within each group.
            return rows.sorted {
                if $0.agentID != $1.agentID { return $0.agentID < $1.agentID }
                return settles($0, $1)
            }
        case .host:
            // Group by the app they run in — tmux together, Warp together —
            // and keep the status order inside each group. Agents with no known
            // host sort last rather than under an empty heading.
            return rows.sorted {
                let a = $0.hostApp ?? "\u{10FFFF}", b = $1.hostApp ?? "\u{10FFFF}"
                if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
                return settles($0, $1)
            }
        case .spend:
            // Rows with no cost at all are not "zero spend" — the harness
            // simply does not report one — so they keep sorting below a real
            // zero and settle among themselves rather than swapping.
            return rows.sorted {
                let a = $0.costUSD ?? -1, b = $1.costUSD ?? -1
                if a != b { return a > b }
                return settles($0, $1)
            }
        case .activity:
            // An agent that is working right now *is* the most recent action,
            // whatever its transcript says. Several harnesses only write when a
            // turn ends — PI records nothing until it answers — so sorting on
            // the file's timestamp alone put a busy agent below a dozen idle
            // ones, and one with no timestamp at all dead last.
            return rows.sorted {
                if $0.state.isBusy != $1.state.isBusy { return $0.state.isBusy }
                return settles($0, $1)
            }
        }
    }

    // MARK: - Processes

    /// Called with an executable path, a process name and argv[0] separately,
    /// so both kinds of match belong here. Without the name check an agent that
    /// runs under an interpreter reported 0MB — its path is only ever "node".
    static func isAgent(_ candidate: String) -> Bool {
        isAgent(candidate,
                fragments: HarnessDescriptor.matchFragments(),
                names: HarnessDescriptor.processNamesAll())
    }

    /// The tables are parameters so this can be checked against the harnesses
    /// the app ships rather than against whatever this Mac happens to have
    /// seeded — the difference between a test and a description of one
    /// developer's machine.
    static func isAgent(_ candidate: String, fragments: [String],
                        names: Set<String>) -> Bool {
        if fragments.contains(where: { candidate.contains($0) }) { return true }
        return names.contains((candidate as NSString).lastPathComponent)
    }

    static func liveProcesses() throws -> [Int32: Processes.Info] {
        try Processes.snapshot(measureIf: isAgent)
    }

    // MARK: - Claude Code

    /// Claude Code publishes live session state per pid, including a status of
    /// idle / busy / shell — far better than inferring activity from a transcript.
    enum RegistryError:Error { case unavailable, invalid, limit }
    private static func registryDate(_ raw:Any?) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let milliseconds = FieldPath.numeric(raw), milliseconds >= 0,
              milliseconds <= 253_402_300_799_000 else { throw RegistryError.invalid }
        return Date(timeIntervalSince1970:milliseconds / 1_000)
    }
    static func claudeRows(_ claude:HarnessDescriptor,processes: [Int32: Processes.Info], unavailablePIDs:Set<Int32> = []) throws -> [AgentRow] {
        let dir = URL(fileURLWithPath: claude.source.path.expandingTilde)
        var directoryInfo = stat()
        if lstat(dir.path,&directoryInfo) != 0 {
            if errno == ENOENT { return [] }
            throw RegistryError.unavailable
        }
        let entries = try BoundedDirectory.entries(dir).filter { $0.url.pathExtension == "json" }
        guard entries.count <= 512 else { throw RegistryError.limit }
        var rows: [AgentRow] = [], bytes = 0
        for entry in entries {
            try Task.checkCancellation()
            let file = entry.url
            // Redundant with BoundedFile.read, which checks S_IFREG on the
            // descriptor it opened and so refuses a symlink or FIFO whatever
            // the caller does — deliberately kept as the nearer of the two
            // checks, and the reason no mutation of this line can be caught.
            guard entry.isRegular else { throw RegistryError.invalid }
            let data = try BoundedFile.read(file,maxBytes:65_536)
            bytes += data.count
            guard bytes <= 8 * 1_024 * 1_024 else { throw RegistryError.limit }
            guard let d = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let cwd = d["cwd"] as? String, cwd.utf8.count <= 4_096,
                  !cwd.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else {
                throw RegistryError.invalid
            }
            let pid = d["pid"].flatMap(FieldPath.processID)
            if let raw = d["pid"], !(raw is NSNull), pid == nil { throw RegistryError.invalid }
            let process = pid.flatMap { processes[$0] }.flatMap { claude.claims($0) ? $0 : nil }
            // File modification predating the process birth cannot establish
            // that this registry entry describes the current PID owner.
            let predatesProcess = process?.startedAt.map { entry.modified < $0.addingTimeInterval(-2) } ?? false
            let alive = process != nil && !predatesProcess
            // A stale session file outlives its process; treat it as ended
            // rather than reporting a status nothing is updating any more.
            // Sessions hosted by Claude Desktop carry no status field at all;
            // taking that as "busy" left them reading Working for ever.
            // Sessions hosted by Claude Desktop publish no status at all, so
            // "no status" must not be read as "busy".
            let published: AgentStateMachine.Published? = {
                switch d["status"] as? String {
                case "idle":  return .waiting
                case "shell": return .shell
                case "busy":  return .working
                default:      return nil
                }
            }()
            // Loop state comes from the transcript, read further down, so the
            // first pass cannot know it. Resolved again once it is known.
            let state = AgentStateMachine.state(
                .init(processAlive: alive, published: published))

            let sessionID = d["sessionId"] as? String ?? file.deletingPathExtension().lastPathComponent
            let sessionName = d["name"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent
            var row = AgentRow(
                // The pid, not just the session id: Claude reuses a session id
                // across resumed sessions, so two live agents in different
                // projects can share one. Two rows with the same identity made
                // the list render one of them twice.
                id: AgentIdentity.local(harness: "claude-code",
                                        sessionID: sessionID, cwd: cwd, pid: pid),
                agentID: "claude-code",
                name: sessionName,
                cwd: cwd,
                state: state,
                startedAt: try registryDate(d["startedAt"]),
                lastActivity: try registryDate(d["updatedAt"]),
                pid: alive ? pid : nil,
                rssBytes: process?.rss,
                tmuxTarget: d["tmux"] as? String,
                sessionName: sessionName)

            let entrypoint = d["entrypoint"] as? String ?? "cli"
            let transcript = transcriptURL(cwd: cwd, sessionID: sessionID,
                                           root: claude.source.paths?["transcripts"])
            if transcript == nil {
                // An SDK- or ACP-launched session registers itself and then
                // writes nothing more: no transcript, no status, and its
                // registry entry is never touched again. There is no model,
                // cost or activity to find — so say that, rather than leaving a
                // blank row that reads as a failure to look.
                row.note = "Started by \(entrypoint) — this session publishes no transcript "
                    + "or status, so its model, tokens and activity are not available."
            }
            if let transcript {
                row.traceFile = transcript.path
                if let stats = TranscriptStats.of(transcript) {
                    applyTranscript(stats,to:&row)
                }
            }
            // Now the transcript has been read, the loop is known — so decide
            // the state once more with everything in hand.
            if alive {
                row.state = AgentStateMachine.state(.init(
                    published: published,
                    lastActivity: row.lastActivity,
                    looping: row.isLooping))
            }
            if predatesProcess {
                row.pid = nil; row.rssBytes = nil; row.tmuxTarget = nil
                row.state = .unobserved
                row.localObservationIssue = "The session record predates this process. Its current ownership is unknown."
            }
            if let pid, unavailablePIDs.contains(pid) {
                row.pid = pid
                row.state = .unobserved
                row.localObservationIssue = "This process could not be inspected. Its current state is unknown."
            }
            row.sessionID = sessionID
            rows.append(row)
        }
        return rows
    }

    static func applyTranscript(_ stats:TranscriptStats,to row:inout AgentRow) {
        row.activity = stats.activitySeries()
        row.model = stats.model
        row.awaitingHistory = stats.isBacklogged
        if let issue = stats.usageIssue {
            row.sentTokens = nil; row.receivedTokens = nil; row.totalTokens = nil
            row.toolCalls = nil; row.costUSD = nil; row.contextTokens = nil
            row.note = issue
        } else {
            row.sentTokens = stats.hasUsageFacts ? stats.sentTokens : nil
            row.receivedTokens = stats.hasUsageFacts ? stats.receivedTokens : nil
            row.toolCalls = stats.toolCalls
            row.costUSD = stats.costUSD
            row.contextTokens = stats.contextTokens
        }
        row.contextWindow = Pricing.rate(for: stats.model)?.contextWindow
        row.loopWakeAt = stats.loopWakeAt
        row.loopStopped = stats.loopStopped
        if let last = stats.lastActivity { row.lastActivity = last }
    }

    /// When a harness publishes no explicit status, activity time is the only
    /// remaining evidence. Anything quiet longer than this is waiting rather
    /// than being presented as active.
    static let idleAfter: TimeInterval = 90
    /// Long enough to cover a lunch break or a meeting, short enough that
    /// yesterday's work does not read as today's.
    static let staleAfter: TimeInterval = 12 * 3600

    /// Names one conversation inside an app that hosts several. Two tabs open
    /// on the same folder need telling apart, and the only thing that reliably
    /// differs is the session's own id, so the tail of it is appended. A folder
    /// with a single conversation is just that folder — a suffix there would be
    /// noise on every row that never needed one.
    static func sessionName(folder: String, sessionID: String?,
                            sharing: Int, fallback: String) -> String {
        guard !folder.isEmpty, folder != "/" else { return fallback }
        guard sharing > 1 else { return folder }
        let tail = String((sessionID ?? "").suffix(4))
        return tail.isEmpty ? folder : "\(folder)-\(tail)"
    }

    /// Whether a detached harness's session is too old to speak for. A CLI
    /// agent is never stale: there the running process is the evidence.
    static func isStale(_ last: Date?, _ descriptor: HarnessDescriptor,
                        now: Date = Date()) -> Bool {
        guard descriptor.isDetached, let last else { return false }
        return now.timeIntervalSince(last) > (descriptor.staleAfter ?? staleAfter)
    }


    /// `/Users/example/Projects/sample` →
    /// `~/.claude/projects/-Users-example-Projects-sample/<id>.jsonl`
    ///
    /// A resumed or forked session keeps the *original* id as its filename, so
    /// an exact match can miss. When it does, look through the project's other
    /// transcripts for one that names this session inside.
    static func transcriptURL(cwd: String, sessionID: String, root: String?) -> URL? {
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4_096, !cwd.contains("\0"),
              !sessionID.isEmpty, sessionID.utf8.count <= 256,
              sessionID != ".", sessionID != "..",
              !sessionID.contains("/"), !sessionID.contains("\\"),
              !sessionID.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let base = (root ?? "~/.claude/projects").expandingTilde
        let dir = URL(fileURLWithPath: base).appendingPathComponent(encoded)
        var directoryInfo = stat()
        guard lstat(dir.path,&directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR else { return nil }

        let exact = dir.appendingPathComponent("\(sessionID).jsonl")
        if BoundedFile.isRegular(exact) { return exact }

        guard let entries = try? BoundedDirectory.entries(dir) else { return nil }
        let candidates = entries
            .filter { $0.isRegular && $0.url.pathExtension == "jsonl" }
            .sorted { $0.modified > $1.modified }
            .prefix(8)

        for candidate in candidates {
            // The id appears on every line, so the head is enough.
            guard let head = try? BoundedFile.prefix(candidate.url,maxBytes:32 * 1_024) else { continue }
            for line in head.split(separator:0x0A).prefix(256) {
                if let record = try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any],
                   record["sessionId"] as? String == sessionID { return candidate.url }
            }
        }
        return nil
    }

    // MARK: - Descriptor-driven harnesses

    /// One row per running process a descriptor claims, filled in from whatever
    /// that harness records. Adding a harness means adding a JSON file.
    /// The rows one descriptor contributes. Exposed so the rule that a
    /// workspace manager contributes none can be checked here rather than by
    /// re-reading the descriptor in a test.
    static func rows(for descriptor: HarnessDescriptor,
                     processes: [Int32: Processes.Info]) -> [AgentRow] {
        if descriptor.contributesFocusOnly { return [] }
        if descriptor.contributesPresenceOnly {
            return presenceRows(descriptor, processes: processes)
        }
        if descriptor.source.kind == .none { return [] }
        if descriptor.source.kind == .command {
            return commandRows(descriptor, processes: processes)
        }
        return []
    }

    private static func descriptorRows(processes: [Int32: Processes.Info]) -> [AgentRow] {
        var rows: [AgentRow] = []
        for descriptor in HarnessDescriptor.all() {
            // A source that names its own pids tells us which processes are
            // sessions; we don't have to recognise them by executable path.
            // `none` means the sessions are read elsewhere; this file exists to
            // say which processes are the agent's. It must not make rows of its
            // own, or every native harness would appear twice and empty.
            // A workspace manager's panes are other agents' sessions; they are
            // joined onto those rows afterwards rather than duplicating them.
            if descriptor.contributesFocusOnly { continue }
            if descriptor.contributesPresenceOnly {
                rows += self.rows(for: descriptor, processes: processes)
                continue
            }
            if descriptor.source.kind == .none { continue }
            if descriptor.source.kind == .command {
                rows += commandRows(descriptor, processes: processes)
                continue
            }
            // By pid, as `presenceRows` does two functions below. A dictionary
            // yields its values in an order that is stable within a process
            // and not across runs, so without this a harness claiming several
            // processes produces rows that shuffle between scans — and the
            // final sort cannot fix it, because rows tied on its key keep
            // whatever order they arrived in.
            let matches = processes.values
                .filter { descriptor.claims($0) }
                .sorted { $0.pid < $1.pid }
            guard !matches.isEmpty else { continue }

            for process in matches {
                let cwd = Processes.cwd(of: process.pid) ?? ""
                // A detached harness is a GUI app: whatever directory it was
                // launched from is not the project it has open, so it takes its
                // newest session instead of being matched by directory.
                let session: HarnessEngine.Session? = {
                    if descriptor.processRule.sessionBinding == .openSourceFile {
                        return HarnessEngine.session(
                            descriptor,
                            boundToOpenFiles: Processes.openFilePaths(of: process.pid))
                    }
                    return HarnessEngine.session(
                        descriptor, forCwd: descriptor.isDetached ? "" : cwd)
                }()
                // A declared binding is required session evidence, not a
                // preference. Helpers share the executable path but do not
                // own a transcript; emitting them would create phantom rows.
                if descriptor.processRule.sessionBinding != nil, session == nil {
                    continue
                }

                // An editor being open is not an agent at work. A detached
                // harness adopts its newest session, and that session can be
                // days old: Zed kept a row for a thread last touched two days
                // earlier, so a project nobody had opened looked like it was
                // running. It only speaks for a session someone has touched
                // recently — a CLI agent is unaffected, because there the
                // process itself is the evidence.
                // One app process, several conversations. OpenCode keeps every
                // tab in one database and runs them all in a single process, so
                // adopting only the newest session showed one row where the
                // user had four open — and the grouping below then kept just
                // one of them anyway, because they share a directory.
                if descriptor.isMultiSession {
                    let all = HarnessEngine.sessions(descriptor)
                    // A database that never forgets a directory will happily
                    // report a project the user removed from the app months
                    // ago. Where the harness can tell which projects are still
                    // listed, only those count; where it cannot, every recent
                    // session does, as before.
                    let openTabs: Set<String>? = {
                        if let selection = descriptor.sessionSelection {
                            return SessionSelection.openIDs(selection)
                        }
                        // Compatibility for an edited pre-selection descriptor.
                        return descriptor.wantsOpenTabsOnly ? OpenCodeTabs.open() : nil
                    }()
                    let live = all
                        .filter { session in
                            guard let openTabs else { return true }
                            guard let id = session.sessionID else { return false }
                            return openTabs.contains(id)
                        }
                        // A tab that is open is open however long it has been
                        // quiet. Staleness is only a stand-in for "still in
                        // use"; where the app answers that directly, the guess
                        // would just hide a conversation sitting right there.
                        .filter { openTabs != nil || !isStale($0.lastActivity, descriptor) }
                        .sorted { ($0.lastActivity ?? .distantPast)
                                > ($1.lastActivity ?? .distantPast) }
                    // Only tell them apart when they need telling apart: a
                    // lone conversation in a folder is just that folder.
                    var perFolder: [String: Int] = [:]
                    for open in live { perFolder[open.cwd ?? cwd, default: 0] += 1 }
                    for (rank, open) in live.enumerated() {
                        let where_ = open.cwd ?? cwd
                        guard where_ != "/" else { continue }
                        var row = AgentRow(
                            id: AgentIdentity.local(
                                harness: descriptor.id,
                                sessionID: open.sessionID,
                                cwd: where_,
                                pid: process.pid,
                                fallback: open.title ?? "\(rank)"),
                            agentID: descriptor.id,
                            name: sessionName(
                                folder: URL(fileURLWithPath: where_).lastPathComponent,
                                sessionID: open.sessionID,
                                sharing: perFolder[where_, default: 0],
                                fallback: descriptor.resolvedFallbackName ?? descriptor.name),
                            cwd: where_,
                            state: .waiting,
                            pid: process.pid,
                            // The process's memory belongs to the app, not to
                            // any one conversation inside it; repeating it on
                            // every row would multiply it in the total.
                            rssBytes: rank == 0 ? process.rss : nil)
                        apply(open, to: &row, descriptor, processAlive: true)
                        rows.append(row)
                    }
                    continue
                }

                if isStale(session?.lastActivity, descriptor) { continue }
                // A detached app's process directory is launch plumbing, not
                // the project. Keep it empty unless its session source states
                // a directory; a title can still name the conversation.
                let resolved = session?.cwd ?? (descriptor.isDetached ? "" : cwd)

                // A process sitting at the filesystem root with no session of
                // its own is a helper, not someone's work — ChatGPT.app runs
                // two such codex processes alongside the real CLI.
                if resolved == "/" && session == nil { continue }
                let name = session?.title
                    ?? URL(fileURLWithPath: resolved).lastPathComponent

                var row = AgentRow(
                    id: AgentIdentity.local(harness: descriptor.id,
                                            sessionID: session?.sessionID,
                                            cwd: resolved,
                                            pid: process.pid),
                    agentID: descriptor.id,
                    name: name.isEmpty || name == "/"
                        ? (descriptor.resolvedFallbackName ?? descriptor.name) : name,
                    cwd: resolved,
                    // No evidence yet. Starting at `.working` meant a process
                    // whose session could not be found stayed "Working" for
                    // ever — the state machine exists precisely so that an
                    // absence of evidence never reads as activity, and an
                    // initialiser default was quietly getting round it.
                    state: .waiting,
                    pid: process.pid,
                    rssBytes: process.rss)

                if let session {
                    apply(session, to: &row, descriptor, processAlive: true)
                }
                rows.append(row)
            }
        }
        // One session per project per harness, keeping the heaviest process —
        // except where the harness says a directory can hold several
        // conversations at once, which is exactly what this would collapse.
        let multi = Set(HarnessDescriptor.all().filter(\.isMultiSession).map(\.id))
        let processBound = Set(HarnessDescriptor.all().filter {
            $0.processRule.sessionBinding == .openSourceFile
        }.map(\.id))
        return Dictionary(grouping: rows, by: { row in
            multi.contains(row.agentID) || processBound.contains(row.agentID)
                ? row.id : "\(row.agentID)|\(row.cwd)"
        })
        .compactMap { $0.value.max { a, b in (a.rssBytes ?? 0) < (b.rssBytes ?? 0) } }
    }

    /// Copies everything a harness session knows onto its row.
    ///
    /// One function because there were two: the descriptor path and the command
    /// path each copied fields by hand, and the command path quietly omitted
    /// `sentTokens`, `receivedTokens` and `subAgents`. The engine had them all
    /// along — an identical harness showed less depending on which kind of
    /// source it used, which is exactly the inconsistency a contributor cannot
    /// diagnose from the outside.
    static func apply(_ session: HarnessEngine.Session,
                              to row: inout AgentRow,
                              _ descriptor: HarnessDescriptor,
                              processAlive: Bool) {
        row.traceFile = session.sourceFile
        row.focusTarget = session.focusTarget
        row.sessionID = session.sessionID
        row.model = session.model
        row.note = nil // Diagnostics describe this observation, not an older failure.
        row.awaitingHistory = session.sourceBacklogged == true
        if let issue = session.usageIssue {
            row.note = issue
            row.toolCalls = nil; row.turns = nil; row.subAgents = nil
            row.costUSD = nil; row.contextTokens = nil; row.contextWindow = nil
            row.sentTokens = nil; row.receivedTokens = nil; row.totalTokens = nil
        } else {
            row.toolCalls = session.hasNumeric("toolCalls") ? session.toolCalls : nil
            row.turns = session.hasNumeric("turns") ? session.turns : nil
            row.subAgents = session.hasNumeric("subAgents") ? session.subAgents : nil
            row.costUSD = session.hasNumeric("cost") ? session.costUSD : nil
            row.contextTokens = session.measuredContext
            // The harness's own figure beats our price table.
            row.contextWindow = session.contextWindow
                ?? Pricing.rate(for: session.model)?.contextWindow
            row.totalTokens = session.hasNumeric("totalTokens") ? session.totalTokens : nil
            row.sentTokens = (session.hasNumeric("inputTokens") || session.hasNumeric("cacheWrite")) ? session.sentTokens : nil
            row.receivedTokens = session.hasNumeric("outputTokens") ? session.outputTokens : nil
        }
        row.startedAt = session.startedAt
        row.lastActivity = session.lastActivity
        row.sessionName = session.title ?? ""

        // Loop state a harness keeps elsewhere, keyed by its own session id.
        var goalIssue: String?
        if let goals = descriptor.source.paths?["goals"], let id = session.sessionID {
            row.loopGoal = nil
            do {
                if let goal = try CodexGoals.all(at:goals)[id], goal.isRunning { row.loopGoal = goal.label }
            } catch {
                goalIssue = (error as? CodexGoals.ReadError)?.message ?? "Autonomous goal state is unavailable."
                row.note = [row.note,goalIssue].compactMap { $0 }.joined(separator:" ")
            }
        }
        row.state = AgentStateMachine.state(.init(
            processAlive: processAlive,
            published: session.isWorking.map { $0 ? .working : .waiting },
            lastActivity: session.lastActivity,
            idleAfter: descriptor.idleAfter ?? idleAfter,
            looping: row.isLooping))
        if processAlive, goalIssue != nil, !row.state.isBusy, !row.isLooping { row.state = .unobserved }
    }

    /// One row per session reported by a harness's own CLI.
    /// Joins a workspace manager's panes onto the rows they contain.
    ///
    /// Matched on the agent's own session id where the manager publishes one —
    /// Herdr does, and it is exact. Otherwise on the working directory, which
    /// is weaker: two agents in one folder cannot be told apart that way, so a
    /// directory claimed by more than one pane is left alone rather than
    /// guessed at. Focusing the wrong pane is worse than focusing none.
    static func attachWorkspaceTargets(to rows: inout [AgentRow],
                                       panes: [HarnessEngine.Session]) {
        guard !panes.isEmpty else { return }
        var bySession: [String: String] = [:]
        var byDirectory: [String: String] = [:]
        var ambiguous: Set<String> = []
        for pane in panes {
            guard let target = pane.focusTarget, !target.isEmpty else { continue }
            if let id = pane.sessionID, !id.isEmpty { bySession[id] = target }
            if let cwd = pane.cwd, !cwd.isEmpty {
                if byDirectory[cwd] != nil, byDirectory[cwd] != target { ambiguous.insert(cwd) }
                byDirectory[cwd] = target
            }
        }
        // The session id is exact, and applied first — but not blindly. Claude
        // reuses a session id across resumed sessions, so two live rows can
        // carry the same one, and both would then be sent to a single pane.
        var rowsPerSession: [String: Int] = [:]
        for row in rows {
            if let id = row.sessionID, !id.isEmpty { rowsPerSession[id, default: 0] += 1 }
        }
        var claimed: Set<String> = []
        for index in rows.indices where rows[index].focusTarget == nil {
            guard let id = rows[index].sessionID, rowsPerSession[id] == 1,
                  let target = bySession[id], !claimed.contains(target) else { continue }
            rows[index].focusTarget = target
            claimed.insert(target)
        }

        // The directory is not. One pane in a folder says nothing about which
        // of two agents working there it holds, and an earlier version of this
        // gave a Claude row and a Codex row the same Orca terminal — clicking
        // either would have raised one pane, silently wrong for the other. A
        // directory is only used when exactly one row and one pane claim it.
        var rowsPerDirectory: [String: Int] = [:]
        for row in rows where row.focusTarget == nil && !row.cwd.isEmpty {
            rowsPerDirectory[row.cwd, default: 0] += 1
        }
        for index in rows.indices where rows[index].focusTarget == nil {
            let cwd = rows[index].cwd
            guard !cwd.isEmpty, !ambiguous.contains(cwd), rowsPerDirectory[cwd] == 1,
                  let target = byDirectory[cwd], !claimed.contains(target) else { continue }
            rows[index].focusTarget = target
            claimed.insert(target)
        }
    }

    /// One row per running process, and nothing else.
    ///
    /// For an agent that keeps no durable session record the process is the
    /// whole of the evidence. Every figure stays absent rather than zero: this
    /// harness genuinely does not know the token count, and saying zero would
    /// be a claim it cannot support.
    static func presenceRows(_ descriptor: HarnessDescriptor,
                             processes: [Int32: Processes.Info]) -> [AgentRow] {
        processes.values
            .filter { descriptor.claims($0) }
            .sorted { $0.pid < $1.pid }
            .map { process in
                let cwd = Processes.cwd(of: process.pid) ?? ""
                let folder = URL(fileURLWithPath: cwd).lastPathComponent
                var row = AgentRow(
                    id: AgentIdentity.local(harness: descriptor.id, sessionID: nil,
                                            cwd: cwd, pid: process.pid),
                    agentID: descriptor.id,
                    name: folder.isEmpty
                        ? (descriptor.resolvedFallbackName ?? descriptor.name) : folder,
                    cwd: cwd,
                    state: .unobserved,
                    pid: process.pid,
                    rssBytes: process.rss)
                // Said plainly, because a row with no numbers otherwise reads
                // as an agent that has done nothing.
                row.localObservationIssue =
                    "\(descriptor.name) keeps no session record, so only its presence is known."
                return row
            }
    }

    private static func commandRows(_ descriptor: HarnessDescriptor,
                                    processes: [Int32: Processes.Info]) -> [AgentRow] {
        HarnessEngine.sessions(descriptor).compactMap { session in
            let process = session.pid.flatMap { processes[$0] }
            let cwd = session.cwd ?? ""
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            var row = AgentRow(
                id: AgentIdentity.local(harness: descriptor.id,
                                        sessionID: session.sessionID,
                                        cwd: cwd,
                                        pid: session.pid,
                                        fallback: session.title),
                agentID: descriptor.id,
                name: name.isEmpty ? (descriptor.resolvedFallbackName ?? descriptor.name) : name,
                cwd: cwd,
                state: .waiting,
                pid: process != nil ? session.pid : nil,
                rssBytes: process?.rss)
            apply(session, to: &row, descriptor, processAlive: process != nil)
            return row
        }
    }

}
