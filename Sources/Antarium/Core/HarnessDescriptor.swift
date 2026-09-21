import Foundation
import AntariumHarnessSDK

/// A coding agent described by data rather than code.
///
/// Most harnesses keep the same shape: a place where sessions live, a way to
/// tell which project a session belongs to, and some field names for the model
/// and token counts. Describing that in JSON means a new harness is a file, not
/// a Swift provider — and the built-in ones are readable examples.
///
/// Startup seeds managed defaults from the app bundle. The user directory is
/// authoritative; duplicate IDs are reported rather than silently overriding.
struct HarnessDescriptor: Codable {
    var formatVersion: Int?
    /// Stable key, also the glyph name in Resources/marks.
    let id: String
    let name: String
    /// Executable-path fragments that identify a running process. Paths, not
    /// process names — Claude Code's binary is called "2.1.241".
    let match: [String]
    /// Exact process names, for harnesses that run under an interpreter.
    private var matchProcessName: [String]?
    private var process: ProcessRule?
    var processNames: [String] {
        Array(Set((matchProcessName ?? []) + (process?.names ?? []))).sorted()
    }

    struct ProcessRule: Codable {
        enum SessionBinding: String, Codable { case openSourceFile }

        /// A synthetic process observation tied to documented installation
        /// evidence. Probes are evaluated by diagnostics and tests through the
        /// production matcher; they never cause a process to be claimed.
        struct InstallationProbe: Codable {
            let method: String
            let path: String
            let name: String
            let argv0: String
            let expected: Bool
            let evidence: String
            let verifiedAt: String
        }

        var pathContains: [String]?
        var names: [String]?
        var argv0Contains: [String]?
        var sessionBinding: SessionBinding?
        var installationProbes: [InstallationProbe]?
    }

    var processRule: ProcessRule {
        ProcessRule(pathContains: Array(Set(match + (process?.pathContains ?? []))).sorted(),
                    names: processNames,
                    argv0Contains: process?.argv0Contains ?? [],
                    sessionBinding: process?.sessionBinding,
                    installationProbes: process?.installationProbes)
    }

    /// True when this descriptor claims a process — by executable path, by
    /// process name, or by argv[0] for anything running under an interpreter.
    func claims(_ process: Processes.Info) -> Bool {
        let rule = processRule
        if (rule.pathContains ?? []).contains(where: { process.path.contains($0) }) { return true }
        let argv0Base = (process.argv0 as NSString).lastPathComponent
        if processNames.contains(process.name) || processNames.contains(argv0Base) { return true }
        return (rule.argv0Contains ?? []).contains { process.argv0.contains($0) }
    }
    let source: Source
    /// Optional: a SQLite harness maps its columns instead, and omitting this
    /// must not make the whole descriptor undecodable.
    private var map: Map?
    var fields: Map { map ?? Map() }
    /// Seconds of quiet before a session counts as waiting on you.
    /// A GUI app whose working directory says nothing about what it has open —
    /// `/` for Codex Desktop, the home folder for OpenCode. It takes its newest
    /// session rather than being matched by directory. Never set this on a CLI:
    /// a stray process would adopt an unrelated session's numbers.
    private var detached: Bool?
    var isDetached: Bool { detached ?? false }
    /// One app process, many conversations. Without this a detached harness
    /// speaks only for its newest session, which hid every other tab the user
    /// had open.
    private var multiSession: Bool?
    var isMultiSession: Bool { multiSession ?? false }
    /// Report only conversations the app still has open. Understood for
    /// OpenCode, whose database records nothing about a tab being closed; see
    /// `OpenCodeTabs`. Ignored elsewhere.
    private var openTabsOnly: Bool?
    var wantsOpenTabsOnly: Bool { openTabsOnly ?? false }

    private var selection: Selection?
    var sessionSelection: Selection? { selection }

    struct Selection: Codable {
        enum Kind: String, Codable { case jsonFiles, sqlite, command }

