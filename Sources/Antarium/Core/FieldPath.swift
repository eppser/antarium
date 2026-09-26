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

    /// The single value a path names, filters included.
    ///
    /// `lookup` is the fast path for a plain dotted path and cannot see a
    /// bracket group at all — it would ask for a member literally called
    /// `usages[scope=FEATURE_CODING]`. This sees them, and takes the first
    /// match, because the callers are asking for a container: one object
    /// holding windows, or one window. For a path with no bracket it is
    /// `lookup` unchanged, which is what every descriptor written so far uses.
    static func first(_ record: [String: Any], _ path: String) -> Any? {
        path.contains("[") ? each(record, path).first : lookup(record, path)
    }

    /// Which elements of an array a bracket group names.
    enum Selection: Equatable {
        /// `[]` — all of them.
        case all
        /// `[-1]` — the last one.
        case last
        /// `[key=value]`, or several separated by commas, all of which must
        /// hold. The key is itself a path, so `[window.duration=300]` reaches
        /// into each element.
        case matching([Clause])
        /// A bracket group that is none of the above. Selects nothing, rather
        /// than being ignored: a descriptor that misspells a filter should
        /// read as no data, never as every element.
        case malformed

        struct Clause: Equatable {
            let path: String
            let value: String
        }
    }

    /// Every value a path names.
    ///
    /// `a.b[].c` is the `c` of every element of the array at `a.b`; `a.b[-1].c`
    /// is only the last one's; `a.b[k=v].c` is only those whose `k` is `v`.
    /// Anything else is the single value, or nothing.
    ///
    /// The filter is what a Connect-RPC usage response needs and `[]` cannot
    /// do. Kimi returns one entry per billing scope in one array and the
    /// five-hour window beside the weekly one in another, so `usages[].detail.limit`
    /// is not the coding plan's limit — it is the sum of every scope's, because
    /// `int` adds up everything a path names. That sum is a number this app
    /// would have invented. A path either names the one entry meant or names
    /// nothing.
    static func each(_ record: [String: Any], _ path: String) -> [Any] {
        guard let group = bracket(path) else {
            return lookup(record, path).map { [$0] } ?? []
        }
        guard let array = lookup(record, group.prefix) as? [[String: Any]] else { return [] }
        let selected: [[String: Any]]
        switch selection(group.inner) {
        case .all: selected = array
        case .last: selected = array.suffix(1).map { $0 }
        case .malformed: return []
        case .matching(let clauses):
            selected = array.filter { entry in
                clauses.allSatisfy { comparable(lookup(entry, $0.path)) == $0.value }
            }
        }
        // Resolved through `each` rather than `lookup` so a filter can be
        // followed by another one: the window Kimi reports its five-hour limit
        // in sits inside the scope entry, and reaching it means two brackets in
        // one path. Each call drops everything up to and including its own
        // `]`, so the recursion is strictly shorter every time.
        return suffix(selected, group.suffix)
    }

    private static func suffix(_ entries: [[String: Any]], _ path: String) -> [Any] {
        guard !path.isEmpty else { return entries }
        return entries.flatMap { each($0, path) }
    }

    /// The first bracket group in a path, and what surrounds it.
    private static func bracket(_ path: String) -> (prefix: String, inner: String, suffix: String)? {
        guard let open = path.firstIndex(of: "["),
              let close = path[open...].firstIndex(of: "]") else { return nil }
        let dots = CharacterSet(charactersIn: ".")
        return (String(path[path.startIndex..<open]).trimmingCharacters(in: dots),
                String(path[path.index(after: open)..<close]),
                String(path[path.index(after: close)...]).trimmingCharacters(in: dots))
    }

    /// What a bracket group's contents select. Callable on its own, because
    /// the descriptor validator has to reject a malformed filter at `--check`
    /// time and the alternative is a path that reads as no data on a user's
    /// machine with nothing saying why.
    static func selection(_ inner: String) -> Selection {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .all }
        if trimmed == "-1" { return .last }
        var clauses: [Selection.Clause] = []
        for clause in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            guard let equals = clause.firstIndex(of: "=") else { return .malformed }
            let key = clause[clause.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = clause[clause.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // An empty half is a typo, not a filter on emptiness. No usage API
            // reports a field whose value is the empty string as the thing
            // that identifies it, and reading `[scope=]` as "scope is blank"
            // would match nothing while looking like it matched deliberately.
            guard !key.isEmpty, !value.isEmpty else { return .malformed }
            clauses.append(Selection.Clause(path: key, value: value))
        }
        // No empty-list case to guard. `omittingEmptySubsequences: false` always
        // yields at least one element, and an element without an `=` has already
        // returned `.malformed` — so a guard here could only ever be dead, and a
        // catalogue entry for it could only ever survive.
        return .matching(clauses)
    }

    /// A JSON value as the text a descriptor would write for it, or nothing
    /// when it is not a value a filter can compare.
    ///
    /// Written out rather than compared as `Any` because the two sides arrive
    /// differently: the descriptor's half is always text, and the response's
    /// half is whatever JSON said. Kimi states the same window's length as the
    /// number 300 and its counts as the strings "1024" and "512" in one
    /// payload, so a filter that only matched strings would work on half of
    /// its own response.
    static func comparable(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if let text = value as? String { return text }
        if let integer = value as? Int { return String(integer) }
        guard let number = value as? Double, number.isFinite else { return nil }
        // An integral value is written the way a descriptor writes it, whatever
        // Swift type carried it here. Parsed JSON hands back `NSNumber`, whose
        // conditional cast to `Int` checks exactness and so takes the branch
        // above; a `Double` built in Swift does not, and 300 would have
        // compared as "300.0" and matched nothing. Which of the two a value
        // arrived as is not something a descriptor can know.
        if number == number.rounded(), let integer = Int(exactly: number) {
            return String(integer)
        }
        return String(number)
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
    ///
    /// `first`, not `lookup`, so the path may filter. Its caller already asked
    /// whether the path names a collection at all and did so through `first` —
    /// so a filtered path reported as present and then counted nothing, which
    /// is a count of zero for a collection that is there.
    static func count(_ record: [String: Any], path: String, match: [String: String]) -> Int {
        let entries: [[String: Any]]
        switch first(record, path) {
        case let dict as [String: Any]: entries = dict.values.compactMap { $0 as? [String: Any] }
        case let array as [[String: Any]]: entries = array
        default: entries = []
        }
        return entries.filter { entry in
            match.allSatisfy { (entry[$0.key] as? String) == $0.value }
        }.count
    }
}
