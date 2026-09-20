import Foundation

/// Which agents get a menu bar item on a fresh install.
///
/// The default used to be a fixed list — claude-code, codex, cursor — written
/// when those were the only three. On a Mac running Copilot and Zed it opened
/// to two items that could never report anything and no item for the agent the
/// user actually had. This replaces the guess with evidence: an agent earns a
/// slot when it is signed in here, or has left sessions on this Mac.
///
/// It runs once, on the first launch that finds no choice recorded. After that
/// `enabledAgents` is the user's, and detection never rewrites it — an agent
/// switched off on purpose stays off however plainly it is installed. The
/// Settings sheet offers an explicit re-run for the case where that is wanted.
enum AgentAutoEnable {

    /// What this Mac says about one agent.
    ///
    /// Both fields are cheap by contract: `signedIn` is `UsageProvider`'s
    /// `isConfigured`, and `hasSessions` is a file existence check.
    struct Evidence: Equatable {
        let id: String
        /// A credential for this agent exists here.
        let signedIn: Bool
        /// This agent has left a session store here.
        let hasSessions: Bool

        var present: Bool { signedIn || hasSessions }
    }

    /// The set to enable, given what was found. Pure, so the policy is testable
    /// without a Mac that has any particular agent installed on it.
    ///
    /// `fallback` is consulted only when nothing at all was detected: a menu
    /// bar with no items leaves no way back into the app, so the first
    /// registered provider is shown, exactly as `ProviderRegistry.enabled`
    /// already guarantees at render time.
    static func resolve(_ evidence: [Evidence], fallback: [String]) -> Set<String> {
        let found = evidence.filter(\.present).map(\.id)
        if !found.isEmpty { return Set(found) }
        return Set(fallback.prefix(1))
    }

    /// Reads the machine. Kept separate from `resolve` so the policy above has
    /// no I/O in it.
    static func evidence(providers: [UsageProvider],
                         sessionsPresent: Set<String>) -> [Evidence] {
        providers.map {
            Evidence(id: $0.id,
                     signedIn: $0.isConfigured,
                     hasSessions: sessionsPresent.contains($0.id))
        }
    }

    /// Agents with a session store on disk, whatever their quota situation.
    static func sessionsPresent() -> Set<String> {
        Set(Onboarding.harnesses().filter(\.found).map(\.id))
    }

    /// True while the user has never expressed a preference. A written
    /// `enabledAgents` — including one this very function wrote — settles it.
    static var isUnconfigured: Bool { Config.strings("enabledAgents") == nil }

    /// First launch only. Returns what it chose, or nil when it declined to
    /// act because a choice already exists.
    @discardableResult
    static func applyIfNeeded(providers: [UsageProvider]) -> Set<String>? {
        guard isUnconfigured, !providers.isEmpty else { return nil }
        return apply(providers: providers)
    }

    /// Re-runs detection over the user's existing choice. Only ever called
    /// from an explicit action in Settings.
    @discardableResult
    static func apply(providers: [UsageProvider]) -> Set<String>? {
        guard !providers.isEmpty else { return nil }
        let chosen = resolve(evidence(providers: providers,
                                      sessionsPresent: sessionsPresent()),
                             fallback: providers.map(\.id))
        guard !chosen.isEmpty else { return nil }
        Settings.enabledAgents = chosen
        return chosen
    }
}
