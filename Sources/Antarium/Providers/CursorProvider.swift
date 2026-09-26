import Foundation
import SQLite3

/// Cursor plan usage from the private Connect endpoint the IDE's billing dashboard uses.
///
/// Verified against a live Pro account: `GetCurrentPeriodUsage` reports
/// `planUsage.totalPercentUsed`, `.autoPercentUsed`, and `.apiPercentUsed`
/// against the included allowance, plus `billingCycleEnd` in epoch milliseconds.
/// The legacy `GET /auth/usage` request buckets are kept as a fallback for
/// Enterprise-style accounts that still expose `maxRequestUsage`.
final class CursorProvider: UsageProvider, @unchecked Sendable {
    let id = "cursor"
    let displayName = "Cursor"
    var setupHint: String { "Sign in to Cursor in the desktop app." }
    let isVerified = true

    private static let apiBase = "https://api2.cursor.sh"
    private static let accessTokenKey = "cursorAuth/accessToken"

    private let session = UsageHTTP.makeSession(headers: [
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    /// Memoised: answering opens Cursor's SQLite state store, and this is
    /// read from a SwiftUI body.
    var isConfigured: Bool {
        ConfiguredProbe.value(id) { accessToken() != nil }
    }

    func fetch() async throws -> Snapshot {
        guard let token = accessToken() else {
            throw ProviderError.notConfigured("Cursor isn't signed in on this Mac.")
        }

        let headers = authHeaders(token)
        let usageURL = URL(string: "\(Self.apiBase)/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        let planURL = URL(string: "\(Self.apiBase)/aiserver.v1.DashboardService/GetPlanInfo")!

        let usage = try await UsageHTTP.postJSON(usageURL, body: [:], headers: headers, session: session)

        var planName: String? = nil
        if let planJSON = try? await UsageHTTP.postJSON(planURL, body: [:], headers: headers, session: session),
           let info = planJSON["planInfo"] as? [String: Any],
           let name = info["planName"] as? String, !name.isEmpty {
            planName = name
        }

        do {
            return try Self.makeSnapshot(usage, planName: planName)
        } catch let err as ProviderError {
            guard case .unsupported = err else { throw err }
            let legacyURL = URL(string: "\(Self.apiBase)/auth/usage")!
            let legacy = try await UsageHTTP.getJSON(legacyURL, headers: ["Authorization": "Bearer \(token)"],
                                                     session: session)
            return try Self.makeSnapshotFromLegacy(legacy, planName: planName)
        }
    }

    // MARK: - Credentials

    private func accessToken() -> String? { Self.accessToken() }

    static func accessToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CURSOR_SESSION_TOKEN"],
           !env.isEmpty { return env }
        return readTokenFromStateDB()
    }

    static func stateDBURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func readTokenFromStateDB(_ url: URL = stateDBURL()) -> String? {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = '\(accessTokenKey)'"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func authHeaders(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
        ]
    }

    // MARK: - Parsing

    static func makeSnapshot(_ usage: [String: Any], planName: String?) throws -> Snapshot {
        guard let planUsage = usage["planUsage"] as? [String: Any] else {
            throw ProviderError.unsupported("Cursor reported no plan usage.")
        }

        let resetsAt = billingCycleEnd(usage)
        let candidates = [
            percentGauge(id: "total", badge: "ALL", title: "Included total",
                         planUsage: planUsage, key: "totalPercentUsed", resetsAt: resetsAt),
            percentGauge(id: "auto", badge: "AUTO", title: "Auto mode",
                         planUsage: planUsage, key: "autoPercentUsed", resetsAt: resetsAt),
            percentGauge(id: "api", badge: "API", title: "Named models",
                         planUsage: planUsage, key: "apiPercentUsed", resetsAt: resetsAt),
        ].compactMap { $0 }

        guard !candidates.isEmpty else {
            throw ProviderError.unsupported("Cursor reported no trustworthy usage window.")
        }

        let total = candidates.first { $0.id == "total" }
        let others = candidates.filter { $0.id != "total" }.sorted { $0.used > $1.used }
        guard let primary = total ?? others.first else {
            throw ProviderError.unsupported("Cursor reported no trustworthy usage window.")
        }

        var gauges = [primary]
        if let second = (total != nil ? others.first : others.dropFirst().first) {
            gauges.append(second)
        }
        let shown = Set(gauges.map(\.id))
        let extras = candidates.filter { !shown.contains($0.id) }

        Log.info("cursor", "Usage response parsed: \(gauges.count) primary windows, \(extras.count) additional windows.")

        return Snapshot(providerID: "cursor", gauges: gauges, extras: extras,
                        accountLabel: planName, fetchedAt: Date())
    }

    static func makeSnapshotFromLegacy(_ json: [String: Any], planName: String?) throws -> Snapshot {
        var gauges: [Gauge] = []

        for (key, value) in json {
            guard key != "startOfMonth", let bucket = value as? [String: Any] else { continue }
            guard let max = intValue(bucket["maxRequestUsage"]), max > 0,
                  let used = intValue(bucket["numRequests"]) else { continue }
            let percent = Double(used) / Double(max) * 100
            let badge = Gauge.badge(from: key)
            gauges.append(Gauge(id: key, badge: badge, title: key,
                                used: Swift.min(Swift.max(percent / 100, 0), 1), resetsAt: nil,
                                reportedSeverity: .normal))
        }

        guard !gauges.isEmpty else {
            throw ProviderError.unsupported("Cursor reported no trustworthy usage window.")
        }

        gauges = ordered(gauges)
        let primary = gauges[0]
        let extras = gauges.count > 1 ? Array(gauges.dropFirst()) : []

        return Snapshot(providerID: "cursor", gauges: [primary], extras: extras,
                        accountLabel: planName, fetchedAt: Date())
    }

    /// Fullest first, and ties broken on the bucket's name.
    ///
    /// The buckets come out of a dictionary, whose order differs between
    /// processes, and Swift's sort is not stable — so two buckets at the same
    /// percentage produced a different primary gauge on different launches,
    /// for the same account and the same response. Same reasoning as the glob
    /// search and first-run detection, both of which break their ties on a
    /// name.
    ///
    /// Callable, because the ordering cannot be checked through the dictionary
    /// that feeds it: within one process that dictionary yields the same order
    /// every time, so a test driving it agrees with itself whether ties are
    /// broken or not. An array is an input a test can actually choose.
    static func ordered(_ gauges: [Gauge]) -> [Gauge] {
        gauges.sorted { ($0.used, $1.id) > ($1.used, $0.id) }
    }

    private static func percentGauge(id: String, badge: String, title: String,
                                     planUsage: [String: Any], key: String,
                                     resetsAt: Date?) -> Gauge? {
        guard let percent = doubleValue(planUsage[key]) else { return nil }
        return Gauge(id: id, badge: badge, title: title,
                     used: Swift.min(Swift.max(percent / 100, 0), 1), resetsAt: resetsAt,
                     reportedSeverity: .normal)
    }

    private static func billingCycleEnd(_ usage: [String: Any]) -> Date? {
        if let raw = usage["billingCycleEnd"] as? String, let value = Double(raw) {
            return FieldPath.epoch(value)
        }
        if let value = doubleValue(usage["billingCycleEnd"]) {
            return FieldPath.epoch(value)
        }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as String: return Double(v)
        default: return nil
        }
    }

    /// A request count from the response.
    ///
    /// `Int(someDouble)` traps on anything outside `Int`'s range and on NaN,
    /// and every number here came off the network. `1e30` in
    /// `maxRequestUsage` took the whole app down on SIGTRAP rather than
    /// reporting a bad response. `exactly:` gives nothing instead, and a
    /// bucket with no readable maximum is already skipped.
    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let v as Int: return v
        case let v as Double: return Int(exactly: v.rounded())
        default: return nil
        }
    }
}
