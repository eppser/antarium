import Foundation

/// Per-million-token list prices, used to estimate what a session *would* have
/// cost on the API. On a subscription plan no money actually changes hands —
/// the figure is a size signal, not a bill, and the dashboard labels it as an
/// estimate.
enum Pricing {
    struct Rate {
        let input: Double        // $ per 1M input tokens
        let output: Double       // $ per 1M output tokens
        /// Explicit rather than inferred: cache policy and provider pricing are
        /// data, and silently applying one vendor's multiplier to another is a
        /// plausible-looking wrong total.
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let contextWindow: Int
    }

    /// Loaded from `Resources/pricing.json`, then from
    /// `~/.antarium/pricing.json` if it exists — prices change more often than
    /// this app does, and correcting one shouldn't need a rebuild. Longest
    /// prefix first, so `claude-opus-5[1m]` and dated variants resolve to the
    /// family rate rather than a shorter prefix that happens to also match.
    private struct Entry: Codable {
        let prefix: String
        let input: Double
        let output: Double
        let cacheWrite5m: Double?
        let cacheWrite1h: Double?
        let cacheRead: Double?
        let contextWindow: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached:
        (stamp: String, checked: Date, table: [(prefix: String, rate: Rate)])?

    /// Rebuilt when `~/.antarium/pricing.json` changes, so a corrected rate
    /// applies at the next scan instead of at the next launch. The bundled
    /// table cannot change without a new build, so only the user's file is
    /// stamped.
    private static var table: [(prefix: String, rate: Rate)] {
        let mine = Config.directory.appendingPathComponent("pricing.json")
        lock.lock()
        if let cached, cached.checked.timeIntervalSinceNow > -1 {
            lock.unlock(); return cached.table
        }
        lock.unlock()
        let stamp = FileStamp.of(mine)
        lock.lock()
        if let cached, cached.stamp == stamp {
            self.cached = (stamp, Date(), cached.table)
            lock.unlock(); return cached.table
        }
        lock.unlock()
        let built = build()
        lock.lock(); cached = (stamp, Date(), built); lock.unlock()
        return built
    }

    private static func build() -> [(prefix: String, rate: Rate)] {
        func load(_ url: URL?) -> [Entry] {
            guard let url, let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"],
                  let raw = try? JSONSerialization.data(withJSONObject: models),
                  let entries = try? JSONDecoder().decode([Entry].self, from: raw)
            else { return [] }
            return entries
        }
        let bundled = load(AppResources.bundle.url(
            forResource: "pricing", withExtension: "json"))
        let mine = load(Config.directory.appendingPathComponent("pricing.json"))
        if bundled.isEmpty && mine.isEmpty {
            NSLog("Antarium: no pricing table found; spend will be blank")
        }
        // The user's entries are consulted first, then the longest prefix wins.
        return (mine + bundled)
            .sorted { $0.prefix.count > $1.prefix.count }
            .compactMap { entry in
                guard let cacheWrite = entry.cacheWrite5m,
                      let cacheWrite1h = entry.cacheWrite1h,
                      let cacheRead = entry.cacheRead else {
                    Log.warn("pricing", "Ignoring an entry with missing cache rates.")
                    return nil
                }
                return (entry.prefix, Rate(input: entry.input, output: entry.output,
                                           cacheWrite5m: cacheWrite,
                                           cacheWrite1h: cacheWrite1h,
                                           cacheRead: cacheRead,
                                           contextWindow: entry.contextWindow))
            }
    }

    static func rate(for model: String?) -> Rate? {
        guard let model = model?.lowercased() else { return nil }
        return table.first { model.hasPrefix($0.prefix) }?.rate
    }

    static func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Short label for the menu bar dashboard: "Opus 5", "Sonnet 5".
    static func shortName(_ model: String?) -> String? {
        guard var s = model, !s.isEmpty else { return nil }
        if let bracket = s.firstIndex(of: "[") { s = String(s[s.startIndex..<bracket]) }

        if s.hasPrefix("claude-") {
            let parts = s.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
            guard let family = parts.first else { return nil }
            let version = parts.dropFirst().joined(separator: ".")
            return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
        }

        // Provider-qualified ids ("~openai/gpt-latest", "mlx-community/Qwen3")
        // carry the model after the slash; the prefix is routing, not identity.
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        while s.hasPrefix("~") { s.removeFirst() }

        // Other providers: drop the "-latest" churn and keep it to two words so
        // the row stays compact.
        let words = s.split(separator: "-").map(String.init)
            .filter { $0 != "latest" && $0 != "preview" }
        let pretty = words.prefix(2).map { word -> String in
            ["gpt", "o1", "o3", "glm", "k2"].contains(word.lowercased())
                ? word.uppercased() : word.capitalized
        }
        return pretty.joined(separator: " ")
    }

    static func money(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10 { return String(format: "$%.1f", usd) }
        if usd >= 0.01 { return String(format: "$%.2f", usd) }
        return usd > 0 ? "<$0.01" : "$0"
    }
}
