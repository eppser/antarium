import Foundation

/// One agent session, local or cloud.
struct AgentRow: Identifiable {
    enum State {
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
            case .cloud:   return 2
            case .shell:   return 3
            // Above the "wants you" threshold: a loop pausing between rounds
            // has not stopped, and announcing it every iteration would be noise.
            case .looping: return 4
            case .working: return 5
            }
        }
        var label: String {
            switch self {
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
    var context = ProjectContext()
    /// Assistant turns per 10-minute bucket over the last 6 hours.
    var activity: [Int] = []
    /// Whole-session traffic, shown as plain totals.
    var sentTokens: Int?
    var receivedTokens: Int?
    /// Sub-agents this session spawned. Distinct from tool calls — Kimi's count
    /// was previously shown under the tool icon, which read as 11 tool calls.
    var subAgents: Int?
    /// Conversation turns. Cursor records these but not tool calls, and putting
    /// them under the hammer would repeat the same mislabelling.
    var turns: Int?
    /// Claude's own session name, e.g. "spicy-c1" — kept for the tooltip.
    var sessionName: String = ""

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

    // MARK: - Entry point

    /// Runs off the main thread; can take a moment on a machine with many
    /// large transcripts.
    static func scan() -> [AgentRow] {
        let processes = liveProcesses()
        var rows = claudeRows(processes: processes)
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
        for i in rows.indices where !rows[i].cwd.isEmpty {
            rows[i].context = ProjectContext.scan(rows[i].cwd, agentID: rows[i].agentID)
        }
        return sorted(uniqued(rows))
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
                NSLog("Antarium: duplicate row id %@ from %@", row.id, row.agentID)
                row.id = candidate
            }
            seen.insert(row.id)
            out.append(row)
        }
        return out
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
                if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
        case .harness:
            // Group by agent, then by the status order within each group.
            return rows.sorted {
                if $0.agentID != $1.agentID { return $0.agentID < $1.agentID }
                if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
        case .host:
            // Group by the app they run in — tmux together, Warp together —
            // and keep the status order inside each group. Agents with no known
            // host sort last rather than under an empty heading.
            return rows.sorted {
                let a = $0.hostApp ?? "\u{10FFFF}", b = $1.hostApp ?? "\u{10FFFF}"
                if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
                if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
        case .spend:
            return rows.sorted { ($0.costUSD ?? -1) > ($1.costUSD ?? -1) }
        case .activity:
            // An agent that is working right now *is* the most recent action,
            // whatever its transcript says. Several harnesses only write when a
            // turn ends — PI records nothing until it answers — so sorting on
            // the file's timestamp alone put a busy agent below a dozen idle
            // ones, and one with no timestamp at all dead last.
            return rows.sorted {
                if $0.state.isBusy != $1.state.isBusy { return $0.state.isBusy }
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
        }
    }

    // MARK: - Processes

    /// Called with an executable path, a process name and argv[0] separately,
    /// so both kinds of match belong here. Without the name check an agent that
    /// runs under an interpreter reported 0MB — its path is only ever "node".
    static func isAgent(_ candidate: String) -> Bool {
        if HarnessDescriptor.matchFragments().contains(where: { candidate.contains($0) }) {
            return true
        }
        return HarnessDescriptor.processNamesAll()
            .contains((candidate as NSString).lastPathComponent)
    }

    static func liveProcesses() -> [Int32: Processes.Info] {
        Processes.snapshot(measureIf: isAgent)
    }

    // MARK: - Claude Code

    /// Claude Code publishes live session state per pid, including a status of
    /// idle / busy / shell — far better than inferring activity from a transcript.
    private static func claudeRows(processes: [Int32: Processes.Info]) -> [AgentRow] {
        guard let claude = HarnessDescriptor.all().first(where: { $0.id == "claude-code" })
        else { return [] }                       // switched off, or removed
        let dir = URL(fileURLWithPath: claude.source.path.expandingTilde)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []

        var rows: [AgentRow] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = d["cwd"] as? String else { continue }

            let pid = (d["pid"] as? Int).map(Int32.init)
            let alive = pid.map { processes[$0] != nil } ?? false
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
                startedAt: (d["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                lastActivity: (d["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                pid: alive ? pid : nil,
                rssBytes: pid.flatMap { processes[$0]?.rss },
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
                if let stats = TranscriptStats.of(transcript) {
                    row.activity = stats.activitySeries()
                    row.sentTokens = stats.sentTokens > 0 ? stats.sentTokens : nil
                    row.receivedTokens = stats.receivedTokens > 0 ? stats.receivedTokens : nil
                    row.model = stats.model
                    row.toolCalls = stats.toolCalls
                    row.costUSD = stats.costUSD
                    row.contextTokens = stats.contextTokens
                    row.contextWindow = Pricing.rate(for: stats.model)?.contextWindow
                    row.loopWakeAt = stats.loopWakeAt
                    row.loopStopped = stats.loopStopped
                    if let last = stats.lastActivity { row.lastActivity = last }
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
            rows.append(row)
        }
        return rows
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
    private static func transcriptURL(cwd: String, sessionID: String, root: String?) -> URL? {
        let fm = FileManager.default
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let base = (root ?? "~/.claude/projects").expandingTilde
        let dir = URL(fileURLWithPath: base).appendingPathComponent(encoded)

        let exact = dir.appendingPathComponent("\(sessionID).jsonl")
        if fm.fileExists(atPath: exact.path) { return exact }

        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let candidates = entries
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(8)

        let needle = "\"sessionId\":\"\(sessionID)\""
        for (url, _) in candidates {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // The id appears on every line, so the head is enough.
            if let head = try? handle.read(upToCount: 32 * 1024),
               String(decoding: head, as: UTF8.self).contains(needle) {
                return url
            }
        }
        return nil
    }

    // MARK: - Descriptor-driven harnesses

    /// One row per running process a descriptor claims, filled in from whatever
    /// that harness records. Adding a harness means adding a JSON file.
    private static func descriptorRows(processes: [Int32: Processes.Info]) -> [AgentRow] {
        var rows: [AgentRow] = []
        for descriptor in HarnessDescriptor.all() {
            // A source that names its own pids tells us which processes are
            // sessions; we don't have to recognise them by executable path.
            // `none` means the sessions are read elsewhere; this file exists to
            // say which processes are the agent's. It must not make rows of its
            // own, or every native harness would appear twice and empty.
            if descriptor.source.kind == .none { continue }
            if descriptor.source.kind == .command {
                rows += commandRows(descriptor, processes: processes)
                continue
            }
            let matches = processes.values.filter { descriptor.claims($0) }
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
    private static func apply(_ session: HarnessEngine.Session,
                              to row: inout AgentRow,
                              _ descriptor: HarnessDescriptor,
                              processAlive: Bool) {
        row.model = session.model
        row.toolCalls = session.toolCalls > 0 ? session.toolCalls : nil
        row.turns = session.turns > 0 ? session.turns : nil
        row.subAgents = session.subAgents > 0 ? session.subAgents : nil
        row.costUSD = session.costUSD > 0 ? session.costUSD : nil
        row.contextTokens = session.contextTokens > 0 ? session.contextTokens : nil
        // The harness's own figure beats our price table.
        row.contextWindow = session.contextWindow
            ?? Pricing.rate(for: session.model)?.contextWindow
        row.sentTokens = session.sentTokens > 0 ? session.sentTokens : nil
        row.receivedTokens = session.outputTokens > 0 ? session.outputTokens : nil
        row.startedAt = session.startedAt
        row.lastActivity = session.lastActivity
        row.sessionName = session.title ?? ""

        // Loop state a harness keeps elsewhere, keyed by its own session id.
        if let goals = descriptor.source.paths?["goals"], let id = session.sessionID,
           let goal = CodexGoals.all(at: goals)[id], goal.isRunning {
            row.loopGoal = goal.label
        }
        row.state = AgentStateMachine.state(.init(
            processAlive: processAlive,
            published: session.isWorking.map { $0 ? .working : .waiting },
            lastActivity: session.lastActivity,
            idleAfter: descriptor.idleAfter ?? idleAfter,
            looping: row.isLooping))
    }

    /// One row per session reported by a harness's own CLI.
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