        let kind: Kind
        var path: String?
        var glob: String?
        /// Path to an array in each state file.
        var records: String?
        private var encodedJSON: Bool?
        var decodesEmbeddedJSON: Bool { encodedJSON ?? false }
        /// Field holding the session identifier.
        var id: String?
        /// Every declared field must equal one of its accepted values.
        var filter: [String: [String]]?
        var query: String?
        var column: String?
        var command: String?
        var args: [String]?
        var root: String?

        init(kind: Kind, path: String, glob: String, records: String,
             encodedJSON: Bool = false, id: String,
             filter: [String: [String]]? = nil) {
            self.kind = kind
            self.path = path
            self.glob = glob
            self.records = records
            self.encodedJSON = encodedJSON
            self.id = id
            self.filter = filter
        }
    }

    /// How to read this agent's remaining quota, when it exposes one. Optional:
    /// most harnesses report sessions and nothing else.
    var quota: Quota?

    /// Project context this harness understands. Paths are data; Swift only
    /// performs the declared probe. Unknown or omitted kinds remain absent
    /// instead of borrowing another agent's conventions.
    private var capabilities: [String: CapabilityRule]?
    var capabilityRules: [String: CapabilityRule] { capabilities ?? [:] }

    struct CapabilityRule: Codable {
        enum Probe: String, Codable {
            /// A non-empty file, or a non-empty directory.
            case content
            /// A directory with at least one entry.
            case directory
            /// A JSON file with a non-empty object at one of the declared keys.
            case jsonObject
            /// A TOML file declaring one of the named keys or table prefixes.
            case toml
        }

        var probe: Probe?
        /// Relative paths are resolved from the session's working directory.
        var project: [String]?
        /// Usually tilde paths, resolved independently of the project.
        var inherited: [String]?
        /// For a directory probe, reveal this file when present and count the
        /// directory's other entries. Useful for a memory index.
        var index: String?
        /// Candidate object keys, TOML keys, or TOML table prefixes.
        var keys: [String]?
        /// When a path is a directory: only entries whose names end with one
        /// of these count.
        ///
        /// Some conventions are a folder where the agent reads one kind of
        /// file and ignores the rest — Cursor reads `.cursor/rules/*.mdc` and
        /// states that a plain `.md` there is ignored, and Copilot's scoped
        /// instructions must end `.instructions.md`. Counting every entry
        /// would report the capability for a folder the agent never reads.
        ///
        /// Suffixes rather than extensions, because `.instructions.md` is not
        /// an extension: the path extension of `style.instructions.md` is
        /// `md`, which would not tell it from a file Copilot ignores.
        var fileSuffixes: [String]?

        var resolvedProbe: Probe { probe ?? .content }
        var projectPaths: [String] { project ?? [] }
        var inheritedPaths: [String] { inherited ?? [] }
        var objectKeys: [String] { keys ?? [] }
        var countedSuffixes: [String] { fileSuffixes ?? [] }
    }

