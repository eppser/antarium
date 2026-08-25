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
        let container: [String: Any] = map.root.flatMap { FieldPath.lookup(json, $0) as? [String: Any] }
            ?? json
        let keys = map.keys ?? container.keys.sorted()

        var gauges: [Gauge] = []
        for key in keys {
            guard let window = container[key] as? [String: Any] else { continue }
            // A window the plan does not include is not a window at zero.
            if let require = map.require,
               require.contains(where: { (window[$0.key] as? Bool) != $0.value }) { continue }
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
                badge: named.map { $0.count <= 4 ? $0.uppercased()
                                                 : String($0.prefix(3)).uppercased() }
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
        gauges.sort { ($0.windowSeconds ?? .greatestFiniteMagnitude)
                    < ($1.windowSeconds ?? .greatestFiniteMagnitude) }

        return Snapshot(providerID: id, gauges: gauges, extras: [],
                        accountLabel: quota.accountLabel.flatMap { FieldPath.lookup(json, $0) as? String },
                        fetchedAt: Date())
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
