import Foundation

/// What a Claude Code transcript says about a session: model, tool calls,
/// context size, estimated cost.
///
/// Transcripts are append-only and reach hundreds of megabytes across a
/// machine — a full re-read took ~7s here. So each file is read **once**, and
/// every later pass consumes only the bytes appended since, which costs
/// essentially nothing. Parsing works on raw bytes: line splitting and the
/// tool-use tally never build a String, and only lines that look like they
/// carry usage are handed to JSONSerialization.
struct TranscriptStats: Codable {
    var model: String?
    private var readerState: BoundedTraceReader.State?
    private var readIssue: String?
    private var numericIssue: String?
    private var backlog: Bool?
    var usageIssue: String? {
        numericIssue ?? readIssue ?? (backlog == true ? "Transcript history is still being read. Usage figures are unavailable until it catches up." : nil)
    }
    var toolCalls: Int = 0
    struct TokenFacts: Codable {
        var input = 0
        var output = 0
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        var cacheRead = 0
    }
    /// Raw billable facts survive pricing edits; dollars are derived on read.
    private var usageByModel: [String: TokenFacts] = [:]
    var costUSD: Double? { estimatedCost(Pricing.rate) }
    var hasUsageFacts: Bool { !usageByModel.isEmpty }
    /// Tokens in the model's context as of the last assistant turn.
    var contextTokens: Int?
    var lastActivity: Date?
    /// When the agent's own last scheduling call says it will wake again.
    ///
    /// An agent in a loop records the call it makes — `ScheduleWakeup` with a
    /// delay, or `stop: true` to end. That is its own declaration, not
    /// something inferred from how regularly it happens to be busy: measured
    /// against real sessions, cadence tells a looping agent and an idle one
    /// apart not at all.
    var loopWakeAt: Date?
    /// The last scheduling call ended the loop.
    var loopStopped = false
    /// Assistant turns per 10-minute bucket, keyed by absolute bucket index
    /// (epoch / 600). Absolute keys mean incremental parsing keeps working —
    /// new lines just land in newer buckets.
    var activity: [Int: Int] = [:]
    /// Tokens actually transmitted per bucket. "Sent" excludes cache reads —
    /// those are re-used server-side, not re-uploaded, and at millions of
    /// tokens they would flatten everything else to nothing.
    var sent: [Int: Int] = [:]
    var received: [Int: Int] = [:]
    /// Whole-session totals. The bucketed series only covers six hours; these
    /// answer "how much has this agent actually moved?".
    var sentTokens: Int = 0
    var receivedTokens: Int = 0
    /// How far into the file we've already accounted for.
    fileprivate var consumed: Int = 0

    nonisolated(unsafe) private static var cache: [String: TranscriptStats] = [:]
    private static let lock = NSLock()
    /// Versioned: a cache written before the token series existed can't be
    /// decoded into the current shape, and silently dropping it would look
    /// like a bug rather than a migration.
    private static let cacheURL = Config.directory.appendingPathComponent("transcripts-v6.json")

    /// Caches from earlier formats. Each version bump orphaned its predecessor
    /// in the user's folder, where three of these had accumulated — files the
    /// app writes are the app's to clean up.
    private static let supersededCaches = [
        "transcripts.json", "transcripts-v2.json", "transcripts-v3.json",
        "transcripts-v4.json", "transcripts-v5.json",
    ]

    @discardableResult
    mutating func recordUsage(model: String?, input: Int, output: Int,
                              cacheWrite5m: Int, cacheWrite1h: Int,
                              cacheRead: Int) -> Bool {
        guard numericIssue == nil else { return false }
        let key = String((model ?? "").prefix(256))
        guard usageByModel[key] != nil || usageByModel.count < 128 else {
            numericIssue = "Transcript contains too many model variants. Usage figures are unavailable."
            return false
        }
        let old = usageByModel[key] ?? TokenFacts()
        guard let i = Self.add(old.input, input), let o = Self.add(old.output, output),
              let w5 = Self.add(old.cacheWrite5m, cacheWrite5m),
              let w1 = Self.add(old.cacheWrite1h, cacheWrite1h),
              let r = Self.add(old.cacheRead, cacheRead) else {
            numericIssue = "Transcript usage values are invalid or out of range. Usage figures are unavailable."
            return false
        }
        usageByModel[key] = TokenFacts(input: i, output: o, cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: r)
        return true
    }