    struct Quota: Codable {
        /// Where the bearer token lives. Omitted for an endpoint needing none.
        struct Credential: Codable {
            /// `jsonFile` — read `field` out of a JSON file.
            /// `textFile` — the whole file is the token.
            /// `env`      — an environment variable named by `name`, and
            ///              then the file at `path` when that is unset. The
            ///              fallback is not optional decoration: an app
            ///              launched from Finder inherits the launchd session
            ///              environment rather than a shell's, so a variable
            ///              exported in a shell profile is invisible to it.
            /// `command`  — run `command` with `args`; its output is the token.
            ///              A menu bar app launched from Finder inherits no
            ///              shell environment, so `gh auth token` reaches a
            ///              credential that `env` cannot.
            let kind: String
            var path: String?
            var field: String?
            var name: String?
            var command: String?
            var args: [String]?
            /// Other fields in the same file that must hold for this token to
            /// belong to this vendor, as field path → required substring
            /// (compared case-insensitively).
            ///
            /// Needed when the credential lives somewhere shared. Z.ai's plan
            /// is driven through Claude Code, so its token is whatever sits in
            /// `env.ANTHROPIC_AUTH_TOKEN` — a field Kimi, MiniMax, a corporate
            /// gateway and a plain Anthropic key all use too. Without a second
            /// field to check, any of those reads as a Z.ai sign-in and gets
            /// sent to Z.ai's endpoint. `jsonFile` only; the validator rejects
            /// it elsewhere, because a guard that silently does nothing is
            /// worse than no guard.
            var requires: [String: String]?
        }
        /// Where the windows live in the response, and what each field is called.
        struct Windows: Codable {
            /// Dot-path to the object holding the windows.
            var root: String?
            /// Candidate paths, tried in order, for a service that sometimes
            /// wraps its payload in an envelope and sometimes does not —
            /// Command Code returns `windowLimits` at the top level or under
            /// `data` depending on the call. Guessing one would make the
            /// gauges silently vanish on the other shape. `root` is the
            /// single-candidate shorthand; giving both tries `roots` first.
            var roots: [String]?
            /// Dot-path to an *array* of windows, for the services that report
            /// one — Z.ai's `data.limits`, MiniMax's `model_remains`. A list
            /// has no member names of its own, so `key` says which field
            /// inside each element names it. Supersedes `root` when both are
            /// given.
            var list: String?
            /// Field paths inside each list element that name that window.
            /// Several are joined with "-" where one alone is ambiguous: Z.ai
            /// reports two `TOKENS_LIMIT` rows and distinguishes them only by
            /// `unit`, so keying on `type` alone silently collapses the weekly
            /// cap into the session one. Without any key the elements are
            /// numbered, which reads badly in a menu.
            var key: [String]?
            /// Which members are windows. Omit to take all of them. For an
            /// object this also fixes their order; for a list the response's
            /// own order is kept.
            var keys: [String]?
            /// 0–100. Some APIs report what is left instead of what is spent;
            /// give `percentRemaining` for those rather than making the author
            /// do arithmetic a config file cannot express.
            var usedPercent: String?
            var percentRemaining: String?
            /// Path to a credit balance: a figure with no denominator. A
            /// window mapped this way draws its amount and no bar, because a
            /// balance cannot honestly be a percentage of anything.
            var balance: String?
            /// Currency of `balance`. A path into the window when the service
            /// states one, otherwise a literal code such as "USD". Assuming
            /// dollars would misreport a CNY balance by an exchange rate.
            var currency: String?
            /// Names the container itself as one window, for the flat
            /// responses that have no per-window object at all — Vercel's
            /// credits endpoint is `{"balance": …}` and nothing more.
            var single: String?
            /// Some APIs report counts rather than a percentage. Give both and
            /// the ratio is worked out — a window whose limit is missing is
            /// skipped, because "0 of nothing" is not 0%.
            var used: String?
            var limit: String?
            /// Windows to skip unless every pair matches — Copilot lists a
            /// premium tier that a free plan simply does not have.
            var require: [String: Bool]?
            /// What to call each window. Without it the badge is the first
            /// letters of the key, which reads as "CHA" and "COM".
            var labels: [String: String]?
            /// What to *draw* for each window, when the label is too long to
            /// abbreviate well. A label is truncated to three letters for the
            /// menu bar, which turns "Premium" into "PRE" and "Tools" into
            /// "TOO"; naming the badge outright avoids inventing a word.
            var badges: [String: String]?
            var windowSeconds: String?
            var resetsAt: String?
            var title: String?
        }
        /// An https URL to read the figures from. Optional because some
        /// services no longer offer one.
        var endpoint: String?
        /// A command to read the figures from instead, as argv. Its stdout
        /// must be the JSON the `windows` map describes.
        ///
        /// Some agents have stopped answering over HTTP at all. Antigravity's
        /// embedded server began rejecting every tokenless request once its
        /// CLI stopped publishing the CSRF token it generates, and the
        /// working path became `agy -p /usage --output-format json`. A model
        /// that can only describe an endpoint cannot describe that, so an
        /// agent whose mapping is perfectly expressible still needed native
        /// code — which is the opposite of what this file is for.
        ///
        /// Run through `Shell.execute` like every other harness command:
        /// argv, never a shell, bounded in time and output, and listed in the
        /// allowlist test beside the rest.
        var command: String?
        var args: [String]?
        var headers: [String: String]?
        var credential: Credential?
        let windows: Windows
        var accountLabel: String?
        var setupHint: String?
        /// Shell command that signs this agent in again, offered in the menu
        /// when the credential is what failed.
        var signInCommand: String?
        /// Whether these numbers have been checked against the real service.
        /// Unverified providers say so rather than quietly showing figures
        /// nobody has confirmed.
        var verified: Bool?
    }

