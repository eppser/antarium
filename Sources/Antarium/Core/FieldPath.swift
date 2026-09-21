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

    /// Integer observations preserve exact values where possible. Missing,
    /// malformed, nonfinite and overflowing aggregates are unavailable, never
    /// coerced to zero or allowed to trap during a scan.
    static func int(_ record: [String: Any], _ path: String) -> Int? {
        let found = each(record, path)
        guard !found.isEmpty else { return nil }
        var total = 0
        for value in found {
            guard let integer = integer(value) else { return nil }
            let sum = total.addingReportingOverflow(integer)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    static func double(_ record: [String: Any], _ path: String) -> Double? {
        number(record, path)
    }

    static func number(_ record: [String: Any], _ path: String) -> Double? {
        let found = each(record, path)
        guard !found.isEmpty else { return nil }
        var total = 0.0
        for value in found {
            guard let number = numeric(value) else { return nil }
            total += number
            guard total.isFinite else { return nil }
        }
        return total
    }

    static func numeric(_ value: Any) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let result: Double?
        switch value {
        case let v as Double: result = v
        case let v as Int: result = Double(v)
        case let v as String: result = Double(v)
        default: result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    static func integer(_ value: Any) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if let value = value as? Int { return value }
        if let text = value as? String, let value = Int(text) { return value }
        return numeric(value).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    static func processID(_ value:Any) -> Int32? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let candidate = (value as? Int32).map(Double.init) ?? numeric(value)
        guard let number = candidate, number > 0, number.rounded(.towardZero) == number else { return nil }
        return Int32(exactly:number)
    }

    /// The latest time a path names. ISO strings, and epochs in either seconds
    /// or milliseconds, are all understood — every store writes a different one.
    static func date(_ record: [String: Any], _ path: String) -> Date? {
        each(record, path).compactMap { value -> Date? in
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            switch value {
            case let v as String: return UsageHTTP.parseDate(v)
            case let v as Double: return epoch(v)
            case let v as Int: return epoch(Double(v))
            default: return nil
            }
        }.max()
    }

    static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        // Anything past the year 5138 in seconds is really milliseconds.
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        // Charts and calendar formatters cannot safely represent arbitrary
        // floating-point magnitudes. No supported trace needs a year beyond 9999.
        guard seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The longest window this app will treat as a window.
    ///
    /// Ten years, which is far longer than any plan and far shorter than the
    /// magnitudes a JSON number can carry. Plans have five-hour, daily,
    /// weekly and monthly windows; nothing needs a decade.
    static let maxWindowSeconds = 315_360_000.0

    /// A reported window length, or nothing.
    ///
    /// The same job `epoch` does for dates, and for the same reason. A window
    /// arrives as a JSON number, and a JSON number can be 1e30. Dividing that
    /// into hours and converting the result to an `Int` — which is what
    /// naming a window and drawing its badge both do — is a trap, not a wrong
    /// answer: the menu bar disappears. Verified by running the conversion on
    /// a parsed `1e30`, which exits on SIGTRAP.
    ///
    /// Rejected rather than saturated. A window of ten billion years is not a
    /// window that was read successfully, and a badge reading "2800000000D"
    /// would be a figure this app invented out of a value it did not
    /// understand. Absent is the honest answer, and every caller already has
    /// one for a window it cannot read.
    static func seconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= maxWindowSeconds
        else { return nil }
        return value
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
