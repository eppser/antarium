import Foundation
import Combine

/// Keeps the agent picture warm in the background so the dashboard opens
/// already populated rather than scanning on click.
///
/// The first pass reads each relevant transcript once; offsets are persisted,
/// so later scans consume only appended bytes. This has its own interval,
/// separate from quota polling: account limits move over hours, agent state
/// over seconds.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var rows: [AgentRow] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedAt: Date?
    /// Fired after every successful scan, for surfaces that aren't SwiftUI.
    var onRowsChanged: (([AgentRow]) -> Void)?

    /// Previous pass, for spotting an agent that just finished.
    private var lastRows: [String: AgentRow] = [:]
    private var lastCacheWrite = Date.distantPast
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generations = ScanGeneration()
    private var cloudRows: [AgentRow] = []
    private var lastCloudAttempt = Date.distantPast
    /// Remote rows kept per machine, never pooled.
    ///
    /// Pooling them meant one retention rule for the whole sweep, which cannot
    /// be right for more than one host: replacing the pool erased a failing
    /// machine's rows the moment a healthy one answered, and keeping the pool
    /// froze every machine's rows whenever the sweep as a whole came back
    /// empty. Each host now keeps or replaces its own.
    private var remoteRowsByHost: [String: [AgentRow]] = [:]
    /// Why a host last contributed nothing, for the settings panel.
    @Published private(set) var remoteIssues: [String: String] = [:]
    private var lastRemoteAttempt = Date.distantPast
    private let remoteScan = RemoteScanController()
    /// The most recent local and cloud passes, so a remote result arriving on
    /// its own clock can be merged without waiting for another local scan.
    private var localRows: [AgentRow] = []
    @Published private(set) var scanIssue: String?
    private var localScanIssue: String?
    private var cloudScanIssue: String?
    /// Scan more often while the dashboard is on screen.
    private(set) var visibleObservers = 0

    /// Agents that were working last pass and aren't now.
    ///
    /// A vanished row counts: Claude leaves its session file behind so a
    /// finished session still appears as `.ended`, but a Codex or Kimi row only
    /// exists while its process does — without this they could never announce
    /// that they'd stopped.
    ///
    /// Pure, so the transition rule can be checked without a running app.
    static func stopped(previous: [String: AgentRow], current: [AgentRow]) -> [AgentRow] {
        guard !previous.isEmpty else { return [] }
        let now = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return previous.values.compactMap { was in
            guard was.state.rank > 2 else { return nil }        // wasn't working
            guard let still = now[was.id] else { return was }   // process is gone
            if case .unobserved = still.state { return nil }
            return still.state.rank <= 2 ? still : nil
        }
    }

    static func applyingLocal(_ observation: AgentScan.Observation?, previous: [AgentRow]) -> (rows: [AgentRow], issue: String?) {
        let issue = "Some local agent sources could not be read reliably. Affected agents have an unknown current state."
        func stale(_ row: AgentRow) -> AgentRow {
            var row = row
            row.state = .unobserved; row.rssBytes = nil; row.localObservationIssue = issue
            return row
        }
        guard let observation else { return (previous.map(stale), issue) }
        var rows = observation.rows
        var index = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) },uniquingKeysWith:{first,_ in first})
        var affected = !observation.unavailableHarnesses.isEmpty || rows.contains { $0.localObservationIssue != nil }
        for row in previous {
            guard observation.unavailableHarnesses.contains(row.agentID)
                || row.pid.map({ observation.unavailablePIDs.contains($0) }) == true else { continue }
            affected = true
            if let position = index[row.id] { rows[position] = stale(row) }
            else { index[row.id] = rows.count; rows.append(stale(row)) }
        }
        return (rows, affected ? issue : nil)
    }

    private func noticeStops(in fresh: [AgentRow]) {
        for row in Self.stopped(previous: lastRows, current: fresh) {
            AgentAlert.shared.post(row)
            Sounds.play(.agentStopped)
        }
        lastRows = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Folds one sweep into the per-host state.
    ///
    /// Pure, because this is the rule that was wrong: it has to hold for a
    /// mix of machines behaving differently in the same sweep, and that cannot
    /// be checked by reading it.
    ///
    /// - A host that answered replaces its rows, *including with none*. An
    ///   empty answer is a fact about that machine, not a failure; treating it
    ///   as one would leave ended sessions on screen forever.
    /// - A host that failed keeps the rows it last showed and records why, so
    ///   one bad connection does not blink a machine out of the list.
    /// - A host no longer configured leaves nothing behind.
    static func applyRemote(results: [RemoteTmux.HostResult],
                            to current: [String: [AgentRow]],
                            issues: [String: String],
                            configured: [String], now:Date = Date()) -> (rows: [String: [AgentRow]],
                                                      issues: [String: String]) {
        var rows = current
        var problems = issues
        for result in results {
            if result.answered {
                rows[result.host] = result.rows.map { row in
                    var fresh = row; fresh.remoteObservedAt = now; fresh.remoteObservationIssue = nil
                    return fresh
                }
                problems[result.host] = nil
            } else {
                problems[result.host] = result.issue
                rows[result.host] = rows[result.host]?.map { row in
                    var stale = row; stale.state = .unobserved; stale.remoteObservationIssue = result.issue
                    return stale
                }
            }
        }
        let keep = Set(RemoteTmux.normalizedHosts(configured))
        return (rows.filter { keep.contains($0.key) },
                problems.filter { keep.contains($0.key) })
    }

    /// Every machine's rows, in the order the hosts are configured, so the
    /// list does not reorder itself because one machine answered first.
    static func orderedRemoteRows(hosts:[String],rowsByHost:[String:[AgentRow]]) -> [AgentRow] {
        RemoteTmux.normalizedHosts(hosts).flatMap { rowsByHost[$0] ?? [] }
    }
    private func remoteRows() -> [AgentRow] {
        Self.orderedRemoteRows(hosts:Settings.remoteTmuxHosts,rowsByHost:remoteRowsByHost)
    }

    /// Merge whatever each source last produced and publish it. Called by the
    /// local scan and, separately, whenever a remote refresh lands.
    private func publish() {
        let harnessIssue = HarnessDescriptor.failures.isEmpty ? nil : "Harness configuration needs attention. Last valid definitions are used when available; see Settings."
        let issues = [localScanIssue,cloudScanIssue,harnessIssue].compactMap { $0 }
        scanIssue = issues.isEmpty ? nil : issues.joined(separator:" ")
        let fresh = AgentScan.merge(local: localRows,
                                    cloud: cloudRows + (Settings.includeRemoteTmux ? remoteRows() : []))
        noticeStops(in: fresh)
        // Re-sort on arrival, not when the scan began. Changing the order
        // while one was in flight cannot be overwritten by stale settings.
        let ordered = AgentScan.sorted(fresh, by: Settings.agentSort)
        rows = ordered
        onRowsChanged?(ordered)
    }

    /// Starts a remote pass if one is due and none is running. Deliberately
    /// not awaited: the point is that it cannot delay the local rows.
    /// Whether to reach out to the fleet, and what to do if not.
    ///
    /// Pure, because three of these four rules are about not connecting: a
    /// sweep opens an SSH session to every configured machine, and the one
    /// that matters most is that switching the feature off stops it. Nothing
    /// tested any of them.
    enum RemoteSweep: Equatable {
        /// Stop, and drop anything in flight.
        case cancel
        /// Not yet — too soon, or one is already running.
        case skip
        case run
    }

    static func remoteSweep(enabled: Bool, hosts: [String], running: Bool,
                            force: Bool, sinceLastAttempt: TimeInterval,
                            minimumInterval: TimeInterval = 30) -> RemoteSweep {
        guard enabled, !hosts.isEmpty else { return .cancel }
        guard !running else { return .skip }
        guard force || sinceLastAttempt >= minimumInterval else { return .skip }
        return .run
    }

    /// Whether results that have just arrived may still be shown. Separate
    /// from `remoteSweep` because it is asked at a different moment — after
    /// the connections have already happened — and the answer can have
    /// changed in between.
    static func shouldApplyRemote(enabled: Bool, hosts: [String]) -> Bool {
        enabled && !hosts.isEmpty
    }

    private func refreshRemoteIfDue(force: Bool) {
        let hosts = Settings.remoteTmuxHosts
        switch Self.remoteSweep(enabled: Settings.includeRemoteTmux, hosts: hosts,
                                running: remoteScan.isRunning, force: force,
                                sinceLastAttempt: Date().timeIntervalSince(lastRemoteAttempt)) {
        case .cancel: remoteScan.cancel(); return
        case .skip:   remoteScan.reconcile(hosts: hosts); return
        case .run:    remoteScan.reconcile(hosts: hosts)
        }
        lastRemoteAttempt = Date()
        remoteScan.start(hosts:hosts) { [weak self] results in
            // The same question as `remoteSweep` asked before starting, asked
            // again now: a sweep takes seconds, and the setting can be turned
            // off while it is in flight. Results arriving after that belong to
            // a feature the user has switched off.
            guard let self,
                  Self.shouldApplyRemote(enabled: Settings.includeRemoteTmux,
                                         hosts: Settings.remoteTmuxHosts)
            else { return }
            let merged = Self.applyRemote(results:results,to:self.remoteRowsByHost,
                issues:self.remoteIssues,configured:Settings.remoteTmuxHosts)
            self.remoteRowsByHost = merged.rows
            self.remoteIssues = merged.issues
            self.publish()
        }
    }

    /// Re-order in place without waiting for the next scan.
    func setSort(_ order: AgentSort) {
        Settings.agentSort = order
        rows = AgentScan.sorted(rows, by: order)
        SettingsBus.shared.changed()
    }
    var totalCost: Double { rows.compactMap(\.costUSD).reduce(0, +) }
    var totalRAM: Int64 { rows.compactMap(\.rssBytes).reduce(0, +) }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        TranscriptStats.loadCache()
        TranscriptStats.removeSupersededCaches()
        HarnessEngine.loadCache()
        reschedule()
        // Warm the cache at launch — this is the one expensive pass.
        refresh()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        task?.cancel()
        task = nil
        // Cancelling propagates to queued hosts, SSH and credential subprocesses.
        // The controller's generation gate also rejects late completions.
        remoteScan.cancel()
        isScanning = false
        TranscriptStats.saveCache()
        HarnessEngine.saveCache()
    }

    /// Called when the dashboard opens and closes.
    func setVisible(_ visible: Bool) {
        // Clamped at zero: an unbalanced close would otherwise drive the count
        // negative and every later open would be swallowed getting back to
        // zero, leaving the dashboard refreshing at the idle rate while open.
        visibleObservers = max(0, visibleObservers + (visible ? 1 : -1))
        reschedule()
        if visible { refresh() }
    }

    /// How often to scan, given how many views are watching.
    ///
    /// Pure, because the difference between this returning five and returning
    /// the user's interval is the difference between a laptop that idles and
    /// one that does not, and a counter that fails to come back down pins it
    /// at the fast rate for the life of the process — a battery drain that
    /// reads as "the app is just like that".
    ///
    /// Never slower than the user asked for and never faster than five
    /// seconds while watched; a configured interval below five is honoured as
    /// it stands rather than being raised to meet the cap.
    static func scanInterval(visible: Int, configured: Int) -> Double {
        visible > 0 ? min(Double(configured), 5) : Double(configured)
    }

    private func reschedule() {
        timer?.invalidate()
        let seconds = Self.scanInterval(visible: visibleObservers,
                                        configured: Settings.agentScanSeconds)
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func intervalChanged() { reschedule() }

    // MARK: - Scanning

    /// `force` is the refresh button: throw away what we are holding first, so
    /// the numbers on screen afterwards were all read just now.
    func refresh(force: Bool = false) {
        // Apply a host removal or disabled switch before waiting for local IO.
        if Settings.includeRemoteTmux { remoteScan.reconcile(hosts:Settings.remoteTmuxHosts) }
        else { remoteScan.cancel() }
        if force {
            Log.info("scan", "refresh requested — dropping caches")
            HarnessEngine.invalidate()
            HarnessDescriptor.reload()
            ProjectContext.invalidate()
            Pricing.reload()
        }
        if task != nil {
            guard force else { return }            // periodic scans never stack
            task?.cancel()                         // force replaces the generation
        }
        let generation = generations.begin()
        isScanning = true
        task = Task { [weak self] in
            Log.debug("scan", "starting")
            let began = ProcessInfo.processInfo.systemUptime
            let worker = Task.detached(priority: .utility) { Result { try AgentScan.observe() } }
            let observation = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self,
                  self.generations.mayPublish(generation, cancelled: Task.isCancelled)
            else { return }
            let local = Self.applyingLocal(try? observation.get(),previous:self.localRows)
            Log.info("scan", "\(local.rows.count) rows in "
                + "\(String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - began) * 1000))ms"
                + " — working \(local.rows.filter { if case .working = $0.state { return true }; return false }.count)")

            var cloud = Settings.includeCloudAgents ? self.cloudRows : []
            if Settings.includeCloudAgents,
               force || Date().timeIntervalSince(self.lastCloudAttempt) >= 60 {
                self.lastCloudAttempt = Date()
                do {
                    cloud = try await CloudScan.codexTasks()
                    guard self.generations.mayPublish(generation, cancelled: Task.isCancelled) else { return }
                    self.cloudRows = cloud
                    self.cloudScanIssue = nil
                } catch {
                    guard self.generations.mayPublish(generation, cancelled: Task.isCancelled) else { return }
                    let message = CloudScan.issue(for:error)
                    Log.info("scan", message)
                    self.cloudScanIssue = message
                    cloud = CloudScan.unavailableRows(self.cloudRows,issue:message)
                }
            }
            if !Settings.includeCloudAgents { self.cloudScanIssue = nil }

            if !Settings.includeRemoteTmux {
                self.remoteRowsByHost = [:]
                self.remoteIssues = [:]
            }

            guard self.generations.mayPublish(generation, cancelled: Task.isCancelled) else { return }
            self.localRows = local.rows
            self.localScanIssue = local.issue
            self.cloudRows = cloud
            self.publish()
            self.scannedAt = Date()
            self.isScanning = false
            self.task = nil

            // Remote tmux hosts are refreshed *after* publishing, never in
            // front of it. Each host is an SSH round trip that can hang until
            // its 20s timeout, and awaiting that before assigning `rows` froze
            // the whole dashboard — every local row included — for as long as
            // one unreachable machine took to fail. The rows already on screen
            // stay live; the remote ones arrive when they arrive.
            self.refreshRemoteIfDue(force: force)
            // Cheap to write, but not every tick.
            if Date().timeIntervalSince(self.lastCacheWrite) > 120 {
                self.lastCacheWrite = Date()
                Task.detached(priority: .background) {
                    TranscriptStats.saveCache()
                    HarnessEngine.saveCache()
                }
            }
        }
    }
}

extension AgentStore {
    /// Used by `--dashboard` to render without starting the timer.
    func adoptForPreview(_ rows: [AgentRow]) {
        self.rows = rows
        self.scannedAt = Date()
        self.isScanning = false
    }
}
