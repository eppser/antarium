import Foundation
import SQLite3

/// Reads a session using whatever a `HarnessDescriptor` says about it.
///
/// One implementation covers every harness whose records are JSONL, a single
/// JSON object, or a SQLite row — which is all of them except Claude Code,
/// whose live status registry earns its own reader.
enum HarnessEngine {
    struct EvaluationMetrics: Codable, Equatable {
        let sourceBytes: UInt64
        let bytesRead: UInt64
        let recordsParsed: Int
        let cacheHit: Bool
        let elapsedMilliseconds: Double
    }

    struct Evaluation {
        let sessions: [Session]
        let metrics: EvaluationMetrics
    }

    private struct EvaluationCounter {
        let descriptorID: String
        var bytesRead: UInt64 = 0
        var recordsParsed = 0
        var cacheHit = false
    }

    nonisolated(unsafe) private static var evaluationCounter: EvaluationCounter?

    struct Health {
        let message: String
        let observedAt: Date
    }

    struct Session: Codable {
        /// Nil only in older persisted/manual values. Parsed sources record
        /// presence separately so an explicit zero never becomes missing data.
        var observedNumericFields: Set<String>?
        mutating func markNumeric(_ field:String) {
            if observedNumericFields == nil { observedNumericFields = [] }
            observedNumericFields?.insert(field)
        }
        func hasNumeric(_ field:String) -> Bool {
            if let observedNumericFields { return observedNumericFields.contains(field) }
            switch field {
            case "inputTokens": return inputTokens > 0
            case "outputTokens": return outputTokens > 0
            case "cacheWrite": return cacheWrite > 0
            case "cacheRead": return cacheRead > 0
            case "cost": return costUSD > 0
            case "toolCalls": return toolCalls > 0
            case "turns": return turns > 0
            case "subAgents": return subAgents > 0
            default: return false
            }
        }
        var sourceFile: String?
        var numericIssue: String?
        var sourceIssue: String?
        var sourceBacklogged: Bool?
        var sourceReadState: BoundedTraceReader.State?
        var sourceStamp: String?
        var cwd: String?
        var title: String?
        var model: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheRead = 0
        var cacheWrite = 0
        var costUSD = 0.0
        var toolCalls = 0
        var turns = 0
        var lastActivity: Date?
        var startedAt: Date?
        /// Set only when the harness records it explicitly.
        var isWorking: Bool?
        var contextWindow: Int?
        var subAgents = 0
        /// Set when the source names the process this session belongs to.
        var pid: Int32?
        /// The harness's own identifier for this session.
        var sessionID: String?
        /// What this harness's focus command needs to bring the session to the
        /// front — a tab id, a terminal handle. Distinct from `sessionID`,
        /// which identifies the conversation: Herdr puts several panes in one
        /// tab, so using the session id would focus the wrong thing or nothing.
        var focusTarget: String?
        /// Whether a record has satisfied `source.filter`. Always true when the
        /// descriptor sets no filter.
        var matchedFilter = false
        /// Set only when the harness measures its own context size.
        var measuredContext: Int?

        /// What tells two sessions apart when nothing else does.
        ///
        /// Sessions are listed most-recent-first, and a harness whose source
        /// carries no activity field gives every one of them the same key —
        /// at which point the order is whatever the sort happened to produce,
        /// and Swift's sort is not stable. The list is read by position:
        /// `session(_:forCwd:)` answers with `first`, and the dashboard uses
        /// each session's rank for the part of a row's identity that has no
        /// session id to use, and to decide which row carries the process's
        /// memory. A reshuffle therefore moves the memory figure to another
        /// row and changes a row's id, which makes the dashboard treat it as
        /// a row it has not seen before.
        ///
        /// Empty only when a session has no identity of any kind, and two of
        /// those are not distinguishable by anything this app can see.
        var orderingKey: String { sessionID ?? sourceFile ?? cwd ?? title ?? "" }

        /// What the harness measured, or what its token counts add up to.
        /// Only what the harness says is in its context right now.
        ///
        /// This used to fall back to summing the session's tokens, which for a
        /// store that keeps running totals reports *lifetime usage* under a
        /// heading that means *occupancy* — hermes read 305k and opencode 18k
        /// that way. The totals are already shown as the volume trace; a
        /// context figure nobody measured is better left blank.
        ///
        /// Blank, and not zero. This said `?? 0` while its own comment said
        /// otherwise, and the two readers of it both printed the zero: a
        /// descriptor author running `--check` against a harness that
        /// measures no context saw "context=0", which says the session is
        /// empty rather than that nothing was read. That is the wrong answer
        /// to give in the one tool whose whole job is telling somebody
        /// whether their mapping works.
        var contextTokens: Int? { measuredContext }
        /// One figure covering everything, for a harness that reports no
        /// split. Never combined with the fields below: a descriptor
        /// declaring both is refused when it decodes.
        var totalTokens: Int?
        /// Some APIs report input tokens with the cached part already included
        /// — Codex does. Adding the cache write on top then counts the cached
        /// portion twice, and "sent" read 206x what was actually uploaded.
        var inputIncludesCacheRead = false
        /// The usage figures of the last record counted, for a source that
        /// re-emits records. Optional so values written before this decode.
        var lastCountedUsage: [Int]?

        /// What actually went over the wire. Cache reads are re-used
        /// server-side, not re-uploaded, so they are not "sent".
        var sentTokens: Int? {
            guard inputTokens >= 0, cacheRead >= 0, cacheWrite >= 0 else { return nil }
            let uncached = inputIncludesCacheRead ? max(inputTokens - cacheRead, 0) : inputTokens
            let total = uncached.addingReportingOverflow(cacheWrite)
            return total.overflow ? nil : total.partialValue
        }
        var usageIssue: String? {
            if let numericIssue { return numericIssue }
            if let sourceIssue { return sourceIssue }
            if sourceBacklogged == true { return "Trace history is still being read. Usage figures are unavailable until it catches up." }
            guard [inputTokens, outputTokens, cacheRead, cacheWrite, toolCalls, turns, subAgents].allSatisfy({ $0 >= 0 }),
                  costUSD.isFinite, costUSD >= 0, sentTokens != nil else {
                return "Trace usage values are invalid or out of range. Usage figures are unavailable."
            }
            return nil
        }
    }

