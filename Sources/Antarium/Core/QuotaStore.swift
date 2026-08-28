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

    func set(providerID: String, snapshot: Snapshot?) {
        if let snapshot {
            snapshots[providerID] = snapshot
            errors.removeValue(forKey: providerID)
        } else {
            snapshots.removeValue(forKey: providerID)
            errors.removeValue(forKey: providerID)
        }
    }

    func set(providerID: String, error: ProviderError, last: Snapshot?) {
        errors[providerID] = error
        if let last { snapshots[providerID] = last }
    }

    func remove(providerID: String) {
        snapshots.removeValue(forKey: providerID)
        errors.removeValue(forKey: providerID)
    }

    func snapshot(for agentID: String) -> Snapshot? {
        snapshots[agentID]
    }

    func primaryGauge(for agentID: String) -> Gauge? {
        snapshot(for: agentID)?.gauges.first
    }
}
