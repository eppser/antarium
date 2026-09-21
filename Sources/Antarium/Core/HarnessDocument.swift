import Foundation
import AntariumHarnessSDK

/// Version boundary for user-authored harness documents.
///
/// Codable alone is deliberately not the boundary: it ignores unknown fields
/// and cannot distinguish an old meaning from a future one. Every load passes
/// through here so bundled and third-party documents receive identical
/// migrations and future versions fail closed.
enum HarnessDocument {
    static let currentVersion = HarnessConfig.currentFormatVersion

    struct Decoded {
        let descriptor: HarnessDescriptor
        /// Nil for an already-current document; zero for the unversioned v0.
        let migratedFrom: Int?
    }

    enum Error: Swift.Error, LocalizedError {
        case notObject
        case invalidVersion
        case futureVersion(Int)
        case unsupportedVersion(Int)
        case semantic(String)

        var errorDescription: String? {
            switch self {
            case .notObject: return "Harness document must be a JSON object."
            case .invalidVersion:
                return "formatVersion must be a non-negative integer."
            case .futureVersion(let version):
                return "Harness format \(version) is newer than this Antarium supports (\(currentVersion))."
            case .unsupportedVersion(let version):
                return "Harness format \(version) cannot be migrated by this Antarium."
            case .semantic(let message): return message
            }
        }
    }

    static func decode(_ data: Data) throws -> Decoded {
        let canonical = try canonicalObject(data)
        try validate(canonical)
        let originalVersion = version(in: try rawObject(data))
        var runtime = canonical

        // Runtime aliases keep the engine's internal model stable while the
        // public v1 document has coherent nested process/presentation sections.
        let process = runtime["process"] as? [String: Any] ?? [:]
        runtime["match"] = process["pathContains"] as? [String] ?? []
        if let names = process["names"] as? [String] { runtime["matchProcessName"] = names }
        if let presentation = runtime["presentation"] as? [String: Any] {
            if let value = presentation["fallbackName"] { runtime["fallbackName"] = value }
            if let value = presentation["mark"] { runtime["mark"] = value }
        }

        let normalized = try JSONSerialization.data(withJSONObject: runtime,
                                                     options: [.sortedKeys])
        let descriptor = try JSONDecoder().decode(HarnessDescriptor.self, from: normalized)
        return Decoded(descriptor: descriptor,
                       migratedFrom: originalVersion == currentVersion ? nil : originalVersion)
    }