    /// The complete observable input fingerprint, not merely the newest mtime.
    /// Names, descriptor rules, manifests and SQLite sidecars all affect what a
    /// session means and therefore all participate in cache validity.
    nonisolated(unsafe) private static var cache:
        [String: (fingerprint: String, sessions: [Session])] = [:]
    /// Parsed sessions keyed by file, with how much of the file they cover.
    /// Transcripts only ever grow, so a rescan folds in the new bytes instead
    /// of re-reading megabytes that haven't changed.
    nonisolated(unsafe) private static var files:
        [String: (bytes: UInt64, session: Session)] = [:]
    /// Which files each filtered descriptor has already disowned.
    nonisolated(unsafe) private static var rejected: Set<String> = []
    nonisolated(unsafe) private static var healthByID: [String: Health] = [:]
    private static let lock = NSLock()

    static func health(for id: String) -> Health? {
        lock.lock()
        defer { lock.unlock() }
        return healthByID[id]
    }

    private static func clearHealth(_ id: String) {
        lock.lock()
        healthByID.removeValue(forKey: id)
        lock.unlock()
    }

    private static func fail(_ id: String, _ message: String) {
        lock.lock()
        healthByID[id] = Health(message: message, observedAt: Date())
        lock.unlock()
        Log.info("harness", message)
    }

    // MARK: - Persistence

    /// One parsed file, and how much of it the parse covers.
    private struct Cached: Codable {
        let bytes: UInt64
        let session: Session
    }
    private struct Store: Codable {
        /// Identifies the descriptors that produced these sessions. If a
        /// descriptor's field map changes, every cached session was parsed by
        /// different rules and has to go.
        let signature: Int
        let files: [String: Cached]
    }

    /// The live cache. Bump this and the old name goes in the list below, or
    /// it stays in the user's folder for ever.
    ///
    /// v3 because the figures in a v2 file were counted under a rule that has
    /// changed. This cache holds accumulated session totals beside the offset
    /// they were read to, so a Codex session already summed with its
    /// re-emitted events counted twice would keep that total for ever: the
    /// bytes behind the offset are never read again, and the correction would
    /// only ever apply to whatever the session wrote next. Discarding the
    /// file costs one re-read and is the only thing that makes the fix reach
    /// a session that already exists.
    static let cacheFilename = "harness-cache-v3.json"
    private static var cacheURL: URL {
        Config.directory.appendingPathComponent(cacheFilename)
    }

    /// Caches from earlier formats.
    ///
    /// `TranscriptStats` has had this since three of its own accumulated in
    /// people's folders, and states the principle plainly: files the app
    /// writes are the app's to clean up. It was never applied here, so the
    /// v1 to v2 bump orphaned a file that is still sitting in this
    /// developer's folder, larger than the one in use.
    static let supersededCacheFilenames = ["harness-cache-v1.json", "harness-cache-v2.json"]

    static func removeSupersededCaches() {
        for name in supersededCacheFilenames {
            try? FileManager.default.removeItem(
                at: Config.directory.appendingPathComponent(name))
        }
    }

