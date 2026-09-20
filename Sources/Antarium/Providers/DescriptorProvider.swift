import Foundation

/// A quota provider described entirely by a config file.
///
/// The three built-in providers each hand-roll the same three steps: find a
/// token, call one endpoint, map the windows in the reply onto gauges. That is
/// data, not logic, so a `quota` block in a harness descriptor is enough to add
/// a whole new agent's usage bar without touching Swift.
///
/// What it deliberately cannot do is Claude's flow — Keychain access and OAuth
/// refresh are control flow, and pretending otherwise would mean a config
/// format that grows into a language.
final class DescriptorProvider: UsageProvider, @unchecked Sendable {
    private let descriptor: HarnessDescriptor
    private let quota: HarnessDescriptor.Quota
    private let session = UsageHTTP.makeSession(headers: [:])

    init?(_ descriptor: HarnessDescriptor) {
        guard let quota = descriptor.quota else { return nil }
        self.descriptor = descriptor
        self.quota = quota
    }

    var id: String { descriptor.id }
    var displayName: String { descriptor.name }
    var isVerified: Bool { quota.verified ?? false }
    var setupHint: String { quota.setupHint ?? "\(descriptor.name) isn't signed in on this Mac." }
    var signInCommand: String? { quota.signInCommand }

    /// Cheap and synchronous, as the protocol requires.
    ///
    /// This is read from inside a SwiftUI body, so it must not run a
    /// subprocess: spawning one pumps the run loop, which re-enters the view
    /// update and takes AttributeGraph down with a precondition failure. For a
    /// command credential the cheap question is "is the command there?" — the
    /// token itself is fetched later, off the main thread, in `fetch()`.
    var isConfigured: Bool {
        // Memoised for the same reason the native providers are: this is read
        // once per provider per settings redraw, and answering means a file
        // read or a PATH walk.
        ConfiguredProbe.value(id) { self.probeConfigured() }
    }

    private func probeConfigured() -> Bool {
        guard let credential = quota.credential else { return true }
        switch credential.kind {
        case "command":
            guard let command = credential.command else { return false }
            return command.contains("/")
                ? FileManager.default.isExecutableFile(atPath: command.expandingTilde)
                : Self.onPath(command) != nil
        default:
            return token() != nil
        }
    }

    // MARK: - Credentials

