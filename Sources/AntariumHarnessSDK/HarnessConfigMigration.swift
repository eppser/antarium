import Foundation

/// Public semantic migration for harness authors and tooling. It returns
/// canonical bytes and never rewrites the caller's file implicitly.
public enum HarnessConfigMigration {
    public struct Result {
        public let data: Data
        public let migratedFrom: Int?
    }

    public enum MigrationError: Swift.Error, LocalizedError {
        case notObject
        case invalidVersion
        case futureVersion(Int)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notObject: return "Harness document must be a JSON object."
            case .invalidVersion: return "formatVersion must be a non-negative integer."
            case .futureVersion(let version):
                return "Harness format \(version) is newer than this SDK supports (\(HarnessConfig.currentFormatVersion))."
            case .unsupportedVersion(let version):
                return "Harness format \(version) cannot be migrated by this SDK."
            }
        }
    }

    public static func migrate(_ data: Data, prettyPrinted: Bool = true) throws -> Result {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.notObject
        }
        let original = try version(in: object)
        guard original <= HarnessConfig.currentFormatVersion else {
            throw MigrationError.futureVersion(original)
        }
        var version = original
        while version < HarnessConfig.currentFormatVersion {
            switch version {
            case 0:
                object = migrateV0toV1(object)
                version = 1
            default: throw MigrationError.unsupportedVersion(version)
            }
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { options.insert(.prettyPrinted) }
        return Result(data: try JSONSerialization.data(withJSONObject: object, options: options),
                      migratedFrom: original == HarnessConfig.currentFormatVersion ? nil : original)
    }

    private static func version(in object: [String: Any]) throws -> Int {
        guard let value = object["formatVersion"] else { return 0 }
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue >= 0,
              number.doubleValue.rounded() == number.doubleValue else {
            throw MigrationError.invalidVersion
        }
        return number.intValue
    }

    /// The new value first, then anything the old key added, without
    /// duplicates and in a stable order.
    private static func merged(_ current: Any?, _ legacy: Any?) -> [String] {
        let a = current as? [String] ?? [], b = legacy as? [String] ?? []
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0).inserted }
    }

    private static func migrateV0toV1(_ input: [String: Any]) -> [String: Any] {
        var object = input
        var process = object["process"] as? [String: Any] ?? [:]
        // A file carrying both forms has been half-migrated by hand. The old
        // key is merged rather than dropped or preferred, and then removed:
        // `processRule` unions the two at runtime anyway, so leaving it would
        // mean a matcher the file no longer shows is still claiming
        // processes. Better that the union is visible and editable.
        process["pathContains"] = merged(process["pathContains"],
                                         object.removeValue(forKey: "match"))
        process["names"] = merged(process["names"],
                                  object.removeValue(forKey: "matchProcessName"))
        if (process["pathContains"] as? [String])?.isEmpty != false {
            process.removeValue(forKey: "pathContains")
        }
        if (process["names"] as? [String])?.isEmpty != false {
            process.removeValue(forKey: "names")
        }
        object["process"] = process

        var presentation = object["presentation"] as? [String: Any] ?? [:]
        if presentation["fallbackName"] == nil,
           let value = object.removeValue(forKey: "fallbackName") {
            presentation["fallbackName"] = value
        }
        if presentation["mark"] == nil, let value = object.removeValue(forKey: "mark") {
            presentation["mark"] = value
        }
        if !presentation.isEmpty { object["presentation"] = presentation }
        object["formatVersion"] = HarnessConfig.currentFormatVersion
        return object
    }
}
