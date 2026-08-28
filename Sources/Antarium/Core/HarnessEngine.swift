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
        /// Whether a record has satisfied `source.filter`. Always true when the
        /// descriptor sets no filter.
        var matchedFilter = false
        /// Set only when the harness measures its own context size.
        var measuredContext: Int?

        /// What the harness measured, or what its token counts add up to.
        /// Only what the harness says is in its context right now.
        ///
        /// This used to fall back to summing the session's tokens, which for a
        /// store that keeps running totals reports *lifetime usage* under a
        /// heading that means *occupancy* — hermes read 305k and opencode 18k
        /// that way. The totals are already shown as the volume trace; a
        /// context figure nobody measured is better left blank.
        var contextTokens: Int { measuredContext ?? 0 }
        /// Some APIs report input tokens with the cached part already included
        /// — Codex does. Adding the cache write on top then counts the cached
        /// portion twice, and "sent" read 206x what was actually uploaded.
        var inputIncludesCacheRead = false

        /// What actually went over the wire. Cache reads are re-used
        /// server-side, not re-uploaded, so they are not "sent".
        var sentTokens: Int {
            let uncached = inputIncludesCacheRead ? max(inputTokens - cacheRead, 0) : inputTokens
            return uncached + cacheWrite
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
        Log.info("harness", "\(id): \(message)")
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

    private static var cacheURL: URL {
        Config.directory.appendingPathComponent("harness-cache-v2.json")
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
        var hash: UInt64 = 0xcbf29ce484222325
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
            NSLog("Antarium: couldn't write harness cache — %@", error.localizedDescription)
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
    static func resetCaches(includingParsedFiles: Bool) {
        lock.lock()
        cache.removeAll()
        commandCache.removeAll()
        rejected.removeAll()
        if includingParsedFiles { files.removeAll() }
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
            return matchingFiles(under: root, glob: descriptor.source.glob ?? "*")
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

        let files = descriptor.source.kind == .sqlite
            ? []
            : matchingFiles(under: URL(fileURLWithPath: descriptor.source.path.expandingTilde),
                            glob: descriptor.source.glob ?? "*")
        let fingerprint = sourceFingerprint(descriptor, files: files)
        lock.lock()
        if let hit = cache[descriptor.id], hit.fingerprint == fingerprint {
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
        let sorted = found.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }

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
               let nested = FieldPath.lookup(dict, root) as? [[String: Any]] { return (nested, path) }
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
            var db: OpaquePointer?
            guard sqlite3_open_v2("file:\(path)?mode=ro", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                  let db else {
                if db != nil { sqlite3_close(db) }
                return ([], "could not open \(path)")
            }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                let message = String(cString: sqlite3_errmsg(db))
                return ([], "query failed: \(message)")
            }
            defer { sqlite3_finalize(statement) }

            var rows: [[String: Any]] = []
            let selected = Int(sqlite3_column_count(statement))
            while sqlite3_step(statement) == SQLITE_ROW, rows.count < 20 {
                var record: [String: Any] = [:]
                for (index, field) in columns.enumerated() where index < selected {
                    let i = Int32(index)
                    switch sqlite3_column_type(statement, i) {
                    case SQLITE_NULL: break
                    case SQLITE_INTEGER: record[field] = Int(sqlite3_column_int64(statement, i))
                    case SQLITE_FLOAT: record[field] = sqlite3_column_double(statement, i)
                    default:
                        if let raw = sqlite3_column_text(statement, i) {
                            record[field] = String(cString: raw)
                        }
                    }
                }
                rows.append(record)
            }
            let mismatch = selected != columns.count
                ? " — query selects \(selected) column(s) but \(columns.count) are named"
                : ""
            return (rows, "sqlite: \(rows.count) row(s)\(mismatch)")
        case .json, .jsonl:
            let root = URL(fileURLWithPath: d.source.path.expandingTilde)
            let files = matchingFiles(under: root, glob: d.source.glob ?? "*")
                .sorted { modified($0) > modified($1) }
            guard let newest = files.first else {
                return ([], "no files matched \(d.source.path)/\(d.source.glob ?? "*")")
            }
            // Several files, not just the newest. A session that was started
            // and never used carries almost no fields, and when it happened to
            // be the newest one the checker called every other field missing —
            // it reported Cursor's title as unreadable while the session next
            // to it had one.
            let sampled = Array(files.prefix(5))
            var records: [[String: Any]] = []
            for file in sampled {
            if d.source.kind == .json {
                if let data = try? Data(contentsOf: file),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    records.append(object)
                }
            } else if d.source.journal == true,
                      let text = try? String(contentsOf: file, encoding: .utf8) {
                let lines = text.split(separator: "\n").compactMap { line -> [String: Any]? in
                    line.data(using: .utf8).flatMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    } ?? nil
                }
                if !lines.isEmpty { records.append(["v": Journal.fold(lines)]) }
            } else if let text = try? String(contentsOf: file, encoding: .utf8) {
                // Both ends, not just the head: a session's opening records and
                // its latest ones carry different fields — Kimi writes its
                // measured context only once a conversation is under way — and
                // sampling the top alone reported a working field as missing.
                let lines = text.split(separator: "\n")
                let half = max(limit / 2, 1)
                let sample = lines.count <= limit
                    ? Array(lines)
                    : Array(lines.prefix(half)) + Array(lines.suffix(half))
                for line in sample {
                    if let data = line.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        records.append(object)
                    }
                }
            }
            }
            let extra = sampled.count > 1 ? " + \(sampled.count - 1) more" : ""
            return (records,
                    "\(files.count) file(s); newest \(newest.lastPathComponent)\(extra)")
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
            guard result.succeeded else {
                let reason: String
                if let error = result.launchError {
                    reason = "could not launch command: \(error)"
                } else if result.timedOut {
                    reason = "command timed out"
                } else {
                    let detail = result.stderr.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    reason = "command exit \(result.exitCode ?? -1)"
                        + (detail.isEmpty ? "" : ": \(detail.prefix(240))")
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
                   let nested = FieldPath.lookup(dict, path) as? [[String: Any]] {
                    records = nested
                } else {
                    records = (object as? [[String: Any]]) ?? []
                }
                for record in records {
                    var session = Session()
                    apply(record, to: &session, d.fields)
                    if let key = d.fields.pid { session.pid = Int32(int(record, key)) }
                    sessions.append(session)
                }
            } else {
                fail(d.id, out.isEmpty
                    ? "command returned no JSON"
                    : "command did not return JSON")
            }
        } else {
            fail(d.id, "command not found: \(d.source.command ?? "")")
        }
        let sorted = sessions.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
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
        let limit = min(max(descriptor.source.limit ?? 40, 1), 400)
        return files
            .sorted { modified($0) > modified($1) }
            .prefix(limit)                                // newest few; older ones are history
            .filter { !rejectedEarly($0, descriptor) }
            .compactMap { file in
                descriptor.source.kind == .jsonl
                    ? cachedJSONL(file, descriptor)
                    : readJSON(file, descriptor)
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
        let key = parsedFileKey(url, d)
        lock.lock(); let known = rejected.contains(key); lock.unlock()
        if known { return true }
        lock.lock(); let parsed = files[parsedFileKey(url, d)] != nil; lock.unlock()
        if parsed { return false }          // already read; its verdict is cached
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 16_384),
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
    private static func matchingFiles(under root: URL, glob: String) -> [URL] {
        let parts = glob.split(separator: "/").map(String.init)
        var level = [root]
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            var next: [URL] = []
            for directory in level {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
                for entry in entries where matches(entry.lastPathComponent, part) {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
                    if isLast ? !isDir.boolValue : isDir.boolValue { next.append(entry) }
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return level
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
        let pattern = glob.split(separator: "/").map(String.init)
        return matchesPath(relative[...], pattern[...])
    }

    private static func matchesPath(_ path: ArraySlice<String>,
                                    _ pattern: ArraySlice<String>) -> Bool {
        guard let wanted = pattern.first else { return path.isEmpty }
        if wanted == "**" {
            return matchesPath(path, pattern.dropFirst())
                || (!path.isEmpty && matchesPath(path.dropFirst(), pattern))
        }
        guard let component = path.first, matches(component, wanted) else { return false }
        return matchesPath(path.dropFirst(), pattern.dropFirst())
    }

    private static func matches(_ name: String, _ pattern: String) -> Bool {
        if pattern == "*" || pattern == "**" { return !name.hasPrefix(".") }
        if pattern.hasPrefix("*") { return name.hasSuffix(pattern.dropFirst()) }
        if pattern.hasSuffix("*") { return name.hasPrefix(pattern.dropLast()) }
        return name == pattern
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    private static func readJSON(_ url: URL, _ d: HarnessDescriptor) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
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
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            .flatMap { $0 } ?? 0
        let key = parsedFileKey(url, d)

        lock.lock(); let hit = files[key]; lock.unlock()
        // A file that shrank was rotated or rewritten: start it over.
        if let hit, hit.bytes == size { return hit.session }
        // A journal's meaning is in the whole file: a later line can overwrite
        // an earlier one, so resuming halfway would apply patches to a document
        // that was never rebuilt. Unchanged files still short-circuit above, so
        // only a session being written right now is re-read — and those are
        // small.
        let journal = d.source.journal == true
        let from = journal ? 0 : ((hit?.bytes ?? 0) <= size ? (hit?.bytes ?? 0) : 0)

        let read = readJSONL(url, d, from: from,
                             carrying: (!journal && from > 0) ? hit?.session : nil)
        guard var session = read.session else { return nil }
        applyPathFields(from: url, to: &session, d)
        applyManifest(near: url, to: &session, d)
        session.lastActivity = session.lastActivity ?? modified(url)

        // Resume from the last *complete* record, not from the end of the file.
        // Storing the file's size treated a half-written trailing line as read:
        // the next pass began after it, so that record — and its tokens — were
        // dropped for good, while any tool marker inside it had already counted.
        lock.lock(); files[key] = (from + read.consumed, session); lock.unlock()
        return session
    }

    /// Returns the session and how many bytes of complete records were read,
    /// so the caller can resume exactly where a record ended.
    private static func readJSONL(_ url: URL, _ d: HarnessDescriptor,
                                  from offset: UInt64 = 0,
                                  carrying: Session? = nil) -> (session: Session?, consumed: UInt64) {
        var data: Data
        if offset > 0, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            data = (try? handle.readToEnd()) ?? Data()
        } else if let whole = try? Data(contentsOf: url) {
            data = whole
        } else {
            return (nil, 0)
        }
        let bytesRead = UInt64(data.count)
        // Everything after the final newline is a record still being written.
        // It is left for the next pass rather than half-parsed now.
        guard let lastBreak = data.lastIndex(of: 0x0A) else {
            return (carrying, 0)
        }
        let consumed = UInt64(data.distance(from: data.startIndex, to: lastBreak) + 1)
        data = data.prefix(upTo: data.index(after: lastBreak))
        let text = String(data: data, encoding: .utf8) ?? ""
        var session = carrying ?? Session()
        var any = carrying != nil
        let journal = d.source.journal == true
        var folding: [[String: Any]] = []
        var parsedRecords = 0
        autoreleasepool {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let marker = d.fields.toolMarker {
                    // One record can carry several calls, so count occurrences.
                    session.toolCalls += line.components(separatedBy: marker).count - 1
                }
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                parsedRecords += 1
                any = true
                if journal { folding.append(object); continue }
                note(object, matching: d, in: &session)
                apply(object, to: &session, d.fields)
            }
            if journal, !folding.isEmpty {
                // One document, mapped once: applying each patch on its own
                // would add the same token count twice when a value is first
                // appended and then set.
                let record = ["v": Journal.fold(folding)]
                note(record, matching: d, in: &session)
                apply(record, to: &session, d.fields)
            }
        }
        observed(d.id, bytes: bytesRead, records: parsedRecords)
        return (any ? session : nil, consumed)
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
        guard let data = try? Data(contentsOf: file),
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
        if let path = map.inputTokens  { session.inputTokens  += int(record, path) }
        if map.inputIncludesCacheRead == true { session.inputIncludesCacheRead = true }
        if let path = map.outputTokens { session.outputTokens += int(record, path) }
        if let path = map.cacheRead    { session.cacheRead    += int(record, path) }
        if let path = map.cacheWrite   { session.cacheWrite   += int(record, path) }
        if let path = map.cost         { session.costUSD      += double(record, path) }
        if let path = map.contextWindow {
            let window = int(record, path)
            if window > 0 { session.contextWindow = window }
        }
        if let paths = map.contextTokens {
            let measured = paths.reduce(0) { $0 + int(record, $1) }
            if measured > 0 { session.measuredContext = measured }
        }
        if let count = map.turns {
            let total = FieldPath.count(record, path: count.path, match: count.filter)
            if total > 0 { session.turns = total }
        }
        if let count = map.subAgents {
            let total = FieldPath.count(record, path: count.path, match: count.filter)
            if total > 0 { session.subAgents = total }
        }

        if let want = map.turnWhere,
           want.allSatisfy({ string(record, $0.key) == $0.value }) {
            session.turns += 1
        }
        if let want = map.toolWhere,
           want.allSatisfy({ string(record, $0.key) == $0.value }) {
            session.toolCalls += 1
        }
        if let count = map.toolCalls {
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

    /// A timestamp column is an epoch in some stores and an ISO string in
    /// others — Copilot writes `2026-08-24T09:40:05.464Z`. Reading it as a
    /// number gave zero, silently, so both are accepted.
    private static func time(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        if sqlite3_column_type(statement, index) == SQLITE_TEXT,
           let raw = sqlite3_column_text(statement, index) {
            return UsageHTTP.parseDate(String(cString: raw))
        }
        return FieldPath.epoch(sqlite3_column_double(statement, index))
    }

    private static func readSQLite(_ d: HarnessDescriptor) -> [Session] {
        clearHealth(d.id)
        guard let query = d.source.query, let columns = d.source.columns else {
            fail(d.id, "SQLite source is missing query or columns")
            return []
        }
        var db: OpaquePointer?
        let path = d.source.path.expandingTilde
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close(db) }
            fail(d.id, "could not open SQLite database at \(path)")
            return []
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            fail(d.id, "SQLite query failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var out: [Session] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var session = Session()
            for (index, field) in columns.enumerated() {
                let i = Int32(index)
                switch field {
                case "sessionID":    session.sessionID = text(statement, i)
                case "cwd":          session.cwd = text(statement, i)
                case "title":        session.title = text(statement, i)
                case "model":        session.model = text(statement, i)
                case "inputTokens":  session.inputTokens = Int(sqlite3_column_int64(statement, i))
                case "outputTokens": session.outputTokens = Int(sqlite3_column_int64(statement, i))
                case "cacheRead":    session.cacheRead = Int(sqlite3_column_int64(statement, i))
                case "cacheWrite":   session.cacheWrite = Int(sqlite3_column_int64(statement, i))
                case "toolCalls":    session.toolCalls = Int(sqlite3_column_int64(statement, i))
                case "cost":         session.costUSD = sqlite3_column_double(statement, i)
                case "startedAt":    session.startedAt = time(statement, i)
                case "lastActivity": session.lastActivity = time(statement, i)
                case "turns":        session.turns = Int(sqlite3_column_int64(statement, i))
                case "subAgents":    session.subAgents = Int(sqlite3_column_int64(statement, i))
                case "contextTokens":
                    session.measuredContext = Int(sqlite3_column_int64(statement, i))
                case "contextWindow":
                    session.contextWindow = Int(sqlite3_column_int64(statement, i))
                default: break
                }
            }
            out.append(session)
            step = sqlite3_step(statement)
        }
        if step != SQLITE_DONE {
            fail(d.id, "SQLite query stopped: \(String(cString: sqlite3_errmsg(db)))")
        }
        return out
    }

    private static func text(_ statement: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(statement, i).map { String(cString: $0) }
    }

    /// Some stores hold seconds, some milliseconds; both are common enough that
    /// guessing from magnitude beats making every descriptor declare it.

    // MARK: - Paths into a record



    /// The last one that has a value — a session's model is whatever it used most
    /// recently, not whatever it started with.
    private static func string(_ r: [String: Any], _ p: String) -> String? { FieldPath.string(r, p) }

    private static func int(_ r: [String: Any], _ p: String) -> Int { FieldPath.int(r, p) }

    private static func double(_ r: [String: Any], _ p: String) -> Double { FieldPath.double(r, p) }

    private static func date(_ r: [String: Any], _ p: String) -> Date? { FieldPath.date(r, p) }

    /// Cheap change stamp: the newest modification under the source.
}