    private func token() -> String? {
        guard let credential = quota.credential else { return "" }   // endpoint needs none
        switch credential.kind {
        case "env":
            return credential.name.flatMap { ProcessInfo.processInfo.environment[$0] }
        case "command":
            guard let command = credential.command else { return nil }
            let path = command.contains("/") ? command.expandingTilde : Self.onPath(command)
            guard let path else { return nil }
            // Arguments name files too, so `~` has to mean the same thing there
            // — including inside a URI like `file:~/Library/...`, where it is
            // not the first character and so never got expanded.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let arguments = (credential.args ?? []).map {
                $0.expandingTilde.replacingOccurrences(of: "~/", with: home + "/")
            }
            let out = Shell.run(path, arguments, timeout: 10)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (out?.isEmpty == false) ? out : nil
        case "textFile":
            guard let path = credential.path?.expandingTilde,
                  let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case "jsonFile":
            guard let path = credential.path?.expandingTilde,
                  let field = credential.field,
                  let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // A shared file can hold another vendor's token in the same field.
            // Failing closed here means an unrecognised setup is reported as
            // not signed in, rather than as this vendor and sent to it.
            for (path, required) in credential.requires ?? [:] {
                guard let found = FieldPath.lookup(object, path) as? String,
                      found.lowercased().contains(required.lowercased())
                else { return nil }
            }
            return FieldPath.lookup(object, field) as? String
        default:
            return nil
        }
    }

    /// Where a bare command name lives. A GUI app's PATH is short, so the
    /// usual places are tried explicitly.
    private static func onPath(_ command: String) -> String? {
        let places = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return places.map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Fetch

    func fetch() async throws -> Snapshot {
        guard let token = token() else { throw ProviderError.notConfigured(setupHint) }
        guard let url = URL(string: quota.endpoint) else {
            throw ProviderError.badResponse("\(displayName)'s endpoint is not a URL.")
        }
        var headers = quota.headers ?? ["Authorization": "Bearer {token}"]
        headers = headers.mapValues { $0.replacingOccurrences(of: "{token}", with: token) }

        let json = try await UsageHTTP.getJSON(url, headers: headers, session: session)
        return try makeSnapshot(json)
    }

    func makeSnapshot(_ json: [String: Any]) throws -> Snapshot {
        let map = quota.windows

        var gauges: [Gauge] = []
        for (key, window) in Self.windows(in: json, map: map) {
            // A window the plan does not include is not a window at zero.
            if let require = map.require,
               require.contains(where: { (window[$0.key] as? Bool) != $0.value }) { continue }
            // A balance is charted instead of a percentage, not alongside
            // one: the two answer different questions and only one of them
            // can be a bar.
            if let path = map.balance {
                guard let value = FieldPath.number(window, path) else { continue }
                let named = map.labels?[key]
                gauges.append(Gauge(
                    id: key,
                    badge: map.badges?[key]?.uppercased()
                        ?? named.map { Gauge.badge(from: $0) }
                        ?? String(key.prefix(3)).uppercased(),
                    title: named ?? key,
                    used: 0,
                    resetsAt: map.resetsAt.flatMap { FieldPath.date(window, $0) ?? FieldPath.date(json, $0) },
                    reportedSeverity: .normal,
                    amount: Gauge.Amount(value: value,
                                         currency: Self.currency(map, window: window))))
                continue
            }
            let percent: Double
            if let path = map.usedPercent, let value = FieldPath.number(window, path) {
                percent = value
            } else if let path = map.percentRemaining, let value = FieldPath.number(window, path) {
                percent = 100 - value
            } else if let usedPath = map.used, let limitPath = map.limit,
                      let used = FieldPath.number(window, usedPath),
                      let limit = FieldPath.number(window, limitPath), limit > 0 {
                percent = used / limit * 100
            } else { continue }
            let span = map.windowSeconds.flatMap { FieldPath.number(window, $0) }
            let named = map.labels?[key]
            gauges.append(Gauge(
                id: key,
                badge: map.badges?[key]?.uppercased()
                    ?? named.map { Gauge.badge(from: $0) }
                    ?? Self.badge(seconds: span, fallback: key),
                title: named
                    ?? map.title.flatMap { FieldPath.lookup(window, $0) as? String }
                    ?? Self.badge(seconds: span, fallback: key),
                used: min(max(percent / 100, 0), 1),
                // Per window if it is there, otherwise the response's own —
                // Copilot states one reset date for every quota it reports.
                resetsAt: map.resetsAt.flatMap { FieldPath.date(window, $0) ?? FieldPath.date(json, $0) },
                reportedSeverity: .normal,
                windowSeconds: span))
        }
        guard !gauges.isEmpty else {
            throw ProviderError.unsupported("\(displayName) reported no usage window.")
        }
        // Shortest window first, so the fast-moving one is the top row.
        // Explicitly stable: `sort` is not, and a service that reports no
        // window length — Copilot — leaves every key equal, which would let
        // the menu bar reorder itself between refreshes for no reason.
        gauges = gauges.enumerated()
            .sorted {
                let left = $0.element.windowSeconds ?? .greatestFiniteMagnitude
                let right = $1.element.windowSeconds ?? .greatestFiniteMagnitude
                return left == right ? $0.offset < $1.offset : left < right
            }
            .map(\.element)

        return Snapshot(providerID: id, gauges: gauges, extras: [],
                        accountLabel: quota.accountLabel.flatMap { FieldPath.lookup(json, $0) as? String },
                        fetchedAt: Date())
    }

    /// The windows a response actually contains, in the order they should be
    /// drawn, named so a gauge has an id.
    ///
    /// Two shapes exist in the wild. Most services return an object whose
    /// member names *are* the window names — Copilot's `quota_snapshots`. Some
    /// return an array instead, where the name is a field inside each element
    /// — Z.ai's `data.limits` keyed by `type`, MiniMax's `model_remains` keyed
    /// by `model_name`. Neither shape is agent-specific logic, so both belong
    /// here rather than in a bespoke Swift provider.
    static func windows(in json: [String: Any],
                        map: HarnessDescriptor.Quota.Windows) -> [(key: String, window: [String: Any])] {
        var found: [(key: String, window: [String: Any])]
        if let path = map.list {
            let elements = FieldPath.lookup(json, path) as? [Any] ?? []
            found = elements.enumerated().compactMap { index, element in
                guard let window = element as? [String: Any] else { return nil }
                let parts = (map.key ?? []).compactMap { Self.name(window, $0) }
                let name = parts.joined(separator: "-")
                return (name.isEmpty ? "\(index)" : name, window)
            }
            // A list can repeat a name where an object cannot. Two gauges with
            // one id would be two identical-looking rows, so later duplicates
            // are numbered rather than dropped: the response said they were
            // different windows.
            var seen: [String: Int] = [:]
            found = found.map { entry in
                let count = (seen[entry.key] ?? 0) + 1
                seen[entry.key] = count
                return count == 1 ? entry : ("\(entry.key)-\(count)", entry.window)
            }
            // `keys`, when given, filters *and* orders — same contract as the
            // object shape, so a descriptor author reading one understands the
            // other. Entries sharing a key keep their response order.
            if let wanted = map.keys {
                found = wanted.flatMap { key in found.filter { $0.key == key } }
            }
        } else if let name = map.single {
            // A flat response — no per-window object exists, so the container
            // itself is the one window.
            let candidates = map.roots ?? map.root.map { [$0] } ?? []
            let container: [String: Any]? = candidates.isEmpty
                ? json
                : candidates.lazy.compactMap { FieldPath.lookup(json, $0) as? [String: Any] }.first
            found = container.map { [(name, $0)] } ?? []
        } else {
            // First candidate that actually resolves to an object. An absent
            // envelope is a different shape, not an empty one, so falling
            // through to the whole response is only correct when no path was
            // declared at all.
            let candidates = map.roots ?? map.root.map { [$0] } ?? []
            let container: [String: Any] = candidates
                .lazy
                .compactMap { FieldPath.lookup(json, $0) as? [String: Any] }
                .first ?? (candidates.isEmpty ? json : [:])
            // For an object the declared order is the drawing order.
            found = (map.keys ?? container.keys.sorted()).compactMap { key in
                (container[key] as? [String: Any]).map { (key, $0) }
            }
        }
        return found
    }

    /// The currency for a balance: a path into the window when the service
    /// reports one, otherwise the literal the descriptor gave. Defaults to USD
    /// only when nothing was declared at all — a descriptor that names a path
    /// and gets nothing back keeps the code it asked for rather than silently
    /// relabelling the money.
    static func currency(_ map: HarnessDescriptor.Quota.Windows,
                         window: [String: Any]) -> String {
        guard let declared = map.currency else { return "USD" }
        if let found = FieldPath.lookup(window, declared) as? String, !found.isEmpty {
            return found
        }
        return declared
    }

    /// One component of a composite window name. A key field is as likely to
    /// be a number as a string — Z.ai's `unit` is an integer — so both read as
    /// text, and a boolean is refused because "true" names nothing.
    private static func name(_ window: [String: Any], _ path: String) -> String? {
        let value = FieldPath.lookup(window, path)
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber:
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15
                ? String(Int64(double)) : String(double)
        default: return nil
        }
    }

    // MARK: - Helpers

    /// "5H", "7D" — derived from the window the service reports rather than
    /// assumed, because plans differ in which windows they even have.
    static func badge(seconds: Double?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return String(fallback.prefix(3)).uppercased() }
        let hours = seconds / 3600
        if hours < 24 { return "\(Int(hours.rounded()))H" }
        return "\(Int((hours / 24).rounded()))D"
    }




}
