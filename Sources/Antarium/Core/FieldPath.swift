import Foundation

/// Resolves a descriptor's field paths against a JSON record.
///
/// One implementation, because there were two. `HarnessEngine` grew array
/// syntax — `requests[].promptTokens` and `requests[-1].promptTokens` — while
/// the copy inside the quota provider did not, so the same notation in the same
/// config file worked under `map` and silently failed under `quota`. A shared
/// vocabulary has to be shared code, or it is two vocabularies that look alike.
enum FieldPath {

    /// `a.b.c` into nested objects.
    static func lookup(_ record: [String: Any], _ path: String) -> Any? {
        var current: Any? = record
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        return current
    }

    /// Every value a path names.
    ///
    /// `a.b[].c` is the `c` of every element of the array at `a.b`; `a.b[-1].c`
    /// is only the last one's. Anything else is the single value, or nothing.
    static func each(_ record: [String: Any], _ path: String) -> [Any] {
        if let marker = path.range(of: "[-1]") {
            let (prefix, suffix) = split(path, around: marker)
            guard let array = lookup(record, prefix) as? [[String: Any]],
                  let last = array.last else { return [] }
            return suffix.isEmpty ? [last] : lookup(last, suffix).map { [$0] } ?? []
        }
        guard let marker = path.range(of: "[]") else {
            return lookup(record, path).map { [$0] } ?? []
        }
        let (prefix, suffix) = split(path, around: marker)
        guard let array = lookup(record, prefix) as? [[String: Any]] else { return [] }
        return suffix.isEmpty ? array : array.compactMap { lookup($0, suffix) }
    }

    private static func split(_ path: String, around marker: Range<String.Index>) -> (String, String) {
        let dots = CharacterSet(charactersIn: ".")
        return (String(path[path.startIndex..<marker.lowerBound]).trimmingCharacters(in: dots),
                String(path[marker.upperBound...]).trimmingCharacters(in: dots))
    }

    /// The newest value — a session's model is what it used last, not first.
    static func string(_ record: [String: Any], _ path: String) -> String? {
        if path.contains("[") { return each(record, path).compactMap { $0 as? String }.last }
        return lookup(record, path) as? String
    }

    /// Totals across an array, so a conversation's tokens add up.
    static func int(_ record: [String: Any], _ path: String) -> Int {
        values(record, path).reduce(0) { $0 + Int($1) }
    }

    static func double(_ record: [String: Any], _ path: String) -> Double {
        values(record, path).reduce(0, +)
    }

    /// Nil rather than zero, for callers that must tell "absent" from "none".
    static func number(_ record: [String: Any], _ path: String) -> Double? {
        let found = values(record, path)
        return found.isEmpty ? nil : found.reduce(0, +)
    }

    private static func values(_ record: [String: Any], _ path: String) -> [Double] {
        each(record, path).compactMap { value in
            switch value {
            case let v as Double: return v
            case let v as Int: return Double(v)
            case let v as String: return Double(v)
            default: return nil
            }
        }
    }

    /// The latest time a path names. ISO strings, and epochs in either seconds
    /// or milliseconds, are all understood — every store writes a different one.
    static func date(_ record: [String: Any], _ path: String) -> Date? {
        each(record, path).compactMap { value -> Date? in
            switch value {
            case let v as String: return UsageHTTP.parseDate(v)
            case let v as Double: return epoch(v)
            case let v as Int: return epoch(Double(v))
            default: return nil
            }
        }.max()
    }

    static func epoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        // Anything past the year 5138 in seconds is really milliseconds.
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// Entries of a nested array or object matching every pair given.
    static func count(_ record: [String: Any], path: String, match: [String: String]) -> Int {
        let entries: [[String: Any]]
        switch lookup(record, path) {
        case let dict as [String: Any]: entries = dict.values.compactMap { $0 as? [String: Any] }
        case let array as [[String: Any]]: entries = array
        default: entries = []
        }
        return entries.filter { entry in
            match.allSatisfy { (entry[$0.key] as? String) == $0.value }
        }.count
    }
}
