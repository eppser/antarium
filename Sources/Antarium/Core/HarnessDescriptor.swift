import Foundation

/// A coding agent described by data rather than code.
///
/// Most harnesses keep the same shape: a place where sessions live, a way to
/// tell which project a session belongs to, and some field names for the model
/// and token counts. Describing that in JSON means a new harness is a file, not
/// a Swift provider — and the built-in ones are readable examples.
///
/// Built-ins ship in the app bundle; anything in `~/.antarium/harnesses/*.json`
/// is loaded too and overrides a built-in with the same `id`.
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

        var resolvedProbe: Probe { probe ?? .content }
        var projectPaths: [String] { project ?? [] }
        var inheritedPaths: [String] { inherited ?? [] }
        var objectKeys: [String] { keys ?? [] }
    }

    struct Quota: Codable {
        /// Where the bearer token lives. Omitted for an endpoint needing none.
        struct Credential: Codable {
            /// `jsonFile` — read `field` out of a JSON file.
            /// `textFile` — the whole file is the token.
            /// `env`      — an environment variable named by `name`.
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
        }
        /// Where the windows live in the response, and what each field is called.
        struct Windows: Codable {
            /// Dot-path to the object holding the windows.
            var root: String?
            /// Which members of it are windows. Omit to take all of them.
            var keys: [String]?
            /// 0–100. Some APIs report what is left instead of what is spent;
            /// give `percentRemaining` for those rather than making the author
            /// do arithmetic a config file cannot express.
            var usedPercent: String?
            var percentRemaining: String?
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
            var windowSeconds: String?
            var resetsAt: String?
            var title: String?
        }
        let endpoint: String
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

    nonisolated(unsafe) private static var cached:
        (stamp: String, checked: Date, list: [HarnessDescriptor],
         fragments: [String], names: Set<String>)?
    private static let lock = NSLock()

    /// Cached: the scan asks whether a path belongs to a harness once per
    /// process, and re-reading every descriptor each time meant hundreds of
    /// decodes per pass.
    nonisolated(unsafe) private static var hasSeeded = false

    static func all() -> [HarnessDescriptor] {
        lock.lock()
        let needsSeed = !hasSeeded
        hasSeeded = true
        lock.unlock()
        if needsSeed { seed() }

        // `isAgent` asks this once per running process, so the directory stat
        // that checks for edits would otherwise run hundreds of times a scan.
        // Once a second is often enough to pick up a file someone just saved.
        lock.lock()
        if let cached, cached.checked.timeIntervalSinceNow > -1 {
            lock.unlock(); return cached.list
        }
        lock.unlock()

        let stamp = FileStamp.ofDirectory(directory)
        lock.lock()
        if let cached, cached.stamp == stamp {
            self.cached = (stamp, Date(), cached.list, cached.fragments, cached.names)
            lock.unlock()
            return cached.list
        }
        lock.unlock()

        let list = load()
        let fragments = list.flatMap(\.match)
        let names = Set(list.flatMap(\.processNames))
        lock.lock(); cached = (stamp, Date(), list, fragments, names); lock.unlock()
        return list
    }

    /// Every executable-path fragment any descriptor matches on, flattened once
    /// so a per-process check is one pass over a small array.
    static func matchFragments() -> [String] {
        _ = all()
        lock.lock(); defer { lock.unlock() }
        return cached?.fragments ?? []
    }

    /// Process names declared by any descriptor, matched exactly rather than as
    /// substrings — an interpreted agent's executable is `node`, and only
    /// argv[0] says which agent it is.
    static func processNamesAll() -> Set<String> {
        _ = all()
        lock.lock(); defer { lock.unlock() }
        return cached?.names ?? []
    }

    /// Drop the cache so an edited descriptor takes effect on the next scan.
    static func reload() {
        lock.lock(); cached = nil; lock.unlock()
    }

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
    static func seed() -> (added: [String], updated: [String], keptYours: [String]) {
        var added: [String] = [], updated: [String] = [], kept: [String] = []
        let manifest = directory.appendingPathComponent(".seed.json")
        var seeded = (try? Data(contentsOf: manifest))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("Antarium: couldn't create %@ — %@", directory.path, error.localizedDescription)
            return ([], [], [])
        }

        // Harnesses point one directory up to this editor schema. It is
        // app-owned rather than user-owned, so the current version can replace
        // it safely whenever the descriptor format grows.
        if let schema = AppResources.bundle.url(
            forResource: "harness.schema", withExtension: "json"),
           let data = try? Data(contentsOf: schema) {
            try? data.write(to: Config.directory.appendingPathComponent(
                "harness.schema.json"), options: .atomic)
        }

        // The previous design exported read-only copies here. It is tool-made
        // and no longer read; leaving it behind would just be a second copy to
        // wonder about.
        let legacy = directory.appendingPathComponent("builtin")
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }

        for source in bundled() {
            let name = source.lastPathComponent
            guard let shipped = try? Data(contentsOf: source) else { continue }
            let destination = directory.appendingPathComponent(name)
            let shippedSum = checksum(shipped)

            guard let existing = try? Data(contentsOf: destination) else {
                if (try? shipped.write(to: destination, options: .atomic)) != nil {
                    seeded[name] = shippedSum
                    added.append(name)
                }
                continue
            }
            let existingSum = checksum(existing)
            if existingSum == shippedSum { seeded[name] = shippedSum; continue }  // already current
            if seeded[name] == existingSum {
                // Untouched since we wrote it, and we now ship something newer.
                if (try? shipped.write(to: destination, options: .atomic)) != nil {
                    seeded[name] = shippedSum
                    updated.append(name)
                }
            } else {
                kept.append(name)                       // edited — leave it alone
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: seeded, options: [.sortedKeys]) {
            try? data.write(to: manifest, options: .atomic)
        }
        try? readme.write(to: directory.appendingPathComponent("README.txt"),
                          atomically: true, encoding: .utf8)
        if !added.isEmpty || !updated.isEmpty {
            NSLog("Antarium: harnesses seeded %d, updated %d, yours %d",
                  added.count, updated.count, kept.count)
        }
        return (added, updated, kept)
    }

    /// FNV-1a. Not for security — just "is this byte-for-byte what we wrote?",
    /// and it has to mean the same thing on every launch, which `hashValue`
    /// does not.
    private static func checksum(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return String(hash, radix: 16)
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
        what it would show. The format is documented in the Antarium README.

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
        return recorded != checksum(data)
    }

    /// Files that failed to load this pass, for the settings panel to show.
    /// A skipped harness used to be a log line nobody saw.
    nonisolated(unsafe) private static var failureStorage: [String] = []
    static var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failureStorage
    }

    /// Built-ins first, then user files, which win on id collision.
    private static func load() -> [HarnessDescriptor] {
        var byID: [String: HarnessDescriptor] = [:]
        var found: [String] = []
        defer {
            lock.lock()
            failureStorage = found
            lock.unlock()
        }
        // Only the user's folder. The bundle seeds it and is not read again —
        // one copy, so "which file is real?" always has one answer.
        for url in user() {
            let descriptor: HarnessDescriptor
            do {
                descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            } catch {
                let detail = "\(url.lastPathComponent): \(error.localizedDescription)"
                found.append(detail)
                NSLog("Antarium: skipping harness %@ — %@", url.lastPathComponent,
                      error.localizedDescription)
                continue
            }
            guard descriptor.isEnabled else { continue }
            byID[descriptor.id] = descriptor
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func bundled() -> [URL] {
        AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
    }

    private static func user() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            // `.seed.json` is bookkeeping, not a harness.
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