    var idleAfter: Double?
    /// How long a detached harness's newest session may go untouched before it
    /// stops counting as someone's work. Only meaningful with `detached`.
    var staleAfter: Double?
    /// Shown instead of the project when a session has no directory.
    var fallbackName: String?
    /// Free text for whoever reads the file. Ignored by the app, but declared
    /// so `--check` doesn't flag it as a typo.
    var note: String?
    /// Set false to switch a harness off without deleting the file — deleting
    /// it only brings the shipped version back on the next start.
    private var enabled: Bool?
    var isEnabled: Bool { enabled ?? true }
    /// Which bundled mark to draw. Defaults to the harness id, so a harness
    /// that shares a product's icon can say so instead of needing code.
    var mark: String?
    var presentation: Presentation?

    /// How to bring one of this harness's sessions to the front.
    ///
    /// A tmux pane is focused by attaching to it, and a desktop app by raising
    /// it — both of which Antarium knows how to do. A workspace manager that
    /// owns its own panes knows neither: Herdr focuses a tab through its
    /// socket API, Orca switches terminals through its CLI. Both publish a
    /// command for it, so the command is configuration and running it is not.
    ///
    /// `{focusTarget}` in an argument is replaced with the session's
    /// `map.focusTarget` value. Nothing else is substituted, and the command
    /// is executed directly rather than through a shell.
    struct Focus: Codable {
        let command: String
        var args: [String]?
    }

    var focus: Focus?

    /// What this harness contributes to the picture.
    ///
    /// A workspace manager hosts other agents rather than being one. Herdr and
    /// Orca each report their panes, and every pane is already a row from the
    /// agent's own harness — the Claude session in a Herdr pane is the same
    /// conversation Claude Code reports. Emitting both shows every agent
    /// twice, once with its real figures and once as an empty duplicate.
    ///
    /// `focus` means: read these records, use them to say how each session is
    /// raised, and make no rows of your own.
    /// `presence` is for an agent that keeps no durable session record.
    /// Gemini CLI writes a project marker and nothing else — no transcript, no
    /// token counts, no cost — so the running process is the only evidence
    /// there is. A row for it says the agent is working in a directory and
    /// leaves every figure absent, which is the truth; omitting it entirely
    /// would say the opposite.
    enum Contribution: String, Codable { case sessions, focus, presence }
    var contributes: Contribution?
    var contributesFocusOnly: Bool { contributes == .focus }
    /// Rows come from the process table alone; no source is read.
    var contributesPresenceOnly: Bool { contributes == .presence }

    struct Presentation: Codable {
        var mark: String?
        var fallbackName: String?
        var sourceLabel: String?
    }

    var resolvedMark: String? { presentation?.mark ?? mark }
    var resolvedFallbackName: String? { presentation?.fallbackName ?? fallbackName }

    var compatibility: Compatibility?

    struct Compatibility: Codable {
        enum Level: String, Codable {
            case experimental, declared, fixtureVerified, liveVerified
        }
        let level: Level
        var verifiedAt: String?
        var agentVersions: [String]?
        var fixture: String?
        var note: String?
    }

    struct Source: Codable {
        /// jsonl — one record per line; json — one object; sqlite — one query.
        let kind: Kind
        /// Directory holding sessions (jsonl/json), or the database file.
        let path: String
        /// True for an append-only journal of snapshot-plus-patches, folded
        /// back into one document before mapping. See `Journal`.
        var journal: Bool?
        /// Shell-style glob under `path`, e.g. "*/*.jsonl". jsonl/json only.
        var glob: String?
        /// Maximum newest files to parse. Defaults to 40; a single-window app
        /// can set one without baking product-specific shortcuts into Swift.
        var limit: Int?
        /// String fields derived from the source file's location when records
        /// do not repeat that metadata. `ancestor` is zero for the file, one
        /// for its parent, and so on; `value` chooses name, stem, or full path.
        var pathFields: [String: PathField]?

