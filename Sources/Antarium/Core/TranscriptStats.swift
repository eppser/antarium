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
    var costUSD: Double { estimatedCost(Pricing.rate) }
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
    private static let cacheURL = Config.directory.appendingPathComponent("transcripts-v5.json")

    /// Caches from earlier formats. Each version bump orphaned its predecessor
    /// in the user's folder, where three of these had accumulated — files the
    /// app writes are the app's to clean up.
    private static let supersededCaches = [
        "transcripts.json", "transcripts-v2.json", "transcripts-v3.json",
        "transcripts-v4.json",
    ]

    mutating func recordUsage(model: String?, input: Int, output: Int,
                              cacheWrite5m: Int, cacheWrite1h: Int,
                              cacheRead: Int) {
        let key = model ?? ""
        usageByModel[key, default: TokenFacts()].input += input
        usageByModel[key, default: TokenFacts()].output += output
        usageByModel[key, default: TokenFacts()].cacheWrite5m += cacheWrite5m
        usageByModel[key, default: TokenFacts()].cacheWrite1h += cacheWrite1h
        usageByModel[key, default: TokenFacts()].cacheRead += cacheRead
    }

    func estimatedCost(_ rateFor: (String?) -> Pricing.Rate?) -> Double {
        usageByModel.reduce(0) { total, item in
            let model = item.key.isEmpty ? nil : item.key
            guard let rate = rateFor(model) else { return total }
            let usage = item.value
            return total
                + Double(usage.input) / 1_000_000 * rate.input
                + Double(usage.output) / 1_000_000 * rate.output
                + Double(usage.cacheWrite5m) / 1_000_000 * rate.cacheWrite5m
                + Double(usage.cacheWrite1h) / 1_000_000 * rate.cacheWrite1h
                + Double(usage.cacheRead) / 1_000_000 * rate.cacheRead
        }
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
            if let delay = input["delaySeconds"] as? Double, let stamp {
                stats.loopWakeAt = stamp.addingTimeInterval(delay)
            } else if let stamp {
                // A cron loop has no single next time we can read; record that
                // one exists so the row can still say the agent is looping.
                stats.loopWakeAt = stamp
            }
        }
    }

    private static let usageNeedle = Array(#""usage""#.utf8)
    private static let toolNeedle = Array(#""type":"tool_use""#.utf8)
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
        let newest = Int(now.timeIntervalSince1970) / bucketSeconds
        return (0..<count).map { buckets[newest - (count - 1 - $0)] ?? 0 }
    }

    static func of(_ url: URL) -> TranscriptStats? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0

        lock.lock()
        var stats = cache[url.path] ?? TranscriptStats()
        lock.unlock()

        // A file that shrank was rotated or replaced — start over.
        if size < stats.consumed { stats = TranscriptStats() }
        if size == stats.consumed && stats.consumed > 0 { return stats }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if stats.consumed > 0 {
            do { try handle.seek(toOffset: UInt64(stats.consumed)) } catch { return nil }
        }

        // Read in bounded chunks rather than slurping the file: a first pass
        // over hundreds of megabytes would otherwise push the whole app's
        // resident memory up by that much.
        let chunkSize = 1 << 20
        var carry = Data()                    // partial line spanning a boundary
        while true {
            // JSONSerialization hands back autoreleased objects. Without a pool
            // per chunk they pile up until the enclosing pool drains, which over
            // a few hundred megabytes of transcript meant ~200 MB of resident
            // memory that looked like a leak.
            let done = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return true
                }
                var buffer = carry
                buffer.append(chunk)
                carry = Data()

                var lineStart = buffer.startIndex
                var index = buffer.startIndex
                while index < buffer.endIndex {
                    if buffer[index] == newline {
                        consume(buffer[lineStart..<index], into: &stats)
                        lineStart = buffer.index(after: index)
                    }
                    index = buffer.index(after: index)
                }
                if lineStart < buffer.endIndex {
                    carry = Data(buffer[lineStart..<buffer.endIndex])
                }
                stats.consumed += chunk.count
                return false
            }
            if done { break }
        }
        // A trailing partial line stays unaccounted until it's finished.
        stats.consumed -= carry.count

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
        let (tools, hasUsage, hasSchedule) = line.withUnsafeBytes {
            (raw: UnsafeRawBufferPointer) -> (Int, Bool, Bool) in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (count(of: toolNeedle, in: bytes),
                    contains(usageNeedle, in: bytes),
                    contains(loopNeedle, in: bytes) || contains(cronNeedle, in: bytes))
        }
        stats.toolCalls += tools
        if hasSchedule { readScheduling(line, into: &stats) }
        guard hasUsage else { return }

        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = d["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        // Claude Code injects messages tagged "<synthetic>"; they'd otherwise
        // become the session's reported model just by being last.
        if let model = message["model"] as? String,
           !model.isEmpty, !model.hasPrefix("<") {
            stats.model = model
        }
        if let ts = d["timestamp"] as? String, let date = UsageHTTP.parseDate(ts) {
            stats.lastActivity = date
            let bucket = Int(date.timeIntervalSince1970) / Self.bucketSeconds
            stats.activity[bucket, default: 0] += 1
            pendingBucket = bucket
        }

        let input = int(usage["input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheCreation = usage["cache_creation"] as? [String: Any]
        var cacheWrite5m = int(cacheCreation?["ephemeral_5m_input_tokens"])
        let cacheWrite1h = int(cacheCreation?["ephemeral_1h_input_tokens"])
        let cacheWriteTotal = int(usage["cache_creation_input_tokens"])
        // Older records predate the TTL breakdown. Cache entries were
        // five-minute by default; any unclassified aggregate belongs there.
        cacheWrite5m += max(cacheWriteTotal - cacheWrite5m - cacheWrite1h, 0)
        let cacheRead = int(usage["cache_read_input_tokens"])
        stats.recordUsage(model: stats.model, input: input, output: output,
                          cacheWrite5m: cacheWrite5m,
                          cacheWrite1h: cacheWrite1h,
                          cacheRead: cacheRead)

        // Context at this turn is everything the model was shown.
        let cacheWrite = cacheWrite5m + cacheWrite1h
        stats.contextTokens = input + cacheWrite + cacheRead
        stats.sentTokens += input + cacheWrite
        stats.receivedTokens += output
        if let bucket = pendingBucket {
            stats.sent[bucket, default: 0] += input + cacheWrite
            stats.received[bucket, default: 0] += output
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

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }
}
