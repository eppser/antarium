import Foundation

/// Latest account-quota readings from each menu-bar provider, for the dashboard.
///
/// Session rows read transcripts; provider gauges live in the status bar. This
/// bridge lets a Cursor session row show the same included-usage bar Codex rows
/// get from per-session context, without duplicating the network fetch.
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
        }
    }

    func set(providerID: String, error: ProviderError, last: Snapshot?) {
        errors[providerID] = error
        if let last { snapshots[providerID] = last }
    }

    /// Maps harness ids that share a provider's account quota.
    static func providerID(for agentID: String) -> String {
        switch agentID {
        case "cursor-cli": return "cursor"
        case "codex-desktop": return "codex"
        default: return agentID
        }
    }

    func snapshot(for agentID: String) -> Snapshot? {
        snapshots[Self.providerID(for: agentID)]
    }

    func primaryGauge(for agentID: String) -> Gauge? {
        snapshot(for: agentID)?.gauges.first
    }
}