        struct PathField: Codable {
            enum Value: String, Codable { case name, stem, path }
            let ancestor: Int
            let value: Value
        }
        /// Extra directories a reader needs beyond `path`. Claude's transcripts
        /// live in a different tree from its session registry, and both should
        /// be fixable in the file if Claude ever moves them.
        var paths: [String: String]?
        /// sqlite only. Newest session first, LIMIT 1.
        var query: String?
        /// sqlite only: what each selected column means.
        var columns: [String]?
        /// Keeps only sessions where some record matches every pair, each
        /// naming the values it accepts. One harness's sessions can otherwise
        /// look identical to another's — Codex writes the CLI's and the
        /// desktop app's into the same directory.
        var filter: [String: [String]]?
        /// A sibling file holding what the session records don't — commonly the
        /// working directory, when the transcript itself never names it. Its
        /// path is relative to the session file.
        var manifest: Manifest?

        struct Manifest: Codable {
            let file: String
            let map: Map
        }

        /// command only: the executable to run, and its arguments. Its stdout
        /// must be JSON. This is how an agent that already ships a status CLI
        /// — `claude agents --json`, and anything shaped like it — becomes a
        /// config file rather than a reader someone has to write in Swift.
        var command: String?
        var args: [String]?
        /// Dot-path to the array of sessions, when the JSON isn't already one.
        var root: String?
        /// How often to run it. Commands cost far more than reading a file, so
        /// they are not run on every scan.
        var refreshEvery: Double?

        /// `none` — this descriptor contributes no sessions. For a config file
        /// that exists only to add a quota bar.
        enum Kind: String, Codable { case jsonl, json, sqlite, command, none }
    }

    /// Dot-separated key paths into a record, e.g. "message.usage.input".
    /// Every entry is optional — a harness that records nothing shows nothing
    /// rather than showing a guess.
    struct Map: Codable {
        var cwd: String?
        /// Path to whatever `focus.command` needs to raise this session.
        var focusTarget: String?
        var contextWindow: String?
        /// What the harness says is currently in the context, as one or more
        /// fields summed. The newest record wins — unlike the token counts,
        /// which accumulate, a context size is measured, not added up.
        var contextTokens: [String]?
        var model: String?
        var timestamp: String?
        var inputTokens: String?
        var outputTokens: String?
        var cacheRead: String?
        /// True when `inputTokens` already counts the cached part, so it is not
        /// added a second time when working out what was actually uploaded.
        var inputIncludesCacheRead: Bool?
        var cacheWrite: String?
        var cost: String?
        var title: String?
        /// Substring that marks a tool call, counted per record.
        var toolMarker: String?
        /// One tool call when every field equals the configured value.
        var toolWhere: [String: String]?
        /// Tool calls stored as entries in a nested array/object.
        var toolCalls: Count?
        /// Records to count as conversation turns, e.g. {"type": "message"}.
        var turnWhere: [String: String]?
        /// Where working/waiting is recorded, when the harness says so.
        var status: Status?
        /// The harness's own id for this session, used to match it against
        /// state held elsewhere — Codex keeps its goals in a separate database
        /// keyed by thread id.
        var sessionID: String?
        /// The process this session belongs to. When a source names it, the
        /// session binds to that pid directly instead of being matched to a
        /// process by working directory.
        var pid: String?
        /// A nested collection counted as conversation turns — VS Code keeps
        /// its whole chat in one record with a `requests` array.
        var turns: Count?
        /// A nested collection counted as sub-agents, e.g. the entries of
        /// `agents` whose `type` is "sub".
        var subAgents: Count?

        struct Count: Codable {
            let path: String
            private var match: [String: String]?
            var filter: [String: String] { match ?? [:] }

            init(path: String) { self.path = path; self.match = nil }
        }

