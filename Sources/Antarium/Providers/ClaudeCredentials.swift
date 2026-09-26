import Foundation
import Security

/// An OAuth token as Claude Code stores it, plus where it came from.
struct ClaudeToken {
    enum Source: String { case securityTool = "security", keychain, file }
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let source: Source

    var isExpired: Bool { isExpired(at: Date()) }

    /// `now` is a parameter so the rule can be asked without waiting for a
    /// clock. A token that states no expiry is *not* expired — absence is not
    /// a date in the past, and Claude Code's file does omit the field.
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Reads the credentials Claude Code already keeps on this Mac.
///
/// Deliberately read-only: we never refresh or rotate the token, because that
/// would invalidate the copy the CLI itself is using. If everything we can see
/// has expired we surface the problem and let the CLI do its own refresh.
///
/// Three sources are tried, cheapest and least intrusive first:
///
///  1. `/usr/bin/security` — Apple-signed and usually already trusted for this
///     item, so it reads without a prompt. Crucially, that trust is granted to
///     `security`, not to us, so it survives rebuilding this app.
///  2. `SecItemCopyMatching` in-process — needs its own grant, and because an
///     ad-hoc signature changes on every build, macOS re-asks each time.
///  3. `~/.claude/.credentials.json` — free, but often a stale leftover.
enum ClaudeCredentials {
    static let service = "Claude Code-credentials"
    static let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    /// What we found, and whether the Keychain refused us — different problems
    /// with different fixes.
    struct Load {
        /// Freshest first, deduplicated.
        let tokens: [ClaudeToken]
        /// Every Keychain route was denied or cancelled.
        let keychainDenied: Bool
    }

    static func load() -> Load {
        var tokens: [ClaudeToken] = []
        var denied = false

        switch readViaSecurityTool() {
        case .found(let t): tokens.append(t)
        case .denied:       denied = true
        case .notFound:     break
        }

        // Only pay the in-process prompt if `security` came up empty.
        if tokens.isEmpty {
            switch readViaSecItem() {
            case .found(let t): tokens.append(t)
            case .denied:       denied = true
            case .notFound:     denied = false   // the item genuinely isn't there
            }
        } else {
            denied = false
        }

        if let file = fromFile() { tokens.append(file) }

        return Load(tokens: ordered(tokens, now: Date()), keychainDenied: denied)
    }

    /// The order tokens are tried in, deduplicated. Pure, and `now` is a
    /// parameter, so the rule is testable without a Keychain or a clock.
    ///
    /// Two lines of this file used to disagree about a missing expiry.
    /// `isExpired` reads it as "not expired", which is right — Claude Code's
    /// file omits the field, and absence is not a date in the past. The sort
    /// read it as `.distantPast`, which put a token of unknown expiry *behind*
    /// every token whose expiry had demonstrably passed.
    ///
    /// Nothing reported a wrong figure for it: the provider tries each token in
    /// turn until one is accepted. But each attempt it wastes is a request to
    /// Anthropic that is expected to fail, and it was spending them on the
    /// tokens least likely to work first.
    ///
    /// Unexpired before expired, and a token with no stated expiry is
    /// unexpired. Among the unexpired, one that *states* a future expiry comes
    /// before one that states none: Claude Code wrote that date because it
    /// believes the token is good until then, and positive evidence of validity
    /// beats no evidence either way. Among tokens that state one, the later
    /// expiry first. Ties keep the order they were found in, which is the order
    /// the sources are tried in — cheapest first.
    static func ordered(_ tokens: [ClaudeToken], now: Date) -> [ClaudeToken] {
        var seen = Set<String>()
        let unique = tokens.filter { seen.insert($0.accessToken).inserted }
        // Enumerated so the sort is total: `sorted(by:)` is not stable, and two
        // tokens with the same expiry would otherwise be free to swap between
        // scans.
        return unique.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            let (aExpired, bExpired) = (a.isExpired(at: now), b.isExpired(at: now))
            if aExpired != bExpired { return !aExpired }
            switch (a.expiresAt, b.expiresAt) {
            // Only reachable for the unexpired: a token with no expiry is never
            // expired, so the expired group states one on both sides.
            case (.some(let x), .some(let y)) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Cheap "has this Mac ever run Claude Code?" check — no Keychain, no prompt.
    static var hasAnyCredentials: Bool {
        if FileManager.default.fileExists(atPath: credentialsFile.path) { return true }
        if case .notFound = readViaSecurityTool() { return false }
        return true
    }

    enum Lookup { case found(ClaudeToken), notFound, denied }

    // MARK: - Sources

    /// The file is a parameter so the bound below can be tested against a
    /// synthetic one. Reading the real credentials file in a test would be
    /// both unreliable and the wrong thing to do.
    static func fromFile(_ credentialsFile: URL = ClaudeCredentials.credentialsFile)
        -> ClaudeToken? {
        // Another application writes this file, and every other reader here
        // is bounded. A credential is a few kilobytes; nothing legitimate
        // about this path is larger.
        guard let data = try? BoundedFile.read(credentialsFile, maxBytes: 256 * 1_024)
        else { return nil }
        return decode(data, source: .file)
    }

    private static func readViaSecItem() -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data, let token = decode(data, source: .keychain) else {
                return .notFound
            }
            return .found(token)
        case errSecItemNotFound:
            return .notFound
        default:
            // errSecUserCanceled / errSecAuthFailed / errSecInteractionNotAllowed:
            // the item exists, we just aren't allowed to read it.
            return .denied
        }
    }

    private static func readViaSecurityTool() -> Lookup {
        guard let out = runSecurity(["find-generic-password", "-s", service,
                                     "-a", NSUserName(), "-w"]) else { return .denied }
        switch out.status {
        case 0:
            guard let token = decode(Data(out.stdout.utf8), source: .securityTool) else {
                return .notFound
            }
            return .found(token)
        case 44:            // SecKeychainSearchCopyNext: item not found
            return .notFound
        default:
            return .denied
        }
    }

    /// Runs `/usr/bin/security` with a watchdog, so a stuck authorisation
    /// dialog can never wedge the refresh loop.
    private static func runSecurity(_ args: [String]) -> (status: Int32, stdout: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let pipe = Pipe(), errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do { try process.run() } catch { return nil }

        // Asked to stop, then made to. `terminate()` is SIGTERM, which a
        // process sitting on a modal authorisation dialog is free to ignore —
        // and the read below blocks until the pipe closes, so ignoring it
        // wedges exactly the loop this watchdog exists to protect. `Shell`
        // has escalated for the same reason since it was written; this had
        // the first half only.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let force = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10.5, execute: force)

        // Read before waiting: a full pipe buffer would otherwise deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        force.cancel()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }

    private static func decode(_ data: Data, source: ClaudeToken.Source) -> ClaudeToken? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeToken(accessToken: token,
                           expiresAt: expiry,
                           subscriptionType: oauth["subscriptionType"] as? String,
                           source: source)
    }
}
