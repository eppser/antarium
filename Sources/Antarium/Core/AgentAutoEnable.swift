import Foundation

/// Which agents get a menu bar item on a fresh install.
///
/// The default used to be a fixed list — claude-code, codex, cursor — written
/// when those were the only three. On a Mac running Copilot and Zed it opened
/// to two items that could never report anything and no item for the agent the
/// user actually had. This replaces the guess with evidence: an agent earns a
/// slot when it is signed in here, or has left sessions on this Mac.
///
/// At most `limit` are switched on, strongest evidence first — ten providers
/// ship now, and a Mac with traces of eight of them should not open to eight
/// menu bar items. Settings lists every one of them for adding the rest.
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

        /// How strong the case for a menu bar slot is. An agent that is both
        /// signed in and used here is the clearest; a credential with no
        /// sessions is next; sessions with no credential last, since that item
        /// can only say "sign in" until the user does something about it.
        var strength: Int {
            switch (signedIn, hasSessions) {
            case (true, true):  return 3
            case (true, false): return 2
            case (false, true): return 1
            case (false, false): return 0
            }
        }
    }

    /// How many agents a first run will switch on.
    ///
    /// Every agent with any evidence used to qualify, which was fine at three
    /// providers and is not at ten: a developer's Mac can easily show traces
    /// of eight, and eight menu bar items is not a default anybody wants. The
    /// strongest evidence wins the slots, and Settings lists every provider
    /// for the user to add the rest.
    static let limit = 4

    /// The set to enable, given what was found. Pure, so the policy is testable
    /// without a Mac that has any particular agent installed on it.
    ///
    /// `fallback` is consulted only when nothing at all was detected: a menu
    /// bar with no items leaves no way back into the app, so the first
    /// registered provider is shown, exactly as `ProviderRegistry.enabled`
    /// already guarantees at render time.
    static func resolve(_ evidence: [Evidence], fallback: [String]) -> Set<String> {
        // Ties break on id so two Macs with the same agents installed get the
        // same bar, rather than whatever order the registry happened to build.
        let ranked = evidence
            .filter(\.present)
            .sorted { ($0.strength, $1.id) > ($1.strength, $0.id) }
            .prefix(limit)
            .map(\.id)
        if !ranked.isEmpty { return Set(ranked) }
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

    /// The whole first-run decision as one pure function, so "a recorded
    /// choice is never overwritten" is a property with a test rather than a
    /// promise spread across a guard and a call site.
    ///
    /// Returns nil to mean *write nothing*: either a choice already exists, or
    /// there is no provider to choose from.
    static func decision(recorded: [String]?, evidence: [Evidence],
                         fallback: [String]) -> Set<String>? {
        guard recorded == nil, !fallback.isEmpty else { return nil }
        let chosen = resolve(evidence, fallback: fallback)
        return chosen.isEmpty ? nil : chosen
    }

    /// First launch only. Returns what it chose, or nil when it declined to
    /// act because a choice already exists.
    @discardableResult
    static func applyIfNeeded(providers: [UsageProvider]) -> Set<String>? {
        guard !providers.isEmpty else { return nil }
        guard let chosen = decision(
            recorded: Config.strings("enabledAgents"),
            evidence: evidence(providers: providers, sessionsPresent: sessionsPresent()),
            fallback: providers.map(\.id)) else { return nil }
        Settings.enabledAgents = chosen
        known = Set(providers.map(\.id))
        return chosen
    }

    /// Provider ids this install has already put in front of the user, so a
    /// provider that ships later can be told apart from one they turned off.
    static var known: Set<String> {
        get { Set(Config.strings("knownAgents") ?? []) }
        set { Config.set("knownAgents", Array(newValue).sorted()) }
    }

    /// Adopts providers that did not exist when the user last chose.
    ///
    /// "Never overwrite a recorded choice" is the rule, and it does not cover
    /// this case: an agent that shipped after the user made their choice is
    /// one they have never been asked about. Seven providers were added at
    /// once here, and an existing install would otherwise have carried on
    /// showing the same three menu bar items with no sign that a fourth was
    /// signed in and ready.
    ///
    /// Only a signed-in provider is adopted. Sessions alone are not enough —
    /// that item could only say "sign in", which is a worse thing to add
    /// unasked than nothing. The bar's cap is respected, so adopting cannot
    /// turn three items into ten.
    ///
    /// An install that has never recorded `knownAgents` records the current
    /// list and adopts nothing, because it cannot tell new from rejected.
    @discardableResult
    static func adoptNewProviders(providers: [UsageProvider]) -> Set<String> {
        guard !providers.isEmpty else { return [] }
        let all = Set(providers.map(\.id))
        let seen = known
        defer { known = seen.union(all) }
        guard !seen.isEmpty else { return [] }

        var enabled = Settings.enabledAgents
        guard enabled.count < limit else { return [] }
        var adopted: Set<String> = []
        for provider in providers.sorted(by: { $0.id < $1.id })
        where !seen.contains(provider.id) && !enabled.contains(provider.id) {
            guard enabled.count < limit else { break }
            guard provider.isConfigured else { continue }
            enabled.insert(provider.id)
            adopted.insert(provider.id)
        }
        if !adopted.isEmpty { Settings.enabledAgents = enabled }
        return adopted
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
        known = Set(providers.map(\.id))
        return chosen
    }
}
