import Foundation

/// How much each menu bar item shows. One setting, applied to every agent, so
/// the row of items reads as one instrument rather than three.
/// Whether the gauge reports consumption or headroom.
///
/// Both readings come from the same figure; only the framing differs. "Used"
/// matches how people describe quota out loud ("I'm at 25% this week"), so it
/// is the default. Colour always tracks headroom either way: green means room
/// left, red means nearly out.
enum MeterMode: String, CaseIterable {
    case used, remaining

    var title: String { self == .used ? "Used" : "Remaining" }
    var subtitle: String {
        self == .used ? "Bar fills as you consume quota"
                      : "Bar drains as you consume quota, like a battery"
    }
}

/// Thin, typed wrapper over the JSON config file. No observers, no Combine.
enum Settings {

    /// Which agents get a menu bar item, in registry order.
    ///
    /// Empty when nothing has been recorded, and deliberately so. The default
    /// used to be `["claude-code", "codex", "cursor"]` — the fixed list
    /// `AgentAutoEnable` exists to replace — which made this property and
    /// a separate `AgentAutoEnable.isUnconfigured` disagreed about whether the user had
    /// chosen anything: one said three agents, the other said none, and both
    /// were right by their own rule. On a Mac with none of those three
    /// installed it also put back exactly the symptom detection was written
    /// to fix, in the one state where detection had not run.
    ///
    /// Nothing has to stand in here, because `ProviderRegistry.shown` already
    /// falls back to the first provider when the choice names nothing that
    /// exists — an empty set is that case.
    static var enabledAgents: Set<String> {
        get { agents(recorded: recordedAgents) }
        set { Config.set("enabledAgents", Array(newValue).sorted()) }
    }

    /// The key as written, with "never chosen" kept distinct from "chose
    /// nothing".
    static var recordedAgents: [String]? { Config.strings("enabledAgents") }

    /// What a recorded value means, and whether there is one.
    ///
    /// Both are functions of the recorded value rather than properties
    /// reading the config, because a test of a property can only see the
    /// state the machine running it happens to be in: on a Mac with a choice
    /// recorded, an assertion about the no-choice case asserts nothing, and
    /// putting the old fixed default back changed no test at all.
    ///
    /// Nothing stands in for an absent record. `ProviderRegistry.shown`
    /// already falls back to the first provider when the choice names nothing
    /// that exists, and an empty set is that case — so the default used to be
    /// `["claude-code", "codex", "cursor"]` for no reason, and the reason it
    /// was wrong is that it made this and the flag beside it
    /// answer differently about the same state.
    static func agents(recorded: [String]?) -> Set<String> {
        recorded.map(Set.init) ?? []
    }

    /// True while nobody has chosen. Writing an empty list is a choice.
    ///
    /// The only reading of that question in the app. There was a second, an
    /// `AgentAutoEnable.isUnconfigured` that asked the config directly; it
    /// was deleted rather than pointed here, because the two agreed on every
    /// state this machine could be in and so nothing could hold them
    /// together — the difference showed only for a recorded empty list, and
    /// a test that cannot reach a state does not guard it.
    static func unconfigured(recorded: [String]?) -> Bool { recorded == nil }

    /// Accent preset id, or a `#RRGGBB` string straight from the config file.
    static var accent: String {
        get { Config.string("accent") ?? Accents.ocean.id }
        set { Config.set("accent", newValue) }
    }

    /// Per-row bar colours for the vivid palette.
    static var rowColors: [String] {
        get { Config.strings("rowColors") ?? AgentStyle.defaultRowColors }
        set { Config.set("rowColors", newValue) }
    }

    static var palette: Palette {
        get { Palette(rawValue: Config.string("palette") ?? "") ?? .vivid }
        set { Config.set("palette", newValue.rawValue) }
    }

    static var meterMode: MeterMode {
        get { MeterMode(rawValue: Config.string("meterMode") ?? "") ?? .used }
        set { Config.set("meterMode", newValue.rawValue) }
    }

    static var refreshMinutes: Int {
        get {
            let v = Config.int("refreshMinutes") ?? 10
            return refreshChoices.contains(v) ? v : 10
        }
        set { Config.set("refreshMinutes", newValue) }
    }

    /// Dashboard sort order, remembered across launches.
    static var agentSort: AgentSort {
        get { AgentSort(rawValue: Config.string("agentSort") ?? "") ?? .name }
        set { Config.set("agentSort", newValue.rawValue) }
    }

    /// Extra menu bar item with the AGENTS status counts.
    static var showAgentCount: Bool {
        get { Config.bool("showAgentCount") ?? false }
        set { Config.set("showAgentCount", newValue) }
    }

    /// Reduced agent list: name, status, context, last reply.
    static var agentListCompact: Bool {
        get { Config.bool("agentListCompact") ?? false }
        set { Config.set("agentListCompact", newValue) }
    }

    /// Banner when an agent stops working.
    static var notifyOnIdle: Bool {
        get { Config.bool("notifyOnIdle") ?? false }
        set { Config.set("notifyOnIdle", newValue) }
    }

    /// Where the user dragged the dashboard, if they ever did. Pinning honours
    /// this instead of docking right.
    static var dashboardOrigin: CGPoint? {
        get {
            guard let xy = Config.doubles("dashboardOrigin"), xy.count == 2 else { return nil }
            return CGPoint(x: xy[0], y: xy[1])
        }
        set {
            if let p = newValue { Config.set("dashboardOrigin", [p.x, p.y]) }
            else { Config.set("dashboardOrigin", []) }
        }
    }

    /// Keep the dashboard on screen, docked to the right.
    static var dashboardPinned: Bool {
        get { Config.bool("dashboardPinned") ?? false }
        set { Config.set("dashboardPinned", newValue) }
    }

    /// How often the agent dashboard rescans, in seconds. Deliberately separate
    /// from `refreshMinutes`: quota moves over hours, agent state over seconds.
    static var agentScanSeconds: Int {
        get { min(max(Config.int("agentScanSeconds") ?? 10, 3), 600) }
        set { Config.set("agentScanSeconds", newValue) }
    }

    static let agentScanChoices = [5, 10, 30, 60, 120, 300]

    /// Include Codex cloud tasks in the dashboard.
    static var includeCloudAgents: Bool {
        get { Config.bool("includeCloudAgents") ?? true }
        set { Config.set("includeCloudAgents", newValue) }
    }

    /// Include agents found in tmux on other machines, over SSH.
    static var includeRemoteTmux: Bool {
        get { Config.bool("includeRemoteTmux") ?? false }
        set { Config.set("includeRemoteTmux", newValue) }
    }

    /// The machines to look on, each written exactly as you would type it
    /// after `ssh` — "quibus", "10.0.0.4", "deploy@quibus". That is the whole
    /// configuration: `~/.ssh/config` already holds the port, the key and the
    /// real hostname, and restating any of it here would only be a second
    /// place for it to go stale. A password, when one is needed, is kept in
    /// the Keychain under `RemoteTmux.keychainService` and never written here.
    static var remoteTmuxHosts: [String] {
        get { RemoteTmux.normalizedHosts(Config.strings("remoteTmuxHosts") ?? []) }
        set { Config.set("remoteTmuxHosts", RemoteTmux.normalizedHosts(newValue)) }
    }

    /// Points between the agent mark and the numbers.
    /// Beams per bar. Little Snitch runs around eight; five is the default.
    static var beams: Int {
        get { min(max(Config.int("beams") ?? 5, 3), 12) }
        set { Config.set("beams", newValue) }
    }

    static let refreshChoices = [5, 10, 15, 30, 60]
}
