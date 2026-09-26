import Foundation

/// Which agents get a menu bar item on a fresh install.
///
/// The default used to be a fixed list — claude-code, codex, cursor — written
/// when those were the only three. On a Mac running Copilot and Zed it opened
/// to two items that could never report anything and no item for the agent the
/// user actually had. This replaces the guess with evidence: an agent earns a
/// slot when it is signed in here, or has left sessions on this Mac.
///
/// At most `limit` are switched on, strongest evidence first — eighteen providers
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
    ///
    /// Asking each provider whether it is signed in is the only I/O; the
    /// tuple form below is what everything else is written against, so the
    /// join between the two halves of the evidence is arithmetic rather than
    /// something only a real Mac can perform.
    static func evidence(providers: [UsageProvider],
                         sessionsPresent: Set<String>) -> [Evidence] {
        evidence(providers: providers.map { ($0.id, $0.isConfigured) },
                 sessionsPresent: sessionsPresent)
    }

    static func evidence(providers: [(id: String, signedIn: Bool)],
                         sessionsPresent: Set<String>) -> [Evidence] {
        providers.map {
            Evidence(id: $0.id,
                     signedIn: $0.signedIn,
                     hasSessions: sessionsPresent.contains($0.id))
        }
    }

    /// Agents with a session store on disk, whatever their quota situation.
    ///
    /// The catalogue is a parameter so this can be asked about a machine that
    /// is not this one. Without it the only way to check that detection feeds
    /// the first run was to install an agent and look, and replacing the
    /// whole of this with an empty set failed no test: every provider the
    /// developer's Mac enables is also signed in, so the sessions half of the
    /// evidence never decided anything here.
    static func sessionsPresent(_ descriptors: [HarnessDescriptor]
                                    = HarnessDescriptor.all()) -> Set<String> {
        Set(Onboarding.harnesses(descriptors).filter(\.found).map(\.id))
    }

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

    /// What a first launch should record, given what it found.
    ///
    /// Both halves or neither. `known` is what lets a later launch tell an
    /// agent that shipped since from one the user turned off — so a first run
    /// that chooses without recording would disable adoption for ever, and
    /// nothing about the bar it produced would look wrong.
    static func firstRunRecord(recorded: [String]?, evidence: [Evidence],
                               fallback: [String])
        -> (enabled: Set<String>, known: Set<String>)? {
        guard let chosen = decision(recorded: recorded, evidence: evidence,
                                    fallback: fallback) else { return nil }
        return (chosen, Set(evidence.map(\.id)))
    }

    /// The same record, from what the machine reported rather than from
    /// evidence somebody else assembled.
    ///
    /// Building the evidence used to happen inside `applyIfNeeded`, in among
    /// the two settings writes, where nothing could reach it: discarding the
    /// session set it was handed changed nothing any suite could see. That
    /// line needs a Mac with an agent used but not signed in to matter, and a
    /// synthetic home cannot be one — seeding always writes the bundled
    /// catalogue, and the providers read the real credentials. In here it is
    /// arithmetic, and the test below is about the machine rather than about
    /// this one.
    static func firstRunRecord(recorded: [String]?,
                               providers: [(id: String, signedIn: Bool)],
                               sessions: Set<String>)
        -> (enabled: Set<String>, known: Set<String>)? {
        guard !providers.isEmpty else { return nil }
        return firstRunRecord(
            recorded: recorded,
            evidence: evidence(providers: providers, sessionsPresent: sessions),
            fallback: providers.map(\.id))
    }

    /// First launch only. Returns what it chose, or nil when it declined to
    /// act because a choice already exists.
    ///
    /// Two writes and nothing else. Everything it decides is decided above.
    @discardableResult
    static func applyIfNeeded(providers: [UsageProvider],
                              sessions: Set<String> = sessionsPresent()) -> Set<String>? {
        guard let record = firstRunRecord(recorded: Settings.recordedAgents,
                                          providers: providers.map { ($0.id, $0.isConfigured) },
                                          sessions: sessions) else { return nil }
        Settings.enabledAgents = record.enabled
        known = record.known
        return record.enabled
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
    /// The adoption decision, with no I/O in it.
    ///
    /// Separated from the settings it reads and writes because a test that
    /// reimplements this rule proves only that the test agrees with itself —
    /// which is what the first version of its test did, and why mutating the
    /// signed-in requirement in the real function changed nothing.
    static func adoptions(known seen: Set<String>, enabled: Set<String>,
                          providers: [(id: String, signedIn: Bool)]) -> Set<String> {
        // Nothing recorded means new and rejected cannot be told apart.
        guard !seen.isEmpty else { return [] }
        var room = limit - enabled.count
        guard room > 0 else { return [] }
        var adopted: Set<String> = []
        for provider in providers.sorted(by: { $0.id < $1.id })
        where !seen.contains(provider.id) && !enabled.contains(provider.id) {
            guard room > 0 else { break }
            // Sessions alone are not enough: that item could only say
            // "sign in", which is worse to add unasked than nothing.
            guard provider.signedIn else { continue }
            adopted.insert(provider.id)
            room -= 1
        }
        return adopted
    }

    /// What one later launch should record. Again both halves together: the
    /// `known` set has to grow whether anything was adopted or not, or a
    /// provider stays "new" for ever and comes back every launch after the
    /// user switches it off.
    static func adoptionRecord(known seen: Set<String>, enabled: Set<String>,
                               providers: [(id: String, signedIn: Bool)])
        -> (adopted: Set<String>, known: Set<String>) {
        (adoptions(known: seen, enabled: enabled, providers: providers),
         seen.union(Set(providers.map(\.id))))
    }

    @discardableResult
    static func adoptNewProviders(providers: [UsageProvider]) -> Set<String> {
        guard !providers.isEmpty else { return [] }
        let enabled = Settings.enabledAgents
        let record = adoptionRecord(known: known, enabled: enabled,
                                    providers: providers.map { ($0.id, $0.isConfigured) })
        if !record.adopted.isEmpty { Settings.enabledAgents = enabled.union(record.adopted) }
        known = record.known
        return record.adopted
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
