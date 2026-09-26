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
    private let session: UsageHTTP.Session

    /// Called when the registry replaces or drops this provider, because a
    /// session outlives the object that made it until it is invalidated.
    func releaseSession() { UsageHTTP.release(session) }

    /// Whether this provider's session is still live. The observable half of
    /// `releaseSession`, so a test can watch one object rather than a count
    /// every other suite is also moving.
    var sessionIsTracked: Bool { UsageHTTP.isTracked(session) }

    /// `protocolClasses` exists so a test can put a synthetic server behind
    /// the provider and still travel the production path — the session is
    /// built here either way, so the bounded body and the redirect refusal
    /// are in it. Taking a whole session instead would mean naming
    /// a session in this file, which the transport contract forbids for the
    /// good reason that it cannot tell an injected one from a hand-rolled
    /// one. The stored property is `UsageHTTP.Session` for the same reason.
    init?(_ descriptor: HarnessDescriptor, protocolClasses: [AnyClass]? = nil) {
        guard let quota = descriptor.quota else { return nil }
        self.descriptor = descriptor
        self.quota = quota
        self.session = UsageHTTP.makeSession(headers: [:], protocolClasses: protocolClasses)
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
            guard Self.belongsToThisVendor(object, credential) else { return nil }
            return FieldPath.lookup(object, field) as? String
        default:
            return nil
        }
    }

    /// Whether a credential file is this vendor's at all.
    ///
    /// One copy, because there are two readers of the same file and they must
    /// not be able to disagree: a file that fails these guards is not this
    /// vendor's, so neither its token nor the account id beside it may be
    /// used. Written twice, the account reader could have kept reading from a
    /// file the token reader had already rejected.
    static func belongsToThisVendor(_ object: [String: Any],
                                    _ credential: HarnessDescriptor.Quota.Credential) -> Bool {
        for (path, required) in credential.requires ?? [:] {
            guard let found = FieldPath.lookup(object, path) as? String,
                  found.lowercased().contains(required.lowercased())
            else { return false }
        }
        return true
    }

    /// The account or organisation the token belongs to, when the service
    /// scopes its usage under one and the credential file names it.
    ///
    /// Read from the same file as the token and checked by the same
    /// `requires` guards — a file that failed those is not this vendor's, and
    /// its account id is not either.
    func account() -> String? {
        guard let credential = quota.credential, credential.kind == "jsonFile",
              let field = credential.accountField,
              let path = credential.path?.expandingTilde,
              let data = try? BoundedFile.read(URL(fileURLWithPath: path),
                                               maxBytes: Self.maxCredentialBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard Self.belongsToThisVendor(object, credential) else { return nil }
        // A number is a perfectly ordinary account id, and reading only
        // strings would report "not signed in" for a file that says so
        // plainly.
        if let text = FieldPath.lookup(object, field) as? String, !text.isEmpty { return text }
        if let number = FieldPath.lookup(object, field) as? NSNumber { return number.stringValue }
        return nil
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
        // The token may belong in the URL rather than in a header. A
        // self-hosted proxy in front of an agent — LiteLLM, and the several
        // like it — asks for the key being queried as a query parameter, and
        // until now `{token}` was substituted into headers and POST bodies
        // but not here. That left the whole class undescribable: not by a
        // shipped descriptor, which cannot know the host anyway, and not by
        // somebody writing their own either, which is the part that mattered.
        //
        // Encoded before it goes in. A key carrying `&`, `?` or `#` would
        // otherwise end the parameter early and send the rest of it as
        // something else — or, worse, quietly query a different key. Encoded
        // conservatively for the same reason the form bodies are: over-
        // encoding a query value is always safe, guessing at a context is
        // not.
        //
        // Nothing logs a request URL — `UsageHTTP` records the status alone,
        // and `--check` prints the endpoint's host — so a credential placed
        // here does not reach the log the way one in a header does not.
        let account = self.account()
        guard let endpoint = quota.endpoint,
              let url = Self.requestURL(endpoint, token: token, account: account) else {
            throw ProviderError.badResponse("\(displayName)'s endpoint is not a URL.")
        }
        // A descriptor that asks for an account it cannot find must say so
        // rather than ask about one named "{account}".
        if endpoint.contains("{account}"), account == nil {
            throw ProviderError.notConfigured(
                "\(displayName) needs the account its credential names, and the file does not name one.")
        }
        var headers = quota.headers ?? ["Authorization": "Bearer {token}"]
        headers = headers.mapValues {
            Self.filled($0, token: token, account: account, forURL: false)
        }

        let json: [String: Any]
        if quota.resolvedMethod == .post {
            json = try await UsageHTTP.postJSON(
                url, body: Self.postBody(quota, token: token, account: account),
                headers: headers, session: session)
        } else {
            json = try await UsageHTTP.getJSON(url, headers: headers, session: session)
        }
        return try makeSnapshot(json)
    }

    /// The body of a POST, from the two halves a descriptor may declare.
    ///
    /// Split out of `fetch` so it can be asked. It was three lines inside an
    /// `await`, which meant the only way to see what gets posted was to post
    /// it: a merge that dropped the list half, or substituted a token into it,
    /// or preferred the wrong half for a key in both, would have shipped with
    /// every fixture still green — a quota fixture replays `makeSnapshot`, and
    /// by then the request has already been made.
    ///
    /// Merged rather than overlaid: the document boundary refuses a key
    /// declared in both halves, so there is no precedence to decide here and
    /// none to get wrong later. `{token}` reaches only the scalar half — a
    /// credential is one value, and every list-valued field seen is a set of
    /// literal scope names.
    static func postBody(_ quota: HarnessDescriptor.Quota,
                         token: String, account: String?) -> [String: Any] {
        var body: [String: Any] = (quota.body ?? [:]).mapValues {
            Self.filled($0, token: token, account: account, forURL: false)
        }
        for (key, value) in quota.bodyList ?? [:] { body[key] = value }
        return body
    }

    /// The URL to ask, with the credential in it if that is where it goes.
    ///
    /// Callable so the substitution can be checked without a network: the
    /// only other way to see this URL is to watch a request leave.
    static func requestURL(_ endpoint: String, token: String,
                           account: String? = nil) -> URL? {
        URL(string: filled(endpoint, token: token, account: account, forURL: true))
    }

    /// The one substitution, so the placeholders cannot come to mean
    /// different things in a URL and in a header.
    ///
    /// `forURL` is the only difference: a value going into a URL is
    /// percent-encoded so punctuation in it stays a value rather than
    /// becoming syntax, and a header value is not, because encoding it there
    /// would send the escape sequence itself.
    static func filled(_ template: String, token: String, account: String?,
                       forURL: Bool) -> String {
        func encode(_ value: String) -> String {
            forURL ? (value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)
                   : value
        }
        var out = template
        if out.contains("{token}") {
            out = out.replacingOccurrences(of: "{token}", with: encode(token))
        }
        // Left as written when there is no account to put in. A URL still
        // carrying the placeholder is refused by the host check rather than
        // silently asking about an account called "{account}".
        if let account, out.contains("{account}") {
            out = out.replacingOccurrences(of: "{account}", with: encode(account))
        }
        return out
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

    /// A flag read from the window, or from the response when the window
    /// does not carry it. Nothing when neither states one.
    ///
    /// The fallback is the rule `resetsAt` already follows, and for the same
    /// reason: a service can state something once for every window it reports.
    /// DeepSeek puts `is_available` beside its balances rather than inside each
    /// one.
    ///
    /// This used to answer `false` for a flag nothing stated, and the two rules
    /// that read it want opposite things from that. `require` wants it —
    /// `unlimited: false` has to mean what it says rather than rejecting every
    /// window that simply does not mention being unlimited — so it still
    /// supplies the `false` itself. `criticalWhen` must not have it: painting a
    /// gauge critical is an assertion about somebody's account, and a reply that
    /// omits `is_available` altogether was marking every DeepSeek balance
    /// critical on evidence that did not exist. Every fixture case stated the
    /// field, so nothing saw it.
    ///
    /// The key is a field path, which it is classified as. It resolved as a flat
    /// member before — so a dotted key silently matched nothing, and a filtered
    /// one would have passed the validator and then never matched, which is the
    /// shape of guard this repository refuses. For a key of one segment this is
    /// the member lookup it was.
    ///
    /// A flag stated as the number 1 or 0 reads as a flag, and 2 or "true" do
    /// not: that is `as? Bool`'s own bridging, checked rather than assumed, and
    /// it is the reading to want. An unreadable value is no longer a silent
    /// `false` for the rule that matters.
    private static func flag(_ key: String, window: [String: Any],
                             root: [String: Any]) -> Bool? {
        (FieldPath.first(window, key) as? Bool) ?? (FieldPath.first(root, key) as? Bool)
    }

    func makeSnapshot(_ json: [String: Any]) throws -> Snapshot {
        let map = quota.windows

        var gauges: [Gauge] = []
        for (key, window) in Self.windows(in: json, map: map) {
            // A window the plan does not include is not a window at zero.
            //
            // An absent flag reads as false, which is what lets a rule ask
            // for one. `has_quota: true` behaves as before — absent already
            // failed it — and `unlimited: false` now means what it says
            // instead of rejecting every window that simply does not mention
            // being unlimited.
            if let require = map.require,
               require.contains(where: {
                   // The `false` is supplied here, deliberately: see `flag`.
                   (Self.flag($0.key, window: window, root: json) ?? false) != $0.value
               }) {
                continue
            }
            // Spent, whatever the figure says. An empty rule marks
            // nothing: `allSatisfy` on nothing is true, and a descriptor that
            // names no flag has not asked for this.
            //
            // No `?? false` here, and that is the whole of the fix: a flag
            // nothing stated is `nil`, `nil == someBool` is false, and the rule
            // is not satisfied. A window is spent because the service said so.
            let reported: Severity = (map.criticalWhen.map {
                !$0.isEmpty && $0.allSatisfy { Self.flag($0.key, window: window, root: json) == $0.value }
            } ?? false) ? .critical : .normal

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
                    reportedSeverity: reported,
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
            } else if let remainingPath = map.remaining, let limitPath = map.limit,
                      let remaining = FieldPath.number(window, remainingPath),
                      let limit = FieldPath.number(window, limitPath), limit > 0 {
                // Clamped before subtracting, for a service reporting more
                // left than its own cap. This has no catalogue entry and is
                // not load-bearing: `Gauge` clamps the fraction it is given,
                // so an unclamped subtraction would reach the same empty bar
                // by going negative first. Kept because the arithmetic here
                // should be meaningful on its own, and because the clamp in
                // the gauge is a guard on a different question.
                percent = (limit - min(max(remaining, 0), limit)) / limit * 100
            } else { continue }
            let span = FieldPath.seconds(map.windowSeconds.flatMap { FieldPath.number(window, $0) })
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
                reportedSeverity: reported,
                windowSeconds: span))
        }
        guard !gauges.isEmpty else {
            // Say what the reply did carry, when it carried something this
            // descriptor does not name. "Reported no usage window" is true
            // and unactionable for the account that hits it most: a plan
            // whose limits are all of a kind the mapping was not written for
            // reads exactly like a plan with no limits at all. The names come
            // from the response, so this reports rather than guesses — and
            // it costs nothing until there is already nothing to draw.
            var unfiltered = map
            unfiltered.keys = nil
            let offered = Self.windows(in: json, map: unfiltered)
                .map { Self.clamped($0.key) }
                .filter { !$0.isEmpty }
                .prefix(Self.maxNamedInError)
            guard offered.isEmpty else {
                throw ProviderError.unsupported(
                    "\(displayName) reported no usage window this app reads. "
                    + "The reply named: \(offered.joined(separator: ", ")).")
            }
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

    /// How many of the reply's own window names an error may repeat back.
    /// They are vendor text on their way to a menu, so they are clamped
    /// individually as well.
    static let maxNamedInError = 6

    static func windows(in json: [String: Any],
                        map: HarnessDescriptor.Quota.Windows) -> [(key: String, window: [String: Any])] {
        var found: [(key: String, window: [String: Any])]
        if let path = map.list {
            let elements = (FieldPath.first(json, path) as? [Any] ?? []).prefix(maxWindows)
            found = elements.enumerated().compactMap { index, element in
                guard let window = element as? [String: Any] else { return nil }
                return (Self.listKey(window, map.key, index: index), window)
            }
            // A list can repeat a name where an object cannot. Two gauges with
            // one id would be two identical-looking rows, so later duplicates
            // are numbered rather than dropped: the response said they were
            // different windows.
            //
            // The separator is not the one a compound name joins with, and that
            // matters on the descriptor that has both. Z.ai keys on `type` and
            // `unit`, so its names are `TOKENS_LIMIT-3`, `TOKENS_LIMIT-6`,
            // `TOKENS_LIMIT-7` — and numbering a duplicate with the same `-`
            // would synthesise `TOKENS_LIMIT-3` for the third row that could
            // not name itself. That id is in the descriptor's `keys`, so the
            // row would be drawn, under unit 3's label, reporting unit 3's
            // figures for a window that is not unit 3.
            var seen: [String: Int] = [:]
            found = found.map { entry in
                let count = (seen[entry.key] ?? 0) + 1
                seen[entry.key] = count
                return count == 1 ? entry : ("\(entry.key)\(Self.duplicateMark)\(count)",
                                             entry.window)
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
                : candidates.lazy.compactMap { FieldPath.first(json, $0) as? [String: Any] }.first
            found = container.map { [(name, $0)] } ?? []
        } else {
            // First candidate that actually resolves to an object. An absent
            // envelope is a different shape, not an empty one, so falling
            // through to the whole response is only correct when no path was
            // declared at all.
            let candidates = map.roots ?? map.root.map { [$0] } ?? []
            let container: [String: Any] = candidates
                .lazy
                .compactMap { FieldPath.first(json, $0) as? [String: Any] }
                .first ?? (candidates.isEmpty ? json : [:])
            // For an object the declared order is the drawing order.
            //
            // A declared key is resolved as a path, not only as a member name,
            // which is how two windows at unrelated places in one response are
            // described. Kimi reports the weekly total in `detail` and the
            // five-hour window inside a `limits` array beside it, and neither
            // the list shape nor a shared parent object reaches both. For a
            // key of one segment — which is every key shipped so far — this is
            // the member lookup it was.
            found = (map.keys ?? container.keys.sorted())
                .prefix(maxWindows)
                .compactMap { key in
                    (FieldPath.first(container, key) as? [String: Any]).map { (key, $0) }
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
    /// What a list element is called, from the key fields the descriptor named.
    ///
    /// Every declared part or none. This used to `compactMap`, so a descriptor
    /// asking for `type` and `unit` and getting only `type` produced
    /// `TOKENS_LIMIT` — a name indistinguishable from one a single-key
    /// descriptor meant, and one that then either matched the wrong entry in
    /// `keys` or matched nothing while looking deliberate. A name built from
    /// half the fields it was told to use is not that name.
    ///
    /// Falling back to the index is what already happened for an element that
    /// could name itself not at all, and it has the property that matters: the
    /// descriptor's `keys` will not contain it, so the window is absent rather
    /// than mislabelled.
    static func listKey(_ window: [String: Any], _ paths: [String]?, index: Int) -> String {
        guard let paths, !paths.isEmpty else { return "\(index)" }
        var parts: [String] = []
        for path in paths {
            guard let part = name(window, path) else { return "\(index)" }
            parts.append(part)
        }
        return parts.joined(separator: "-")
    }

    /// Separates a synthesised duplicate number from the name it disambiguates.
    /// Deliberately not `-`, which is what a compound key joins with.
    static let duplicateMark = "#"

    private static func name(_ window: [String: Any], _ path: String) -> String? {
        // `first`, not `lookup`: a key part is a field path, which is how it is
        // classified, and `lookup` cannot see a filter at all.
        let value = FieldPath.first(window, path)
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
    static func badge(seconds raw: Double?, fallback: String) -> String {
        // Bounded, because the next two lines divide it and convert the
        // result to an `Int`, which traps rather than rounds on a response
        // carrying 1e30.
        guard let seconds = FieldPath.seconds(raw)
        else { return String(fallback.prefix(3)).uppercased() }
        let hours = seconds / 3600
        if hours < 24 { return "\(Int(hours.rounded()))H" }
        return "\(Int((hours / 24).rounded()))D"
    }




}
