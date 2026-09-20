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
    private var remoteTask: Task<Void, Never>?
    /// The most recent local and cloud passes, so a remote result arriving on
    /// its own clock can be merged without waiting for another local scan.
    private var localRows: [AgentRow] = []
    @Published private(set) var scanIssue: String?
    /// Scan more often while the dashboard is on screen.
    private var visibleObservers = 0

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
            return still.state.rank <= 2 ? still : nil
        }
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
                            configured: [String]) -> (rows: [String: [AgentRow]],
                                                      issues: [String: String]) {
        var rows = current
        var problems = issues
        for result in results {
            if result.answered {
                rows[result.host] = result.rows
                problems[result.host] = nil
            } else {
                problems[result.host] = result.issue
            }
        }
        let keep = Set(configured)
        return (rows.filter { keep.contains($0.key) },
                problems.filter { keep.contains($0.key) })
    }

    /// Every machine's rows, in the order the hosts are configured, so the
    /// list does not reorder itself because one machine answered first.
    private func remoteRows() -> [AgentRow] {
        Settings.remoteTmuxHosts.flatMap { remoteRowsByHost[$0] ?? [] }
    }

    /// Merge whatever each source last produced and publish it. Called by the
    /// local scan and, separately, whenever a remote refresh lands.
    private func publish() {
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
    private func refreshRemoteIfDue(force: Bool) {
        guard Settings.includeRemoteTmux else { return }
        let hosts = Settings.remoteTmuxHosts
        guard !hosts.isEmpty else { return }
        // One in flight at a time. Hosts that time out take 20s each, which is
        // longer than the scan interval, so without this the passes would pile
        // up and re-ask a dead machine while the previous ask was still open.
        guard remoteTask == nil else { return }
        guard force || Date().timeIntervalSince(lastRemoteAttempt) >= 30 else { return }
        lastRemoteAttempt = Date()
        remoteTask = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                RemoteTmux.scanAll(hosts: hosts)
            }.value
            guard let self else { return }
            // Cleared on every exit, not just the happy one. Returning early
            // without clearing left `remoteTask` non-nil forever, and the
            // single-flight guard above then blocked every future remote scan
            // for the rest of the session — remote agents would quietly stop
            // updating with nothing in the log to say why.
            defer { self.remoteTask = nil }
            guard !Task.isCancelled else { return }

            let merged = Self.applyRemote(results: results,
                                          to: self.remoteRowsByHost,
                                          issues: self.remoteIssues,
                                          configured: Settings.remoteTmuxHosts)
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
        // An SSH sweep outlives the scan that started it — up to 20s per host
        // — and would otherwise carry on and publish into a stopped store.
        remoteTask?.cancel()
        remoteTask = nil
        isScanning = false
        TranscriptStats.saveCache()
        HarnessEngine.saveCache()
    }

    /// Called when the dashboard opens and closes.
    func setVisible(_ visible: Bool) {
        visibleObservers = max(0, visibleObservers + (visible ? 1 : -1))
        reschedule()
        if visible { refresh() }
    }

    private func reschedule() {
        timer?.invalidate()
        let seconds = visibleObservers > 0
            ? min(Double(Settings.agentScanSeconds), 5)
            : Double(Settings.agentScanSeconds)
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
            let local = await Task.detached(priority: .utility) { AgentScan.scan() }.value
            Log.info("scan", "\(local.count) rows in "
                + "\(String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - began) * 1000))ms"
                + " — working \(local.filter { if case .working = $0.state { return true }; return false }.count)")
            guard let self, self.generations.isCurrent(generation),
                  !Task.isCancelled else { return }

            var cloud = Settings.includeCloudAgents ? self.cloudRows : []
            if Settings.includeCloudAgents,
               force || Date().timeIntervalSince(self.lastCloudAttempt) >= 60 {
                self.lastCloudAttempt = Date()
                do {
                    cloud = try await CloudScan.codexTasks()
                    guard self.generations.isCurrent(generation),
                          !Task.isCancelled else { return }
                    self.cloudRows = cloud
                    self.scanIssue = nil
                } catch {
                    let message = "Cloud scan failed: \(error.localizedDescription)"
                    Log.info("scan", message)
                    self.scanIssue = message
                    cloud = self.cloudRows
                }
            }

            if !Settings.includeRemoteTmux {
                self.remoteRowsByHost = [:]
                self.remoteIssues = [:]
            }

            guard self.generations.isCurrent(generation),
                  !Task.isCancelled else { return }
            self.localRows = local
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
