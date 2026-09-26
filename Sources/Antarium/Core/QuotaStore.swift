import Foundation

/// Latest account-quota readings from each menu-bar provider, for the dashboard.
///
/// Session rows read transcripts; provider gauges live in the status bar. This
/// bridge lets a session row show its provider's included-usage bar without
/// duplicating the network fetch.
@MainActor
final class QuotaStore: ObservableObject {
    static let shared = QuotaStore()

    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published private(set) var errors: [String: ProviderError] = [:]

    /// Providers whose menu bar item has gone, and whose readings are
    /// therefore no longer wanted.
    ///
    /// Switching an agent off disposes its item, which removes its reading —
    /// and a fetch already in flight finishes afterwards and puts it back. The
    /// item is gone by then, so it never publishes again: the dashboard kept
    /// drawing that agent's gauge and plan label, frozen at whatever the last
    /// fetch returned, until the app was relaunched.
    ///
    /// Held here rather than as a flag on the item because this is the side a
    /// test can reach. Constructing an `AgentItem` needs a status bar, which
    /// is why the wiring between disposal and removal was noted in that file
    /// as held by reading rather than by a test.
    private var retired: Set<String> = []

    /// Accepts readings from this provider again.
    ///
    /// Called when an item is created, which is the only thing that makes a
    /// provider's readings wanted. Without it, switching an agent off and on
    /// again would leave it silently retired for the rest of the session —
    /// the same bug in the other direction, and a worse one.
    func admit(providerID: String) {
        retired.remove(providerID)
    }

    func set(providerID: String, snapshot: Snapshot?) {
        guard !retired.contains(providerID) else { return }
        if let snapshot {
            snapshots[providerID] = snapshot
            errors.removeValue(forKey: providerID)
        } else {
            snapshots.removeValue(forKey: providerID)
            errors.removeValue(forKey: providerID)
        }
    }

    func set(providerID: String, error: ProviderError, last: Snapshot?) {
        guard !retired.contains(providerID) else { return }
        errors[providerID] = error
        if let last { snapshots[providerID] = last }
    }

    func remove(providerID: String) {
        retired.insert(providerID)
        snapshots.removeValue(forKey: providerID)
        errors.removeValue(forKey: providerID)
    }

    func snapshot(for agentID: String) -> Snapshot? {
        snapshots[agentID]
    }

    func primaryGauge(for agentID: String) -> Gauge? {
        snapshot(for: agentID)?.gauges.first
    }

    /// How long a reading may stand before it is worth saying how old it is.
    ///
    /// The menu bar refreshes every minute, so a snapshot older than several
    /// of those is one whose refreshes have been failing — the store keeps
    /// the last good reading on purpose, so the bar does not blink out, and
    /// the cost of that is a figure that goes on looking current.
    nonisolated static let staleAfter: TimeInterval = 5 * 60

    /// Whether a reading is old enough that showing it without saying so
    /// would be presenting a guess as a fact.
    ///
    /// Pure, because the answer is the whole rule: the menu already says
    /// "Updated ten minutes ago" and the dashboard drew the same figure with
    /// nothing at all, so the two surfaces disagreed about whether the number
    /// on screen was current.
    nonisolated static func isStale(_ fetchedAt: Date?, now: Date = Date(),
                                    after: TimeInterval = staleAfter) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > after
    }

    /// When the reading behind this agent's gauge was taken.
    func fetchedAt(for agentID: String) -> Date? {
        snapshot(for: agentID)?.fetchedAt
    }
}