    /// What the current descriptors would parse to. Cheap: they are already
    /// decoded and cached.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds its hasher randomly per
    /// process, so a `hashValue` written to disk never matches on the next
    /// launch — the cache would be discarded every single time and the whole
    /// exercise would be silently pointless.
    private static func signature() -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(HarnessDescriptor.all()) else { return 0 }
        // Reader semantics changed: invalidate persisted counts lacking presence.
        var hash: UInt64 = 0xcbf29ce484222325 ^ 3
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }

    /// Stable across launches, unlike Swift's randomized hash values.
    private static func fingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return "unencodable" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func manifestURL(near source: URL, _ descriptor: HarnessDescriptor) -> URL? {
        guard let manifest = descriptor.source.manifest else { return nil }
        return URL(fileURLWithPath: manifest.file,
                   relativeTo: source.deletingLastPathComponent()).standardizedFileURL
    }

    /// Everything whose bytes or interpretation can change the returned list.
    ///
    /// A maximum modification date is insufficient: deleting an older file
    /// leaves the maximum unchanged. SQLite may leave the main database
    /// untouched while its live rows exist only in the WAL.
    private static func sourceFingerprint(_ descriptor: HarnessDescriptor,
                                          files sourceFiles: [URL]) -> String {
        var parts = ["descriptor=\(fingerprint(descriptor))"]
        if descriptor.source.kind == .sqlite {
            let path = descriptor.source.path.expandingTilde
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: path + suffix)
                parts.append("\(url.path)=\(FileStamp.of(url))")
            }
        } else {
            for file in sourceFiles.sorted(by: { $0.path < $1.path }) {
                parts.append("\(file.path)=\(FileStamp.of(file))")
                if let manifest = manifestURL(near: file, descriptor) {
                    parts.append("manifest:\(manifest.path)=\(FileStamp.of(manifest))")
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Parsed transcript identity excludes the transcript's own stamp so an
    /// append can resume at the previous byte offset. It includes every rule
    /// and auxiliary file that changes the meaning of those bytes.
    private static func parsedFileKey(_ url: URL, _ descriptor: HarnessDescriptor) -> String {
        let manifest = manifestURL(near: url, descriptor)
            .map { "\($0.path)=\(FileStamp.of($0))" } ?? ""
        return "\(descriptor.id)|\(fingerprint(descriptor))|\(manifest)|\(url.path)"
    }

    /// Transcripts are re-read in full on the first scan of every launch —
    /// 16MB of Kimi history is most of a second. The offsets survive a restart
    /// the way `TranscriptStats` already does, so a relaunch resumes instead.
    static func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.signature == signature()
        else { return }
        lock.lock()
        files = store.files.mapValues { ($0.bytes, $0.session) }
        lock.unlock()
    }

    static func saveCache() {
        lock.lock()
        // Drop entries for sessions that no longer exist. Keyed by path, this
        // cache would otherwise only ever grow: every transcript ever seen
        // stays in it, and in the file on disk, long after the file is gone.
        let live = files.filter { key, _ in
            guard let path = key.split(separator: "|").last else { return false }
            return FileManager.default.fileExists(atPath: String(path))
        }
        files = live
        let snapshot = live.mapValues { Cached(bytes: $0.bytes, session: $0.session) }
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let store = Store(signature: signature(), files: snapshot)
        do {
            try FileManager.default.createDirectory(at: Config.directory,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(store).write(to: cacheURL, options: .atomic)
        } catch {
            Log.warn("harness", "Could not save the harness cache.")
        }
    }

    /// Drops everything held in memory so the next scan re-reads from disk.
    ///
    /// The per-file byte offsets stay: transcripts only grow, and re-parsing
    /// hundreds of megabytes would make an explicit refresh feel broken. What
    /// goes is every *decision* we cached — session lists, command output on its
    /// own timer, and which files a filter had disowned.
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        commandCache.removeAll()
        rejected.removeAll()
        lock.unlock()
    }

    /// Test/evaluation reset. Production reloads preserve parsed offsets; an
    /// explicit cold evaluation must be able to prove what a first read costs.
    /// Forgets everything the engine has read, so the next scan is cold.
    ///
    /// Test support. It had one caller in the app — the fixture verifier,
    /// which wiped the whole cache before every verification to avoid a
    /// collision that a fingerprint already prevents — and that caller is
    /// gone. Kept because a couple of dozen tests need a cold engine and
    /// there is no other way to ask for one; named plainly so nobody
    /// concludes the app depends on it.
    ///
    /// It took an `includingParsedFiles` flag that all twenty-two callers
    /// passed as `true`, so the branch that kept parsed files had never once
    /// been taken. A parameter with one possible value is a choice nobody
    /// made.
    /// How many parsed files are held. For tests that assert a reader
    /// cleaned up after itself; the cache has no eviction, so "it grew" and
    /// "it leaked" are the same sentence.
    static var parsedFileCount: Int {
        lock.lock(); defer { lock.unlock() }
        return files.count
    }

    /// The same count, for one directory only.
    ///
    /// The whole-cache count is a process-global, and the suites run beside
    /// each other: ten of them parse the shipped descriptors, so any test
    /// asserting the global number is unchanged is really asserting that
    /// nothing else parsed anything while it ran. That held until an
    /// eleventh suite was added, and then it did not — the failure named a
    /// timezone, because the timezone pass is where the order happened to
    /// put them together.
    ///
    /// A reader that works in a temporary tree can ask about that tree
    /// instead, and then nothing another suite does can answer for it. The
    /// prefix rule is `forget(under:id:)`'s, so the two agree about what
    /// belongs to a directory.
    static func parsedFileCount(under root: URL) -> Int {
        let prefix = root.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return files.keys.filter { $0.contains(prefix) }.count
    }

    /// Forgets what was read from one directory, and nothing else.
    ///
    /// For a reader that works in a temporary tree and then deletes it: the
    /// parsed-file cache is keyed partly by path and has no eviction, so
    /// entries for a directory that no longer exists would sit there for the
    /// life of the process. The fixture verifier is the one such reader, and
    /// it used to clear the entire cache instead — which was a far larger
    /// hammer and cost every other harness its work.
    ///
    /// The descriptor's own entry goes too: it was computed from files under
    /// that root and describes nothing once they are gone.
    static func forget(under root: URL, id: String) {
        let prefix = root.standardizedFileURL.path
        lock.lock()
        files = files.filter { !$0.key.contains(prefix) }
        cache.removeValue(forKey: id)
        lock.unlock()
    }

    static func resetCaches() {
        lock.lock()
        cache.removeAll()
        commandCache.removeAll()
        rejected.removeAll()
        files.removeAll()
        lock.unlock()
    }

    /// Runs the same engine path as the app and reports only directly observed
    /// work. `bytesRead` is application-level file/command bytes, not an
    /// estimate of filesystem or SQLite page-cache I/O.
    static func evaluate(_ descriptor: HarnessDescriptor) -> Evaluation {
        let sourceBytes = observableSourceBytes(descriptor)
        lock.lock()
        evaluationCounter = EvaluationCounter(descriptorID: descriptor.id)
        lock.unlock()
        let start = ProcessInfo.processInfo.systemUptime
        let found = sessions(descriptor)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        lock.lock()
        let counter = evaluationCounter ?? EvaluationCounter(descriptorID: descriptor.id)
        evaluationCounter = nil
        lock.unlock()
        return Evaluation(sessions: found,
            metrics: EvaluationMetrics(sourceBytes: sourceBytes,
                                       bytesRead: counter.bytesRead,
                                       recordsParsed: counter.recordsParsed,
                                       cacheHit: counter.cacheHit,
                                       elapsedMilliseconds: elapsed))
    }

    private static func observableSourceBytes(_ descriptor: HarnessDescriptor) -> UInt64 {
        switch descriptor.source.kind {
        case .json, .jsonl:
            let root = URL(fileURLWithPath: descriptor.source.path.expandingTilde)
            let limit = min(max(descriptor.source.limit ?? 40, 1), 400)
            return ((try? matchingFiles(under: root, glob: descriptor.source.glob ?? "*")) ?? [])
                .sorted { modified($0) > modified($1) }
                .prefix(limit)
                .reduce(0) { total, url in
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                        as? NSNumber)?.uint64Value ?? 0
                    return total + size
                }
        case .sqlite:
            return ["", "-wal", "-shm"].reduce(0) { total, suffix in
                let path = descriptor.source.path.expandingTilde + suffix
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]
                    as? NSNumber)?.uint64Value ?? 0
                return total + size
            }
        case .command, .none: return 0
        }
    }

    private static func observed(_ descriptorID: String, bytes: UInt64 = 0, records: Int = 0,
                                 cacheHit: Bool = false) {
        lock.lock()
        if var counter = evaluationCounter, counter.descriptorID == descriptorID {
            counter.bytesRead += bytes
            counter.recordsParsed += records
            counter.cacheHit = counter.cacheHit || cacheHit
            evaluationCounter = counter
        }
        lock.unlock()
    }

    /// Every session the descriptor can see, newest activity first.
    static func sessions(_ descriptor: HarnessDescriptor) -> [Session] {
        // Walk the glob once: it answers both "has anything changed?" and
        // "what is there to read?", and walking it twice a scan was costing
        // more than the parsing it guards.
        // A command has no files to stat; it is re-run on its own interval.
        if descriptor.source.kind == .none { return [] }
        if descriptor.source.kind == .command { return commandSessions(descriptor) }

        let files: [URL]
        do {
            files = descriptor.source.kind == .sqlite ? [] : try matchingFiles(
                under: URL(fileURLWithPath: descriptor.source.path.expandingTilde), glob: descriptor.source.glob ?? "*")
        } catch {
            fail(descriptor.id, "Source discovery is unavailable or exceeds its directory budget. Session details are unavailable.")
            return []
        }
        let fingerprint = sourceFingerprint(descriptor, files: files)
        lock.lock()
        if let hit = cache[descriptor.id], hit.fingerprint == fingerprint,
           healthByID[descriptor.id] == nil,
           !hit.sessions.contains(where: { $0.sourceBacklogged == true }) {
            lock.unlock()
            observed(descriptor.id, cacheHit: true)
            return hit.sessions
        }
        lock.unlock()

        let found: [Session]
        switch descriptor.source.kind {
        case .sqlite: found = readSQLite(descriptor)
        case .json, .jsonl: found = readFiles(descriptor, files)
        case .command, .none: found = []          // handled above
        }
        let sorted = found.sorted(by: byRecency)

        lock.lock(); cache[descriptor.id] = (fingerprint, sorted); lock.unlock()
        return sorted
    }

    /// The session belonging to a working directory.
    ///
    /// When the process has a directory and no session matches it, that is an
    /// answer — attaching the newest unrelated session would put one project's
    /// tokens on another's row.
    static func session(_ descriptor: HarnessDescriptor, forCwd cwd: String) -> Session? {
        let all = sessions(descriptor)
        guard !cwd.isEmpty else { return all.first }
        if let match = all.first(where: { $0.cwd == cwd }) { return match }
        // A harness whose sessions carry no directory at all can only offer one.
        return all.allSatisfy { $0.cwd == nil } ? all.first : nil
    }

    /// The session file a process itself has open. This is stronger evidence
    /// than a shared working directory: several agents may work in the same
    /// checkout, while each process owns a different append-only transcript.
    static func session(_ descriptor: HarnessDescriptor,
                        boundToOpenFiles paths: [String]) -> Session? {
        guard descriptor.processRule.sessionBinding == .openSourceFile,
              let glob = descriptor.source.glob else { return nil }
        let root = URL(fileURLWithPath: descriptor.source.path.expandingTilde)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidates = paths.prefix(1_024).compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
                .resolvingSymlinksInPath()
            return sourceFile(url, isUnder: root, matching: glob) ? url : nil
        }
        return readFiles(descriptor, candidates)
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
    }

    // MARK: - Inspection, for `--check`

    /// A handful of real records from whatever this descriptor points at, so
    /// the checker can test field paths against the data they will actually
    /// meet rather than against the author's expectations.
    static func sampleRecords(_ d: HarnessDescriptor, limit: Int = 400) -> (records: [[String: Any]], where: String) {
        switch d.source.kind {
        case .none:
            return ([], "no session source")
        case .command:
            guard let path = resolve(d.source.command ?? "") else {
                return ([], "command not found: \(d.source.command ?? "")")
            }
            let out = Shell.run(path, d.source.args ?? [], timeout: 10) ?? ""
            guard let data = out.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return ([], "\(path) did not print JSON")
            }
            if let root = d.source.root, let dict = object as? [String: Any],
               let nested = FieldPath.first(dict, root) as? [[String: Any]] { return (nested, path) }
            return ((object as? [[String: Any]]) ?? [], path)
        case .sqlite:
            // Run the real query so the checker can say what each declared
            // column actually produced. Without this a sqlite harness got no
            // field validation at all — the whole point of the check.
            let path = d.source.path.expandingTilde
            guard FileManager.default.fileExists(atPath: path) else {
                return ([], "sqlite file not found: \(path)")
            }
            guard let query = d.source.query else { return ([], "no query declared") }
            guard let columns = d.source.columns else { return ([], "no columns declared") }
            guard let result = try? BoundedSQLite.query(path:path,sql:query) else {
                return ([],"SQLite source is unavailable, invalid, or exceeds its read budget.")
            }
            guard result.columns.count == columns.count else { return ([],"SQLite columns do not match the declared mapping.") }
            let rows:[[String:Any]] = result.rows.prefix(min(20,max(1,limit))).map { values in
                var record:[String:Any] = [:]
                for (field,value) in zip(columns,values) {
                    switch value {
                    case .null, .blob: break
                    case .integer(let number): record[field] = Int(exactly:number)
                    case .real(let number): record[field] = number
                    case .text(let text): record[field] = text
                    }
                }
                return record
            }
            return (rows,"sqlite: \(rows.count) sampled row(s)")
        case .json, .jsonl:
            let root = URL(fileURLWithPath: d.source.path.expandingTilde)
            guard let matched = try? matchingFiles(under: root, glob: d.source.glob ?? "*") else {
                return ([], "Source discovery is unavailable or exceeds its directory budget.")
            }
            let files = matched.sorted { modified($0) > modified($1) }
            guard let newest = files.first else {
                return ([], "no files matched \(d.source.path)/\(d.source.glob ?? "*")")
            }
            // Several files, not just the newest. A session that was started
            // and never used carries almost no fields, and when it happened to
            // be the newest one the checker called every other field missing —
            // it reported Cursor's title as unreadable while the session next
            // to it had one.
            let budget = min(400, max(1, limit))
            let sampled = Array(files.prefix(min(5, budget)))
            let perFile = max(1, budget / sampled.count)
            var records: [[String: Any]] = []
            var limited = false
            for file in sampled {
                if d.source.kind == .json {
                    if let data = try? BoundedFile.read(file),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        records.append(object)
                    } else { limited = true }
                } else if d.source.journal == true {
                    // A journal must be folded from the full bounded document;
                    // sampling its ends would manufacture an invalid state.
                    if let data = try? BoundedFile.read(file) {
                        let lines = data.split(separator: 0x0A).compactMap {
                            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                        }
                        if !lines.isEmpty { records.append(["v": Journal.fold(lines)]) }
                    } else { limited = true }
                } else if let sample = try? BoundedFile.sampleJSONL(file, maxRecords: perFile) {
                    limited = limited || sample.limited
                    records.append(contentsOf: sample.records.compactMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    })
                } else { limited = true }
            }
            let extra = sampled.count > 1 ? " + \(sampled.count - 1) more" : ""
            let bounds = limited ? "; bounded sample, some history omitted" : ""
            return (Array(records.prefix(budget)),
                    "\(files.count) file(s); newest \(newest.lastPathComponent)\(extra)\(bounds)")

        }
    }

    /// Exposed for `--check`; the same resolution the engine itself uses,
    /// array syntax included. Using a plain lookup here reported working array
    /// paths as matching nothing.
    static func value(_ record: [String: Any], _ path: String) -> Any? {
        FieldPath.each(record, path).first
    }

    // MARK: - Commands

    /// Sessions from an agent's own CLI. Cached on a timer rather than a file
    /// stamp: running a process costs milliseconds where a stat costs
    /// microseconds, and no agent's state changes usefully faster than this.
    nonisolated(unsafe) private static var commandCache:
        [String: (at: Date, sessions: [Session])] = [:]

    /// The most sessions one command harness may contribute in a reading. A
    /// workspace manager reporting more panes than this is reporting
    /// something other than a workspace.
    static let maxCommandSessions = 256

    private static func commandSessions(_ d: HarnessDescriptor) -> [Session] {
        let every = d.source.refreshEvery ?? 30
        let key = "\(d.id)|\(fingerprint(d))"
        lock.lock()
        if let hit = commandCache[key], Date().timeIntervalSince(hit.at) < every {
            lock.unlock(); return hit.sessions
        }
        lock.unlock()

        var sessions: [Session] = []
        if let path = resolve(d.source.command ?? "") {
            clearHealth(d.id)
            let result = Shell.execute(path, d.source.args ?? [], timeout: 10)
            guard result.completeOutput else {
                let reason: String
                if result.launchError != nil {
                    reason = "could not launch the configured command"
                } else if result.stdoutTruncated {
                    reason = "command output exceeded its size limit; no partial sessions were accepted"
                } else if result.timedOut {
                    reason = "command timed out"
                } else {
                    reason = "command exit \(result.exitCode ?? -1); private command output was omitted"
                }
                fail(d.id, reason)
                lock.lock()
                commandCache[key] = (Date(), [])
                lock.unlock()
                return []
            }
            let out = result.stdout
            if let data = out.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                let records: [[String: Any]]
                if let path = d.source.root,
                   let dict = object as? [String: Any],
                   let nested = FieldPath.first(dict, path) as? [[String: Any]] {
                    records = nested
                } else {
                    records = (object as? [[String: Any]]) ?? []
                }
                // The command's output is bounded, which is not the same as
                // bounding what is built from it: four megabytes of small
                // records is tens of thousands of sessions, and each becomes a
                // row, a sort key and a transcript read. The same cap as the
                // other readers that take input from outside this process.
                for record in records.prefix(maxCommandSessions) {
                    var session = Session()
                    apply(record, to: &session, d.fields)

                    sessions.append(session)
                }
            } else {
                fail(d.id, out.isEmpty
                    ? "command returned no JSON"
                    : "command did not return JSON")
            }
        } else {
            fail(d.id, "configured command was not found")
        }
        let sorted = sessions.sorted(by: byRecency)
        lock.lock(); commandCache[key] = (Date(), sorted); lock.unlock()
        return sorted
    }

    /// A bare name is looked up on PATH; anything with a slash is used as given.
    private static func resolve(_ command: String) -> String? {
        guard !command.isEmpty else { return nil }
        let expanded = command.expandingTilde
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Files

    private static func readFiles(_ descriptor: HarnessDescriptor, _ files: [URL]) -> [Session] {
        clearHealth(descriptor.id)
        let limit = min(max(descriptor.source.limit ?? 40, 1), 400)
        return files
            .sorted { modified($0) > modified($1) }
            .prefix(limit)                                // newest few; older ones are history
            .filter { !rejectedEarly($0, descriptor) }
            .compactMap { file in
                var session = descriptor.source.kind == .jsonl
                    ? cachedJSONL(file, descriptor)
                    : readJSON(file, descriptor)
                if descriptor.source.kind == .jsonl { session?.sourceFile = file.path }
                return session
            }
            .filter { descriptor.source.filter == nil || $0.matchedFilter }
    }

    /// A filtered harness shares its directory with another — Codex writes the
    /// CLI's sessions and the desktop app's side by side. The first record
    /// already says which, so check that before parsing megabytes of the wrong
    /// one. Silence is not disagreement: a file whose opening record doesn't
    /// mention the field is parsed in full and judged on its contents.
    private static func rejectedEarly(_ url: URL, _ d: HarnessDescriptor) -> Bool {
        guard let filter = d.source.filter else { return false }
        let key = parsedFileKey(url, d) + "|" + FileStamp.of(url)
        lock.lock(); let known = rejected.contains(key); lock.unlock()
        if known { return true }
        lock.lock(); let parsed = files[parsedFileKey(url, d)] != nil; lock.unlock()
        if parsed { return false }          // already read; its verdict is cached
        guard let chunk = try? BoundedFile.prefix(url,maxBytes:16_384),
              let text = String(data: chunk, encoding: .utf8),
              let line = text.split(separator: "\n").first,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let no = filter.contains { path, accepted in
            guard let value = string(object, path) else { return false }
            return !accepted.contains(value)
        }
        if no { lock.lock(); rejected.insert(key); lock.unlock() }
        return no
    }

    /// Minimal glob: `*` matches within one path component, `**` any depth.
    private static func matchingFiles(under root: URL, glob: String) throws -> [URL] {
        try BoundedGlob.files(under:root,pattern:glob)
    }

    /// Applies a source glob to an already-known absolute file without walking
    /// the source tree. `**` spans path components; `*` keeps the same bounded
    /// component semantics as the normal source collector.
    private static func sourceFile(_ file: URL, isUnder root: URL,
                                   matching glob: String) -> Bool {
        let rootParts = root.pathComponents
        let fileParts = file.pathComponents
        guard fileParts.count > rootParts.count,
              fileParts.starts(with: rootParts) else { return false }
        let relative = Array(fileParts.dropFirst(rootParts.count))
        return BoundedGlob.matches(path:relative,pattern:glob)
    }

    /// Most recent first, with ties broken on something stable.
    ///
    /// The three places that ordered sessions this way each wrote the
    /// comparison out, and each left `lastActivity ?? .distantPast` as the
    /// only key — so every session a harness reports no activity for compared
    /// equal, and the list came back in a different order each time it was
    /// built. See `Session.orderingKey` for what that costs.
    static func byRecency(_ a: Session, _ b: Session) -> Bool {
        let x = a.lastActivity ?? .distantPast, y = b.lastActivity ?? .distantPast
        return x == y ? a.orderingKey < b.orderingKey : x > y
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    private static func readJSON(_ url: URL, _ d: HarnessDescriptor) -> Session? {
        guard let data = try? BoundedFile.read(url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fail(d.id, "JSON source is unavailable, invalid, or exceeds the 4 MiB read limit.")
            return nil
        }
        observed(d.id, bytes: UInt64(data.count), records: 1)
        var session = Session()
        note(object, matching: d, in: &session)
        apply(object, to: &session, d.fields)
        applyPathFields(from: url, to: &session, d)
        applyManifest(near: url, to: &session, d)
        session.lastActivity = session.lastActivity ?? modified(url)
        return session
    }

    /// Reads only what has been appended since the last scan.
    private static func cachedJSONL(_ url: URL, _ d: HarnessDescriptor) -> Session? {
        let key = parsedFileKey(url, d)
        let stamp = FileStamp.of(url)
        lock.lock(); let hit = files[key]; lock.unlock()
        if let hit, hit.session.sourceStamp == stamp, hit.session.sourceBacklogged != true {
            return hit.session
        }
        let journal = d.source.journal == true
        // Legacy caches lack an identity, so their counters cannot safely be
        // combined with a file that may have been replaced since persistence.
        let previous = !journal && hit?.session.sourceReadState != nil ? hit?.session : nil
        guard var session = readJSONL(url, d, carrying: previous) else { return nil }
        applyPathFields(from: url, to: &session, d)
        applyManifest(near: url, to: &session, d)
        session.lastActivity = session.lastActivity ?? modified(url)
        session.sourceStamp = stamp
        lock.lock(); files[key] = (session.sourceReadState?.offset ?? 0, session); lock.unlock()
        return session
    }

    private static func readJSONL(_ url: URL, _ d: HarnessDescriptor,
                                  carrying: Session? = nil) -> Session? {
        var session = carrying ?? Session()
        var any = carrying != nil
        let journal = d.source.journal == true
        var folding: [[String: Any]] = []
        var parsedRecords = 0
        var invalidRecords = 0
        do {
            let batch = try BoundedTraceReader.read(url, state: session.sourceReadState ?? .init(),
                onReset: { session = Session(); any = false }) { data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        invalidRecords += 1; return
                    }
                    parsedRecords += 1; any = true
                    if let marker = d.fields.toolMarker, let line = String(data: data, encoding: .utf8) {
                        session.markNumeric("toolCalls")
                        let count = line.components(separatedBy: marker).count - 1
                        let next = session.toolCalls.addingReportingOverflow(count)
                        if next.overflow { session.numericIssue = "Trace tool count is out of range. Usage figures are unavailable." }
                        else { session.toolCalls = next.partialValue }
                    }
                    if journal { folding.append(object); return }
                    note(object, matching: d, in: &session)
                    apply(object, to: &session, d.fields)
                }
            session.sourceReadState = batch.state
            session.sourceBacklogged = batch.backlogged
            if batch.skipped > 0 || invalidRecords > 0 {
                session.sourceIssue = "Some trace records were invalid or exceeded the read limit. Usage figures are unavailable."
            }
            if journal {
                if batch.backlogged {
                    // Journal patches require the entire document. A truncated
                    // fold must never masquerade as the complete session.
                    session.sourceIssue = "The journal exceeds the 4 MiB read limit. Usage figures are unavailable."
                    session.sourceBacklogged = false
                } else if !folding.isEmpty {
                    let record = ["v": Journal.fold(folding)]
                    note(record, matching: d, in: &session)
                    apply(record, to: &session, d.fields)
                }
            }
            observed(d.id, bytes: UInt64(batch.bytesRead), records: parsedRecords)
            return any || session.usageIssue != nil ? session : nil
        } catch {
            fail(d.id, "Trace source could not be read as a regular file.")
            return nil
        }
    }


    /// Records whether this session is one the descriptor asked for.
    private static func note(_ record: [String: Any], matching d: HarnessDescriptor,
                             in session: inout Session) {
        guard let filter = d.source.filter, !session.matchedFilter else { return }
        session.matchedFilter = filter.allSatisfy { path, accepted in
            string(record, path).map(accepted.contains) ?? false
        }
    }

    /// Folds in the sibling file a descriptor points at, if it has one.
    private static func applyManifest(near url: URL, to session: inout Session,
                                      _ d: HarnessDescriptor) {
        guard let manifest = d.source.manifest,
              let file = manifestURL(near: url, d) else { return }
        guard let data = try? BoundedFile.read(file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        apply(object, to: &session, manifest.map)
    }

    /// Adds metadata encoded by directory layout. This keeps readers generic:
    /// a product may put the project/session id in parent folder names rather
    /// than redundantly writing them into every transcript record.
    private static func applyPathFields(from file: URL, to session: inout Session,
                                        _ d: HarnessDescriptor) {
        for (field, rule) in d.source.pathFields ?? [:] {
            guard rule.ancestor >= 0 else { continue }
            var source = file
            for _ in 0..<rule.ancestor { source.deleteLastPathComponent() }
            let value: String
            switch rule.value {
            case .name: value = source.lastPathComponent
            case .stem: value = source.deletingPathExtension().lastPathComponent
            case .path: value = source.path
            }
            guard !value.isEmpty else { continue }
            switch field {
            case "cwd": session.cwd = value
            case "title": session.title = value
            case "model": session.model = value
            case "sessionID": session.sessionID = value
            default: break
            }
        }
    }

    /// Folds one record into the session. Later records win for single values;
    /// token counts accumulate.
    private static func apply(_ record: [String: Any], to session: inout Session,
                              _ map: HarnessDescriptor.Map) {
        if let path = map.sessionID, let value = string(record, path), !value.isEmpty {
            session.sessionID = value
        }
        if let path = map.focusTarget, let value = string(record, path), !value.isEmpty {
            session.focusTarget = value
        }
        if let path = map.cwd, let value = string(record, path), !value.isEmpty {
            // VS Code records its folder as `file:///Users/...`, percent-encoded.
            // Every other harness writes a plain path, and the rest of the app
            // compares against plain paths.
            session.cwd = value.hasPrefix("file://")
                ? (URL(string: value)?.path ?? value)
                : value
        }
        if let path = map.title, let value = string(record, path), !value.isEmpty {
            // Some harnesses keep the whole opening prompt here; a row shows one line.
            session.title = value.split(separator: "\n").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? value
        }
        if let path = map.model, let value = string(record, path),
           !value.isEmpty, !value.hasPrefix("<") { session.model = value }

        if let path = map.timestamp, let when = date(record, path) {
            session.lastActivity = when
            if session.startedAt == nil { session.startedAt = when }
        }
        if let path = map.pid, let value = FieldPath.first(record,path) {
            session.pid = FieldPath.processID(value)
        }
        let integerPaths = [map.inputTokens, map.outputTokens, map.cacheRead, map.cacheWrite,
                            map.contextWindow] + (map.contextTokens ?? []).map(Optional.some)
        for path in integerPaths.compactMap({ $0 }) {
            let values = FieldPath.each(record, path)
            if !values.isEmpty && !values.allSatisfy({ $0 is NSNull }),
               (FieldPath.int(record, path).map { $0 >= 0 } != true) {
                session.numericIssue = "Trace usage values are invalid or out of range. Usage figures are unavailable."
            }
        }
        if let path = map.cost, !FieldPath.each(record,path).isEmpty,
           !FieldPath.each(record,path).allSatisfy({ $0 is NSNull }),
           FieldPath.number(record, path).map({ $0 >= 0 }) != true {
            session.numericIssue = "Trace cost is invalid or unavailable. Usage figures are unavailable."
        }
        if session.observedNumericFields == nil { session.observedNumericFields = [] }
        for (field,path) in [("inputTokens",map.inputTokens),("outputTokens",map.outputTokens),
                            ("cacheRead",map.cacheRead),("cacheWrite",map.cacheWrite),
                            ("totalTokens",map.totalTokens)] {
            if let path, let value = FieldPath.int(record,path), value >= 0 { session.markNumeric(field) }
        }
        if let path = map.cost, let amount = FieldPath.number(record,path), amount >= 0 { session.markNumeric("cost") }
        if map.inputIncludesCacheRead == true { session.inputIncludesCacheRead = true }

        // A record this source has already written once.
        //
        // Only where the descriptor says the source does that, and only for a
        // record carrying figures at all: the records between two turns carry
        // none, and skipping those would be comparing nothing with nothing.
        // A record whose usage this source does not want counted. Read for
        // everything else — the rule says which figures may be added, not
        // which records exist.
        var countable = true
        if let skip = map.skipUsageWhere, !skip.isEmpty {
            countable = !skip.allSatisfy { string(record, $0.key) == $0.value }
        }

        var repeated = false
        if countable, map.skipRepeatedUsage == true {
            let figures = [map.inputTokens, map.outputTokens, map.cacheRead,
                           map.cacheWrite, map.totalTokens]
                .map { $0.flatMap { FieldPath.int(record, $0) } ?? 0 }
            if figures.contains(where: { $0 > 0 }) {
                repeated = figures == session.lastCountedUsage
                session.lastCountedUsage = figures
            }
        }

        if session.numericIssue == nil {
            func accumulated(_ current: Int, path: String?) -> Int? {
                // A record whose figures are not this session's to add — a
                // running total, or an event written twice — contributes
                // nothing and changes nothing. The record is still read below
                // for its context and its window: those are the latest state
                // rather than a sum, and a running total is as current a
                // statement of them as anything else in the file.
                guard countable, !repeated else { return current }
                let amount = path.flatMap { FieldPath.int(record, $0) } ?? 0
                let total = current.addingReportingOverflow(amount)
                return total.overflow ? nil : total.partialValue
            }
            if let input = accumulated(session.inputTokens, path: map.inputTokens),
               let output = accumulated(session.outputTokens, path: map.outputTokens),
               let read = accumulated(session.cacheRead, path: map.cacheRead),
               let write = accumulated(session.cacheWrite, path: map.cacheWrite) {
                session.inputTokens = input; session.outputTokens = output
                session.cacheRead = read; session.cacheWrite = write
                // Accumulated the same bounded way, and kept apart from the
                // four above: a harness declares one shape or the other.
                if let path = map.totalTokens {
                    if let total = accumulated(session.totalTokens ?? 0, path: path) {
                        session.totalTokens = total
                    } else {
                        session.numericIssue = "Trace usage totals exceeded the supported range. Usage figures are unavailable."
                    }
                }
            } else {
                session.numericIssue = "Trace usage totals exceeded the supported range. Usage figures are unavailable."
            }
            if countable, !repeated, let path = map.cost,
               let amount = FieldPath.number(record, path) {
                let total = session.costUSD + amount
                if total.isFinite { session.costUSD = total }
                else { session.numericIssue = "Trace cost exceeded the supported range. Usage figures are unavailable." }
            }
            if let path = map.contextWindow, let window = FieldPath.int(record, path), window > 0 {
                session.contextWindow = window
            }
            if let paths = map.contextTokens {
                var measured = 0
                for path in paths {
                    let total = measured.addingReportingOverflow(FieldPath.int(record, path) ?? 0)
                    if total.overflow {
                        session.numericIssue = "Trace context exceeded the supported range. Usage figures are unavailable."
                        break
                    }
                    measured = total.partialValue
                }
                if session.numericIssue == nil && paths.contains(where: { FieldPath.int(record,$0) != nil }) {
                    session.measuredContext = measured
                }
            }
        }
        func countIsPresent(_ path:String) -> Bool {
            let value = FieldPath.first(record,path)
            return value is [Any] || value is [String:Any]
        }
        if let count = map.turns, countIsPresent(count.path) {
            session.markNumeric("turns")
            session.turns = FieldPath.count(record,path:count.path,match:count.filter)
        }
        if let count = map.subAgents, countIsPresent(count.path) {
            session.markNumeric("subAgents")
            session.subAgents = FieldPath.count(record,path:count.path,match:count.filter)
        }
        if map.turnWhere != nil { session.markNumeric("turns") }
        if map.toolWhere != nil { session.markNumeric("toolCalls") }

        if let want = map.turnWhere,
           want.allSatisfy({ string(record, $0.key) == $0.value }) {
            session.turns += 1
        }
        if let want = map.toolWhere,
           want.allSatisfy({ string(record, $0.key) == $0.value }) {
            session.toolCalls += 1
        }
        if let count = map.toolCalls, countIsPresent(count.path) {
            session.markNumeric("toolCalls")
            session.toolCalls += FieldPath.count(record, path: count.path, match: count.filter)
        }
        if let status = map.status, let path = status.whileNotEmpty {
            let busy = FieldPath.count(record, path: path, match: [:])
            session.isWorking = busy > 0
        }
        if let status = map.status, let field = status.field, !field.isEmpty,
           let value = string(record, field) {
            if status.workingValues.contains(value) { session.isWorking = true }
            else if status.idleValues.contains(value) { session.isWorking = false }
        }
    }

    // MARK: - SQLite

    private static func readSQLite(_ d: HarnessDescriptor) -> [Session] {
        clearHealth(d.id)
        guard let query = d.source.query, let columns = d.source.columns else {
            fail(d.id, "SQLite source is missing query or columns")
            return []
        }
        let result:BoundedSQLite.Result
        do { result = try BoundedSQLite.query(path:d.source.path.expandingTilde,sql:query) }
        catch {
            fail(d.id,(error as? BoundedSQLite.ReadError)?.message ?? "SQLite source could not be read.")
            return []
        }
        guard columns.count == result.columns.count else {
            fail(d.id,"SQLite result columns do not match the declared mapping."); return []
        }
        return result.rows.map { values in
            var session = Session(); session.observedNumericFields = []
            for (field,value) in zip(columns,values) {
                if value == .null { continue }
                switch field {
                case "sessionID": session.sessionID = value.string
                case "cwd": session.cwd = value.string
                case "title": session.title = value.string
                case "model": session.model = value.string
                case "startedAt": session.startedAt = value.date
                case "lastActivity": session.lastActivity = value.date
                case "cost":
                    if let amount = value.number, amount >= 0 { session.costUSD = amount; session.markNumeric("cost") }
                    else { session.numericIssue = "SQLite usage values are invalid. Usage figures are unavailable." }
                case "inputTokens","outputTokens","cacheRead","cacheWrite","toolCalls","turns","subAgents","contextTokens","contextWindow":
                    guard let amount = value.integer, amount >= 0 else {
                        session.numericIssue = "SQLite usage values are invalid. Usage figures are unavailable."; continue
                    }
                    session.markNumeric(field)
                    switch field {
                    case "inputTokens": session.inputTokens = amount
                    case "outputTokens": session.outputTokens = amount
                    case "cacheRead": session.cacheRead = amount
                    case "cacheWrite": session.cacheWrite = amount
                    case "toolCalls": session.toolCalls = amount
                    case "turns": session.turns = amount
                    case "subAgents": session.subAgents = amount
                    case "contextTokens": session.measuredContext = amount
                    case "contextWindow": session.contextWindow = amount > 0 ? amount : nil
                    default: break
                    }
                default: break
                }
            }
            return session
        }
    }

    /// Some stores hold seconds, some milliseconds; both are common enough that
    /// guessing from magnitude beats making every descriptor declare it.

    // MARK: - Paths into a record



    /// The last one that has a value — a session's model is whatever it used most
    /// recently, not whatever it started with.
    private static func string(_ r: [String: Any], _ p: String) -> String? { FieldPath.string(r, p) }



    private static func date(_ r: [String: Any], _ p: String) -> Date? { FieldPath.date(r, p) }

    /// Cheap change stamp: the newest modification under the source.
}
