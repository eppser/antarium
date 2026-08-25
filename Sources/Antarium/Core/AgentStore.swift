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

            guard self.generations.isCurrent(generation),
                  !Task.isCancelled else { return }
            let fresh = AgentScan.merge(local: local, cloud: cloud)
            self.noticeStops(in: fresh)
            // Re-sort on arrival, not when the scan began. Changing the order
            // while one was in flight cannot be overwritten by stale settings.
            let ordered = AgentScan.sorted(fresh, by: Settings.agentSort)
            self.rows = ordered
            self.onRowsChanged?(ordered)
            self.scannedAt = Date()
            self.isScanning = false
            self.task = nil
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