        struct Status: Codable {
            /// Working for as long as this collection has anything in it.
            ///
            /// VS Code parks an in-flight request in `pendingRequests` and
            /// clears it when the answer lands, which is a statement of fact
            /// rather than the timestamp guesswork that had these harnesses
            /// reading "Waiting" while they worked.
            var whileNotEmpty: String?
            /// Optional: a status published as a value. Omit it when the
            /// state is told by `whileNotEmpty` instead.
            var field: String?
            private var working: [String]?
            private var idle: [String]?
            var workingValues: [String] { working ?? [] }
            var idleValues: [String] { idle ?? [] }
        }
    }

    // MARK: - Loading

    static var directory: URL {
        Config.directory.appendingPathComponent("harnesses")
    }

    private static let catalog = HarnessCatalog(directory:directory,defaults:bundled(),
        schema:AppResources.bundle.url(forResource:"harness.schema",withExtension:"json"),readme:readme)

    /// Read-only, bounded and cached; startup explicitly seeds shipped defaults.
    static func all() -> [HarnessDescriptor] { catalog.snapshot().enabled }
    /// Both are derived once when the catalog changes, not per caller: the
    /// process scan asks for them once per process.
    static func matchFragments() -> [String] { catalog.snapshot().matchFragments }
    static func processNamesAll() -> Set<String> { catalog.snapshot().processNames }
    static func reload() { catalog.invalidate() }

    /// Puts the shipped harnesses in your folder, and keeps them current.
    ///
    /// They are *yours* once written — this is the only copy, and it is what the
    /// app reads. But agents change: Codex renamed `function_call` to
    /// `custom_tool_call`, and a fix nobody receives is not a fix. So a file
    /// that still matches what we wrote is updated in place when the app ships
    /// a newer version of it, and a file you have edited is never touched.
    ///
    /// `.seed.json` records the checksum of what we last wrote, which is how
    /// "untouched" is decided. Delete a file and it comes back; edit it and it
    /// is yours for good.
    @discardableResult
    static func seed(in targetDirectory:URL = directory, sources:[URL]? = nil) -> HarnessSeed.Result {
        let result = targetDirectory == directory && sources == nil
            ? catalog.seed()
            : HarnessSeed.run(directory:targetDirectory,sources:sources ?? bundled(),
                schema:AppResources.bundle.url(forResource:"harness.schema",withExtension:"json"),readme:readme)
        if targetDirectory == directory, !result.added.isEmpty || !result.updated.isEmpty {
            Log.info("harness", "Default files added: \(result.added.count); updated: \(result.updated.count); user-owned: \(result.keptYours.count).")
        }
        return result
    }

    private static let readme = """
        These are Antarium's harnesses — one file per agent. This folder is the
        only copy: Antarium reads it at every start.

        Edit any of them, or add your own. Once you change a file, Antarium
        stops updating it and it is yours. Files you have not touched are kept
        current, so when an agent changes its format the fix reaches you.

        Delete a file to get the shipped version back on the next start.

        Check your work before restarting:

            /Applications/Antarium.app/Contents/MacOS/Antarium --check <file>

        It reports typos, field paths that match nothing in your real data, and
        what it would show.

        harness.schema.json next to this folder is the authority on the format,
        and most editors will use it for completion and validation. The fields
        are explained in docs/TECHNICAL.md under "Harness files".

        """

    /// Whether a harness file differs from the one we shipped. Every file lives
    /// in the user's folder now, so "is it in that folder?" no longer answers
    /// "did they write it?" — the seed manifest does.
    static func isEdited(_ id: String) -> Bool {
        let file = directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: file) else { return false }
        guard let manifest = try? Data(contentsOf: directory.appendingPathComponent(".seed.json")),
              let seeded = try? JSONSerialization.jsonObject(with: manifest) as? [String: String],
              let recorded = seeded["\(id).json"]
        else { return true }                       // never shipped: entirely theirs
        return recorded != HarnessSeed.checksum(data)
    }

    /// Visible configuration degradation, independent of retained descriptors.
    static var failures: [String] { catalog.issues }

    private static func bundled() -> [URL] {
        AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
    }


}

extension String {
    /// Expands a leading `~` so descriptors can be written the way people think.
    var expandingTilde: String {
        hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + dropFirst()
            : self
    }
}
