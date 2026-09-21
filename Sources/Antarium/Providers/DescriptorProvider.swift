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

    /// Called when the registry replaces or drops this provider, because a
    /// session outlives the object that made it until it is invalidated.
    func releaseSession() { UsageHTTP.release(session) }

    /// Whether this provider's session is still live. The observable half of
    /// `releaseSession`, so a test can watch one object rather than a count
    /// every other suite is also moving.
    var sessionIsTracked: Bool { UsageHTTP.isTracked(session) }

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
        // A command quota is configured when its program is there. Falling
        // through to the credential branch answered `true` for every one of
        // them, because a command quota declares no credential and "no
        // credential needed" is a legitimate endpoint. So an agent that is
        // not installed would have been offered as signed in, and said so
        // until the first refresh failed.
        if let command = quota.command { return CommandPath.resolve(command) != nil }
        guard let credential = quota.credential else { return true }
        switch credential.kind {
        case "command":
            guard let command = credential.command else { return false }
            return CommandPath.resolve(command) != nil
        default:
            return token() != nil
        }
    }

    // MARK: - Credentials

    /// Internal so the bound on a credential command's output can be tested:
    /// `isConfigured` only asks whether the command resolves, and the output
    /// is the part that becomes a bearer token.
    /// The cap on a credential file, matching what the native providers use.
    ///
    /// These are written by another application, so they are input: Codex and
    /// Gemini read theirs through `BoundedFile` at this size and these two
    /// branches did not, which is the whole of the difference. A settings
    /// file large enough to matter is not a settings file.
    static let maxCredentialBytes = 256 * 1_024

    func token() -> String? {
        guard let credential = quota.credential else { return "" }   // endpoint needs none
        switch credential.kind {
        case "env":
            // The variable first, then the file, because a terminal launch
            // has the variable and a Finder launch does not.
            //
            // A menu bar app started from Finder inherits the launchd session
            // environment, not a shell's — the same fact the copilot harness
            // already relies on to read `gh auth token` instead of a variable.
            // So `env` on its own meant three shipped providers could not
            // work in the ordinary installation, and said "not signed in"
            // for ever while their setup hint described an action that was
            // not possible.
            if let name = credential.name,
               let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
                return value
            }
            guard let path = credential.path?.expandingTilde,
                  let data = try? BoundedFile.read(URL(fileURLWithPath: path),
                                                   maxBytes: Self.maxCredentialBytes),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case "command":
            guard let command = credential.command else { return nil }
            // Resolved the same way whether it is a bare name or a path:
            // a credential command that is not there is not a credential.
            let path = CommandPath.resolve(command)
            guard let path else { return nil }
            // Arguments name files too, so `~` has to mean the same thing there
            // — including inside a URI like `file:~/Library/...`, where it is
            // not the first character and so never got expanded.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let arguments = (credential.args ?? []).map {
                $0.expandingTilde.replacingOccurrences(of: "~/", with: home + "/")
            }
            // A token is a few kilobytes at most. A command that breaks and
            // prints an error page should fail here, legibly, rather than put
            // megabytes into an Authorization header and fail somewhere less
            // obvious.
            let result = Shell.execute(path, arguments, timeout: 10, outputLimit: 8 * 1_024)
            // Truncated output is not a short token, it is a different string.
            guard result.completeOutput else { return nil }
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        case "textFile":
            guard let path = credential.path?.expandingTilde,
                  let data = try? BoundedFile.read(URL(fileURLWithPath: path),
                                                   maxBytes: Self.maxCredentialBytes),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case "jsonFile":
            guard let path = credential.path?.expandingTilde,
                  let field = credential.field,
                  let data = try? BoundedFile.read(URL(fileURLWithPath: path),
                                                   maxBytes: Self.maxCredentialBytes),
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

    // MARK: - Fetch

    /// The most a command's reply may be.
    ///
    /// Larger than a credential because this is a payload rather than a
    /// token, and still far below anything that belongs in a menu bar. A
    /// truncated reply is refused rather than parsed: half a JSON document is
    /// not a smaller set of windows, it is a parse error at best and a
    /// misread number at worst.
    static let maxCommandOutput = 512 * 1_024

    func fetch() async throws -> Snapshot {
        if quota.command != nil { return try makeSnapshot(try runCommand()) }
        guard let token = token() else { throw ProviderError.notConfigured(setupHint) }
        guard let endpoint = quota.endpoint, let url = URL(string: endpoint) else {
            throw ProviderError.badResponse("\(displayName)'s endpoint is not a URL.")
        }
        var headers = quota.headers ?? ["Authorization": "Bearer {token}"]
        headers = headers.mapValues { $0.replacingOccurrences(of: "{token}", with: token) }

        let json = try await UsageHTTP.getJSON(url, headers: headers, session: session)
        return try makeSnapshot(json)
    }

    /// Reads the figures from a command's stdout.
    ///
    /// No credential is involved: the CLI is already signed in or it is not,
    /// and saying "not signed in" for a CLI that is missing would be a
    /// different untruth from the one it fixes. A command that is not
    /// installed is `notConfigured`; one that runs and fails is a failure,
    /// which is what keeps "missing" and "broken" apart.
    private func runCommand() throws -> [String: Any] {
        guard let name = quota.command, let path = CommandPath.resolve(name) else {
            throw ProviderError.notConfigured(setupHint)
        }
        let result = Shell.execute(path, quota.args ?? [], timeout: 15,
                                   outputLimit: Self.maxCommandOutput)
        // Asked apart rather than through `completeOutput`, which is
        // `succeeded && !stdoutTruncated` and so is false for every kind of
        // failure. Reporting all of them as "printed too much" is the same
        // mistake as reporting a missing file as an empty one: the person
        // reading it goes and looks at the wrong thing.
        if result.timedOut {
            throw ProviderError.transport("\(displayName)'s usage command did not answer.")
        }
        if let launchError = result.launchError {
            throw ProviderError.notConfigured(
                "\(displayName)'s usage command could not be run: \(launchError)")
        }
        guard result.exitCode == 0 else {
            // Unwrapped rather than interpolated: `exitCode` is optional, and
            // the message it produced read "exited with Optional(1)".
            let status = result.exitCode.map(String.init) ?? "no status"
            throw ProviderError.badResponse(
                "\(displayName)'s usage command exited with \(status).")
        }
        // Equivalent to `completeOutput` by this line — timeout, launch and
        // exit status are all settled above, and nothing here passes a
        // cancellation — so there is no catalogue entry for it. Written this
        // way regardless, because the next reader should not have to
        // reconstruct that argument to know what is being asked.
        guard !result.stdoutTruncated else {
            throw ProviderError.badResponse(
                "\(displayName) printed more than \(Self.maxCommandOutput / 1_024) KB of usage.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                as? [String: Any] else {
            throw ProviderError.badResponse("\(displayName)'s usage command did not print JSON.")
        }
        return json
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
                    ?? map.title.flatMap { FieldPath.lookup(window, $0) as? String }.map(Self.clamped)
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
    /// A usage response is capped at 2 MiB, which is not the same as bounding
    /// what gets built from it: 2 MiB of small objects is tens of thousands of
    /// windows, and each one becomes a gauge, a menu bar line and an alert
    /// evaluation. No plan reports more than a handful — the largest shipped
    /// descriptor names four — so a response claiming more than this is broken
    /// rather than interesting, and the first are kept.
    static let maxWindows = 64

    /// Text that comes from the response rather than from the descriptor: a
    /// window title, a currency code, a composite key. Descriptor labels are
    /// trusted local configuration and are left alone; these arrive over the
    /// network and end up in a menu item.
    static let maxResponseText = 64

    static func clamped(_ text: String) -> String {
        text.count <= maxResponseText ? text : String(text.prefix(maxResponseText))
    }

    static func windows(in json: [String: Any],
                        map: HarnessDescriptor.Quota.Windows) -> [(key: String, window: [String: Any])] {
        var found: [(key: String, window: [String: Any])]
        if let path = map.list {
            let elements = (FieldPath.lookup(json, path) as? [Any] ?? []).prefix(maxWindows)
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
            found = (map.keys ?? container.keys.sorted())
                .prefix(maxWindows)
                .compactMap { key in
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
        // No default. A descriptor declaring a balance must declare its
        // currency — the decoder refuses one that does not — so reaching here
        // with nothing means the rule was removed rather than that dollars
        // are a reasonable guess.
        guard let declared = map.currency else { return "" }
        if let found = FieldPath.lookup(window, declared) as? String, !found.isEmpty {
            return clamped(found)
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
        case let text as String: return text.isEmpty ? nil : clamped(text)
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