    private static func add(_ values: Int...) -> Int? {
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    func estimatedCost(_ rateFor: (String?) -> Pricing.Rate?) -> Double? {
        guard usageIssue == nil, !usageByModel.isEmpty else { return nil }
        var total = 0.0
        for (key, usage) in usageByModel {
            guard let rate = rateFor(key.isEmpty ? nil : key),
                  [rate.input, rate.output, rate.cacheWrite5m, rate.cacheWrite1h, rate.cacheRead]
                    .allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            total += Double(usage.input) / 1_000_000 * rate.input
                + Double(usage.output) / 1_000_000 * rate.output
                + Double(usage.cacheWrite5m) / 1_000_000 * rate.cacheWrite5m
                + Double(usage.cacheWrite1h) / 1_000_000 * rate.cacheWrite1h
                + Double(usage.cacheRead) / 1_000_000 * rate.cacheRead
            guard total.isFinite else { return nil }
        }
        return total
    }

    static func removeSupersededCaches() {
        for name in supersededCaches {
            try? FileManager.default.removeItem(at: Config.directory.appendingPathComponent(name))
        }
    }

    /// Persisting consumed offsets and running totals means a relaunch resumes
    /// where the last process stopped instead of rereading transcript history.
    static func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: TranscriptStats].self, from: data)
        else { return }
        lock.lock(); cache = stored; lock.unlock()
    }

    static func saveCache() {
        lock.lock()
        // Same reasoning as the harness cache: a transcript that has been
        // deleted should not keep a row in this file for ever.
        cache = cache.filter { FileManager.default.fileExists(atPath: $0.key) }
        let snapshot = cache
        lock.unlock()
        guard !snapshot.isEmpty, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Pulls the loop's own bookkeeping out of a scheduling call. Later calls
    /// overwrite earlier ones, so what survives is the current intent.
    private static func readScheduling(_ line: Data, into stats: inout TranscriptStats) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = d["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        let stamp = (d["timestamp"] as? String).flatMap(UsageHTTP.parseDate)

        for block in blocks where (block["type"] as? String) == "tool_use" {
            guard let name = block["name"] as? String,
                  name == "ScheduleWakeup" || name == "CronCreate" else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            if (input["stop"] as? Bool) == true {
                stats.loopStopped = true
                stats.loopWakeAt = nil
                continue
            }
            stats.loopStopped = false
            if let delay = input["delaySeconds"] as? Double, delay.isFinite, delay >= 0, delay <= 31_536_000, let stamp {
                stats.loopWakeAt = stamp.addingTimeInterval(delay)
            } else if let stamp {
                // A cron loop has no single next time we can read; record that
                // one exists so the row can still say the agent is looping.
                stats.loopWakeAt = stamp
            }
        }
    }

    private static let usageNeedle = Array(#""usage""#.utf8)
    private static let toolNeedle = Array(#""tool_use""#.utf8)
    private static let loopNeedle = Array(#"ScheduleWakeup"#.utf8)
    private static let cronNeedle = Array(#"CronCreate"#.utf8)
    private static let newline = UInt8(0x0A)

    static let bucketSeconds = 600
    static let historyHours = 6

    /// Counts per bucket across the last `historyHours`, oldest first.
    func activitySeries(now: Date = Date()) -> [Int] { Self.series(from: activity, now: now) }

    /// Shared with the other agents so every sparkline covers the same window.
    static func series(from buckets: [Int: Int], now: Date = Date()) -> [Int] {
        let count = historyHours * 3600 / bucketSeconds
        guard let epoch = Int(exactly: now.timeIntervalSince1970.rounded(.towardZero)) else { return Array(repeating: 0, count: count) }
        let newest = epoch / bucketSeconds
        return (0..<count).map { buckets[newest - (count - 1 - $0)] ?? 0 }
    }

    static func of(_ url: URL) -> TranscriptStats? {
        lock.lock()
        var stats = cache[url.path] ?? TranscriptStats()
        lock.unlock()
        // Older persisted offsets have no file identity and cannot safely be
        // attached to today's file. Rebuild once through the bounded reader.
        if stats.readerState == nil { stats = TranscriptStats() }
        do {
            let batch = try BoundedTraceReader.read(url, state: stats.readerState ?? .init(),
                onReset: { stats = TranscriptStats() }) { line in
                    consume(line, into: &stats)
                }
            stats.readerState = batch.state
            stats.consumed = Int(clamping: batch.state.offset)
            stats.backlog = batch.backlogged
            if batch.skipped > 0 {
                stats.readIssue = "Some transcript records exceeded the read limit. Usage figures are unavailable."
            }
        } catch { return nil }

        let cutoff = Int(Date().timeIntervalSince1970) / bucketSeconds
            - (historyHours * 3600 / bucketSeconds)
        stats.activity = stats.activity.filter { $0.key >= cutoff }
        stats.sent = stats.sent.filter { $0.key >= cutoff }
        stats.received = stats.received.filter { $0.key >= cutoff }

        lock.lock(); cache[url.path] = stats; lock.unlock()
        return stats
    }

    /// Cheap byte tests first; JSON decoding only for lines that carry usage.
    private static func consume(_ line: Data, into stats: inout TranscriptStats) {
        var pendingBucket: Int?
        guard !line.isEmpty else { return }
        let (hasTools, hasUsage, hasSchedule) = line.withUnsafeBytes {
            (raw: UnsafeRawBufferPointer) -> (Bool, Bool, Bool) in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (contains(toolNeedle, in: bytes), contains(usageNeedle, in: bytes),
                    contains(loopNeedle, in: bytes) || contains(cronNeedle, in: bytes))
        }
        guard hasTools || hasUsage || hasSchedule else { return }
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            stats.readIssue = "Some transcript records were invalid. Usage figures are unavailable."
            return
        }
        let message = d["message"] as? [String: Any] ?? [:]
        if hasTools, let content = message["content"] as? [[String: Any]] {
            let tools = content.filter { ($0["type"] as? String) == "tool_use" }.count
            if let total = add(stats.toolCalls, tools) { stats.toolCalls = total }
            else { stats.numericIssue = "Transcript tool count is out of range. Usage figures are unavailable." }
        }
        if hasSchedule { readScheduling(line, into: &stats) }
        guard hasUsage, let usage = message["usage"] as? [String: Any] else { return }

        // Claude Code injects messages tagged "<synthetic>"; they'd otherwise
        // become the session's reported model just by being last.
        let currentModel = (message["model"] as? String).flatMap {
            !$0.isEmpty && !$0.hasPrefix("<") && $0.utf8.count <= 256 ? $0 : nil
        }
        if let currentModel { stats.model = currentModel }
        if let ts = d["timestamp"] as? String, let date = UsageHTTP.parseDate(ts) {
            stats.lastActivity = date
            let bucket = Int(date.timeIntervalSince1970) / Self.bucketSeconds
            stats.activity[bucket, default: 0] += 1
            pendingBucket = bucket
        }

        // Required message totals must be present. The API's optional cache
        // fields may be absent/null; a supplied TTL breakdown must be complete.
        let creation: [String:Any]
        if let raw = usage["cache_creation"], !(raw is NSNull) {
            guard let object = raw as? [String:Any],
                  object["ephemeral_5m_input_tokens"] != nil,
                  object["ephemeral_1h_input_tokens"] != nil else {
                stats.numericIssue = "Transcript cache usage is incomplete or unsupported. Usage figures are unavailable."
                return
            }
            creation = object
        } else { creation = [:] }
        func usageCount(_ object: [String: Any], _ key: String, required:Bool = false) -> Int? {
            guard let raw = object[key], !(raw is NSNull) else { return required ? nil : 0 }
            return FieldPath.integer(raw).flatMap { $0 >= 0 ? $0 : nil }
        }
        guard let input = usageCount(usage, "input_tokens",required:true),
              let output = usageCount(usage, "output_tokens",required:true),
              let w5 = usageCount(creation, "ephemeral_5m_input_tokens",required:!creation.isEmpty),
              let w1 = usageCount(creation, "ephemeral_1h_input_tokens",required:!creation.isEmpty),
              let writeTotal = usageCount(usage, "cache_creation_input_tokens"),
              let read = usageCount(usage, "cache_read_input_tokens"),
              let classified = add(w5, w1),
              let write5 = add(w5, max(0, writeTotal - classified)),
              let write = add(write5, w1), let sent = add(input, write),
              let context = add(sent, read), let sentTotal = add(stats.sentTokens, sent),
              let receivedTotal = add(stats.receivedTokens, output),
              stats.recordUsage(model: currentModel, input: input, output: output,
                                cacheWrite5m: write5, cacheWrite1h: w1, cacheRead: read) else {
            stats.numericIssue = "Transcript usage values are invalid or out of range. Usage figures are unavailable."
            return
        }
        stats.contextTokens = context
        stats.sentTokens = sentTotal
        stats.receivedTokens = receivedTotal
        if let bucket = pendingBucket {
            guard let sentBucket = add(stats.sent[bucket, default: 0], sent),
                  let receivedBucket = add(stats.received[bucket, default: 0], output) else {
                stats.numericIssue = "Transcript usage values are out of range. Usage figures are unavailable."
                return
            }
            stats.sent[bucket] = sentBucket; stats.received[bucket] = receivedBucket
        }

    }

    // MARK: - Byte helpers

    private static func contains(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> Bool {
        count(of: needle, in: hay, stopAtFirst: true) > 0
    }

    private static func count(of needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>,
                              stopAtFirst: Bool = false) -> Int {
        guard needle.count <= hay.count, let first = needle.first else { return 0 }
        var found = 0
        var i = 0
        let limit = hay.count - needle.count
        while i <= limit {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count {
                    found += 1
                    if stopAtFirst { return found }
                    i += needle.count
                    continue
                }
            }
            i += 1
        }
        return found
    }

}
