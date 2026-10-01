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

    /// The rates and the day they were taken, built together.
    ///
    /// `asOf` used to read both files itself on every call, and it is called
    /// from a tooltip inside a SwiftUI body — once per row, on every render.
    /// Reading it here costs one parse that was already happening.
    struct Table {
        let rates: [(prefix: String, rate: Rate)]
        let asOf: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached:
        (stamp: String, checked: Date, table: Table)?

    /// Rebuilt when `~/.antarium/pricing.json` changes, so a corrected rate
    /// applies at the next scan instead of at the next launch. The bundled
    /// table cannot change without a new build, so only the user's file is
    /// stamped.
    private static var table: Table {
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

    /// The day the rates were taken from the vendor's published page, as the
    /// table states it, or nothing when no table says.
    ///
    /// The file has carried this since it was written and nothing read it. A
    /// cost is presented as an estimate everywhere it appears, and an
    /// estimate rests on prices from a particular day: if a vendor changes
    /// theirs, every figure here is quietly wrong and the row says only that
    /// it was an estimate, never of when. The user's own table wins, as it
    /// does for the rates themselves.
    static var asOf: String? { table.asOf }

    /// One table file, parsed once for both the rates and the day.
    ///
    /// Bounded like every other file this app reads: the user's copy is
    /// hand-edited local configuration, and a reader with no ceiling is a
    /// reader that a mistyped path can hand a very large file to.
    private static func load(_ url: URL?) -> (entries: [Entry], asOf: String?) {
        guard let url, let data = try? BoundedFile.read(url, maxBytes: 4 * 1_024 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], nil) }
        let day = (object["asOf"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [Entry]
        if let models = object["models"],
           let raw = try? JSONSerialization.data(withJSONObject: models),
           let decoded = try? JSONDecoder().decode([Entry].self, from: raw) {
            entries = decoded
        } else {
            entries = []
        }
        return (entries, day?.isEmpty == false ? day : nil)
    }

    private static func build() -> Table {
        let bundledFile = load(AppResources.bundle.url(
            forResource: "pricing", withExtension: "json"))
        let myFile = load(Config.directory.appendingPathComponent("pricing.json"))
        let bundled = bundledFile.entries, mine = myFile.entries
        if bundled.isEmpty && mine.isEmpty {
            NSLog("Antarium: no pricing table found; spend will be blank")
        }
        // The user's entries are consulted first, then the longest prefix wins.
        // The user's day wins for the same reason their rates do — if they
        // corrected the table, the correction's date is the honest one.
        let rates = (mine + bundled)
            .sorted { $0.prefix.count > $1.prefix.count }
            .compactMap { entry -> (prefix: String, rate: Rate)? in
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
        return Table(rates: rates, asOf: day(mine: myFile.asOf, bundled: bundledFile.asOf))
    }

    /// Which day a figure was priced on, when both tables state one.
    ///
    /// Separated out because `Config.directory` binds at first touch, so no
    /// test in this process can put a real second table on disk — and a
    /// precedence nothing can reach is a precedence nothing checks. Reversing
    /// it here would date every corrected rate to the day the app was built.
    static func day(mine: String?, bundled: String?) -> String? {
        mine ?? bundled
    }

    static func rate(for model: String?) -> Rate? {
        guard let model = model?.lowercased() else { return nil }
        return table.rates.first { model.hasPrefix($0.prefix) }?.rate
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
            // Drop the prefix, not every occurrence of it: `replacingOccurrences`
            // would also eat it out of the middle of an id.
            var parts = s.dropFirst("claude-".count).split(separator: "-")
            // Claude ids carry a release date — `claude-haiku-4-5-20251001` is
            // the shipped id for Haiku 4.5 — and joining every component after
            // the family put "Haiku 4.5.20251001" in the menu bar. A version
            // component is one or two digits; a date is not a version.
            while let last = parts.last, last.count >= 6, last.allSatisfy(\.isNumber) {
                parts.removeLast()
            }
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

    /// Four bands: whole dollars above a hundred, one decimal above ten,
    /// cents above a penny, and below that a statement that something was
    /// spent rather than a figure claiming nothing was.
    ///
    /// The band is chosen from the rounded figure where rounding can widen
    /// it. Choosing first and rounding second printed "$100.0" for 99.999 and
    /// "$10.00" for 9.999 — the narrower band's precision on a number that
    /// had just left it, which is the same mistake as a loop reading "loops
    /// in 60m".
    ///
    /// The last boundary is deliberately not rounded that way. Nine tenths of
    /// a cent rounds to a penny, and printing "$0.01" would claim a penny was
    /// spent when less was; "<$0.01" says what is true.
    static func money(_ usd: Double) -> String {
        // Widen when the figure *as the narrower band would print it* reads
        // as the boundary. Testing the whole-dollar rounding instead widens
        // everything from 99.50 up, which turns "$99.9" into "$100" and
        // loses a digit that was worth having.
        if ((usd * 10).rounded() / 10) >= 100 { return String(format: "$%.0f", usd) }
        if ((usd * 100).rounded() / 100) >= 10 { return String(format: "$%.1f", usd) }
        if usd >= 0.01 { return String(format: "$%.2f", usd) }
        return usd > 0 ? "<$0.01" : "$0"
    }
}
