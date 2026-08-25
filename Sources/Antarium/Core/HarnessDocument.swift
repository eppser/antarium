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
}