    /// Canonical current-format bytes, suitable for an explicit SDK/CLI
    /// migration. Loading never rewrites a user's file implicitly.
    static func migratedData(_ data: Data) throws -> Data {
        let object = try canonicalObject(data)
        return try JSONSerialization.data(withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func rawObject(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.notObject
        }
        return value
    }

    /// Only ever called after `canonicalObject` has accepted the document, so
    /// the refusals below cannot be reached by anything that decodes — a
    /// non-numeric or negative version has already been thrown out. They stay
    /// because this function's answer is reported to the user as "migrated
    /// from", and returning a plausible 0 for an unreadable value would be a
    /// figure invented rather than read.
    private static func version(in object: [String: Any]) -> Int {
        guard let value = object["formatVersion"] else { return 0 }
        // NSNumber may also represent a boolean, which is not a version.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else { return -1 }
        return number.intValue
    }

    private static func canonicalObject(_ data: Data) throws -> [String: Any] {
        do {
            let result = try HarnessConfigMigration.migrate(data, prettyPrinted: false)
            return try rawObject(result.data)
        } catch let error as HarnessConfigMigration.MigrationError {
            switch error {
            case .notObject: throw Error.notObject
            case .invalidVersion: throw Error.invalidVersion
            case .futureVersion(let version): throw Error.futureVersion(version)
            case .unsupportedVersion(let version): throw Error.unsupportedVersion(version)
            }
        } catch {
            throw error
        }
    }

    private static func validate(_ object: [String: Any]) throws {
        func requireText(_ key: String, in value: [String: Any], at path: String = "") throws {
            guard let text = value[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.semantic("\(path)\(key) is required and must not be empty")
            }
        }

        try requireText("id", in: object)
        try requireText("name", in: object)
        guard object["process"] is [String: Any] else {
            throw Error.semantic("process is required in harness format \(currentVersion)")
        }
        guard let source = object["source"] as? [String: Any] else {
            throw Error.semantic("source is required")
        }
        try requireText("kind", in: source, at: "source.")
        guard let kind = source["kind"] as? String,
              ["jsonl", "json", "sqlite", "command", "none"].contains(kind) else {
            throw Error.semantic("source.kind is not supported")
        }
        guard source["path"] is String else {
            throw Error.semantic("source.path is required (use an empty string for none/command)")
        }
        if let process = object["process"] as? [String: Any],
           let binding = process["sessionBinding"] as? String {
            guard binding == "openSourceFile" else {
                throw Error.semantic("process.sessionBinding is not supported")
            }
            guard kind == "json" || kind == "jsonl" else {
                throw Error.semantic(
                    "process.sessionBinding openSourceFile requires a JSON or JSONL source")
            }
        }
        if let map = object["map"] as? [String: Any],
           (map["totalTokens"] as? String)?.isEmpty == false {
            // A total and a split cannot both be believed: nothing here can
            // tell whether the total already counts the other two, so adding
            // them makes a figure too large and ignoring them makes the
            // descriptor's own declaration a lie. Same reasoning as the quota
            // block refusing an endpoint and a command together.
            let split = ["inputTokens", "outputTokens", "cacheRead", "cacheWrite"]
                .filter { (map[$0] as? String)?.isEmpty == false }
            guard split.isEmpty else {
                throw Error.semantic(
                    "map.totalTokens is for a harness that reports no split, and this one "
                    + "also declares \(split.joined(separator: ", "))")
            }
        }
        if let quota = object["quota"] as? [String: Any] {
            // Exactly one way in. Both would leave which one wins to the
            // order of an if, and neither is a quota block that does
            // anything — it would decode, ship, and report nothing.
            let endpoint = (quota["endpoint"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let command = (quota["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch (endpoint?.isEmpty == false, command?.isEmpty == false) {
            case (true, true):
                throw Error.semantic(
                    "quota declares both an endpoint and a command; it reads from one or the other")
            case (false, false):
                throw Error.semantic("quota declares neither an endpoint nor a command")
            default: break
            }
            // A balance is money, and money with no stated currency is a
            // number whose meaning is unknown. The mapping used to answer
            // "USD" for an author who omitted it, which turns a CNY balance
            // into a dollar figure wrong by an exchange rate — the exact
            // mistake the deepseek harness carries a note about. Neither
            // shipped descriptor relied on that default; it was a trap set
            // for whoever wrote the next one.
            if let windows = quota["windows"] as? [String: Any],
               let balance = windows["balance"] as? String, !balance.isEmpty {
                let currency = (windows["currency"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let currency, !currency.isEmpty else {
                    throw Error.semantic(
                        "quota.windows.balance needs quota.windows.currency — a path "
                        + "into the response where the service states one, or the code itself")
                }
            }
            // The method is checked rather than defaulted: a typo reads as
            // GET, and a descriptor that meant to post would fetch the wrong
            // way and report whatever a GET to that path happens to return.
            if let raw = quota["method"] {
                guard let method = raw as? String,
                      ["get", "post"].contains(method.lowercased()) else {
                    throw Error.semantic("quota.method must be GET or POST")
                }
                if method.lowercased() != "post", quota["body"] != nil {
                    throw Error.semantic("quota.body is only sent with POST")
                }
            } else if quota["body"] != nil {
                throw Error.semantic("quota.body is only sent with POST")
            }
            if let body = quota["body"], !(body is [String: String]) {
                throw Error.semantic("quota.body must be an object of string values")
            }
            if command?.isEmpty == false {
                if quota["headers"] != nil {
                    throw Error.semantic("quota.headers is only read for an endpoint")
                }
                if quota["method"] != nil || quota["body"] != nil {
                    throw Error.semantic("quota.method and quota.body are only read for an endpoint")
                }
                // argv, never a shell. A separator in the command name is the
                // shape of an injected path rather than a program name.
                if let command, command.contains("/") || command.contains(" ") {
                    throw Error.semantic(
                        "quota.command must be a program name resolved on PATH, not a path or a line")
                }
                if let args = quota["args"], !(args is [String]) {
                    throw Error.semantic("quota.args must be an array of strings")
                }
            } else if quota["args"] != nil {
                throw Error.semantic("quota.args is only read for a command")
            }
        }
        if let quota = object["quota"] as? [String: Any],
           let credential = quota["credential"] as? [String: Any],
           let rawRequires = credential["requires"] {
            // A guard that silently does nothing is worse than no guard: the
            // descriptor reads as if the credential were checked.
            guard let requires = rawRequires as? [String: String], !requires.isEmpty else {
                throw Error.semantic(
                    "quota.credential.requires must be a non-empty object of field to substring")
            }
            // Refused here rather than in HarnessCheck: `--check` decodes
            // first and gives up if that fails, so a copy of this rule over
            // there could never fire. A check that cannot fail is worse than
            // no check, because it reads as coverage.
            guard credential["kind"] as? String == "jsonFile" else {
                throw Error.semantic(
                    "quota.credential.requires is only read for a jsonFile credential")
            }
            for (field, expected) in requires where
                field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Error.semantic(
                    "quota.credential.requires has an empty field or substring")
            }
        }

        if let process = object["process"] as? [String: Any],
           let rawProbes = process["installationProbes"] {
            guard let probes = rawProbes as? [[String: Any]] else {
                throw Error.semantic("process.installationProbes must be an array")
            }
            for (index, probe) in probes.enumerated() {
                let prefix = "process.installationProbes[\(index)]."
                for key in ["method", "path", "name", "argv0", "evidence", "verifiedAt"] {
                    guard probe[key] is String else {
                        throw Error.semantic("\(prefix)\(key) is required")
                    }
                }
                guard probe["expected"] is Bool else {
                    throw Error.semantic("\(prefix)expected is required and must be boolean")
                }
                let method = probe["method"] as? String ?? ""
                let evidenceText = probe["evidence"] as? String ?? ""
                let verifiedAt = probe["verifiedAt"] as? String ?? ""
                guard !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let evidence = URL(string: evidenceText),
                      evidence.scheme == "https", evidence.host != nil,
                      validDay(verifiedAt) else {
                    throw Error.semantic(
                        "\(prefix) requires a method, HTTPS evidence, and yyyy-MM-dd verifiedAt date")
                }
            }
        }
        if kind == "json" || kind == "jsonl" {
            try requireText("glob", in: source, at: "source.")
        } else if kind == "sqlite" {
            try requireText("query", in: source, at: "source.")
            guard let columns = source["columns"] as? [String], !columns.isEmpty else {
                throw Error.semantic("source.columns is required for SQLite")
            }
        } else if kind == "command" {
            try requireText("command", in: source, at: "source.")
        }
        if let rawLimit = source["limit"] as? NSNumber,
           !(1...400).contains(rawLimit.intValue) {
            throw Error.semantic("source.limit must be between 1 and 400")
        }

        if let selection = object["selection"] as? [String: Any] {
            try requireText("kind", in: selection, at: "selection.")
            switch selection["kind"] as? String {
            case "jsonFiles":
                for key in ["path", "glob", "records", "id"] {
                    try requireText(key, in: selection, at: "selection.")
                }
            case "sqlite":
                for key in ["path", "query", "column"] {
                    try requireText(key, in: selection, at: "selection.")
                }
            case "command":
                for key in ["command", "id"] {
                    try requireText(key, in: selection, at: "selection.")
                }
            default: throw Error.semantic("selection.kind is not supported")
            }
        }

        if let compatibility = object["compatibility"] as? [String: Any],
           let level = compatibility["level"] as? String,
           level == "fixtureVerified" || level == "liveVerified" {
            try requireText("verifiedAt", in: compatibility, at: "compatibility.")
            try requireText("fixture", in: compatibility, at: "compatibility.")
        }
    }

    private static func validDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
