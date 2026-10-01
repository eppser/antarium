import Foundation
import Testing
@testable import Antarium

/// Selecting one element of an array by what is in it.
///
/// `[]` and `[-1]` were the whole vocabulary, and between them they cannot
/// name "the entry for this plan". Every usage API that reports more than one
/// thing at a time needs that: a response with one entry per billing scope,
/// or one per rate-limit window, has no position a descriptor can rely on —
/// the order is the server's business and it changes.
///
/// What made this worth adding rather than working around is how `[]` fails
/// on such a response. `FieldPath.int` sums every value a path names, so
/// `usages[].detail.limit` against a two-scope response is the two limits
/// added together: a plausible number, in the right units, wrong. There is no
/// missing data for anything to notice.
@Suite("A field path selects array elements by field")
struct FieldPathFilterTests {

    /// Shaped after the response this was added for — a Connect-RPC billing
    /// reply with one entry per scope, each carrying a weekly total and an
    /// array of rate-limit windows. Synthetic figures, real shape: the counts
    /// arrive as strings and the window length as a number, in one payload,
    /// which is the case a filter has to handle on both sides.
    private var response: [String: Any] {
        [
            "usages": [
                [
                    "scope": "FEATURE_CHAT",
                    "detail": ["limit": "100", "used": "10", "remaining": "90"],
                    "limits": [["window": ["duration": 60, "timeUnit": "TIME_UNIT_MINUTE"],
                                "detail": ["limit": "20", "remaining": "20"]]],
                ],
                [
                    "scope": "FEATURE_CODING",
                    "detail": ["limit": "2048", "used": "512", "remaining": "1536"],
                    "limits": [
                        ["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                         "detail": ["limit": "400", "remaining": "250"]],
                        ["window": ["duration": 7, "timeUnit": "TIME_UNIT_DAY"],
                         "detail": ["limit": "2048", "remaining": "1536"]],
                    ],
                ],
            ],
        ]
    }

    // MARK: - What was already there

    @Test("An empty bracket still names every element")
    func allStillMeansAll() {
        #expect(FieldPath.each(response, "usages[].scope").count == 2)
        // Both limits added, which is `[]`'s documented meaning and exactly
        // why the filter below had to exist.
        #expect(FieldPath.int(response, "usages[].detail.limit") == 2148)
    }

    @Test("A negative-one bracket still names the last element")
    func lastStillMeansLast() {
        #expect(FieldPath.string(response, "usages[-1].scope") == "FEATURE_CODING")
        #expect(FieldPath.int(response, "usages[-1].detail.limit") == 2048)
    }

    @Test("A path with no bracket is still the single value")
    func plainPath() {
        #expect(FieldPath.int(["a": ["b": 7]], "a.b") == 7)
        #expect(FieldPath.int(["a": ["b": 7]], "a.c") == nil)
    }

    // MARK: - The filter

    @Test("A filter names only the entry whose field matches")
    func filterSelectsOne() {
        #expect(FieldPath.string(response, "usages[scope=FEATURE_CODING].scope") == "FEATURE_CODING")
        #expect(FieldPath.int(response, "usages[scope=FEATURE_CODING].detail.limit") == 2048,
                "the other scope's limit was added in")
        #expect(FieldPath.int(response, "usages[scope=FEATURE_CHAT].detail.remaining") == 90)
    }

    /// The half a string comparison would get wrong. This payload states the
    /// window length as the number 300 and the counts beside it as strings, so
    /// a filter that compared only strings would work on one field and not the
    /// other in the same response.
    @Test("A numeric field matches a filter written as text")
    func numberMatchesText() {
        let path = "usages[scope=FEATURE_CODING].limits[window.duration=300].detail.remaining"
        #expect(FieldPath.int(response, path) == 250)
    }

    @Test("Two brackets in one path each filter their own array")
    func nestedFilters() {
        let path = "usages[scope=FEATURE_CODING].limits[window.timeUnit=TIME_UNIT_DAY].detail.limit"
        #expect(FieldPath.int(response, path) == 2048)
    }

    @Test("Every clause of a filter must hold")
    func everyClause() {
        let base = "usages[scope=FEATURE_CODING].limits"
        #expect(FieldPath.int(response,
                              base + "[window.duration=300,window.timeUnit=TIME_UNIT_MINUTE].detail.remaining")
                == 250)
        // Right duration, wrong unit: a window of 300 days is not this one.
        #expect(FieldPath.int(response,
                              base + "[window.duration=300,window.timeUnit=TIME_UNIT_DAY].detail.remaining")
                == nil)
    }

    /// The distinction the whole file protects. A filter that matches nothing
    /// has found no data, and no data is not a zero — a gauge reading "0 left"
    /// on a plan with plenty left is worse than a gauge that does not appear.
    @Test("A filter that matches nothing is absent, not zero")
    func noMatchIsAbsent() {
        #expect(FieldPath.int(response, "usages[scope=FEATURE_UNKNOWN].detail.limit") == nil)
        #expect(FieldPath.string(response, "usages[scope=FEATURE_UNKNOWN].scope") == nil)
        #expect(FieldPath.each(response, "usages[scope=FEATURE_UNKNOWN]").isEmpty)
    }

    @Test("A filter may match several entries, and then names all of them")
    func severalMatches() {
        let many: [String: Any] = ["rows": [["kind": "a", "n": 1], ["kind": "a", "n": 2],
                                            ["kind": "b", "n": 30]]]
        #expect(FieldPath.int(many, "rows[kind=a].n") == 3)
    }

    // MARK: - Filters that are not filters

    /// A misspelled filter must select nothing. The tempting alternative — fall
    /// back to every element — turns a typo into a summed figure, which is the
    /// failure this feature exists to prevent.
    @Test("A bracket that is not a filter selects nothing", arguments: [
        "usages[scope]", "usages[=FEATURE_CODING]", "usages[scope=]",
        "usages[scope=FEATURE_CODING,]", "usages[,]", "usages[ ]. scope",
    ])
    func malformed(path: String) {
        #expect(FieldPath.each(response, path).isEmpty,
                Comment(rawValue: "\(path) selected something"))
    }

    @Test("An unclosed bracket is not a bracket group")
    func unclosed() {
        #expect(FieldPath.each(response, "usages[scope=FEATURE_CODING").isEmpty)
    }

    @Test("What a bracket's contents mean is decidable on its own")
    func selectionIsCallable() {
        #expect(FieldPath.selection("") == .all)
        #expect(FieldPath.selection("  ") == .all)
        #expect(FieldPath.selection("-1") == .last)
        #expect(FieldPath.selection("a=1") == .matching([.init(path: "a", value: "1")]))
        #expect(FieldPath.selection(" a.b = 1 , c = 2 ")
                == .matching([.init(path: "a.b", value: "1"), .init(path: "c", value: "2")]))
        #expect(FieldPath.selection("a") == .malformed)
        #expect(FieldPath.selection("=1") == .malformed)
        #expect(FieldPath.selection("a=") == .malformed)
    }

    /// A field stated as null matches nothing, and says nothing.
    ///
    /// `JSONSerialization` hands a null back as `NSNull`, which is neither a
    /// string nor a number nor absent. Reading it as the empty string would
    /// let `[scope=]` match it — except that group is refused — and reading
    /// it as zero would let `[n=0]` match a field that stated no number. It
    /// matches nothing, which is the same answer an absent field gets,
    /// because a filter has nothing to say about the difference.
    @Test("A field stated as null matches no filter")
    func nullMatchesNothing() throws {
        let data = Data(#"{"rows":[{"scope":null,"n":1},{"scope":"C","n":2}]}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(FieldPath.int(json, "rows[scope=C].n") == 2)
        #expect(FieldPath.int(json, "rows[scope=null].n") == nil,
                "a null was matched by the text null")
        #expect(FieldPath.comparable(NSNull()) == nil)
        // And it does not swallow the entry that does match, which is the way
        // this would fail quietly: a filter that threw on the null row.
        #expect(FieldPath.each(json, "rows[scope=C]").count == 1)
    }

    /// A value containing a comma cannot be filtered on, and that limit is
    /// loud rather than quiet: the clause splits, the group reads as
    /// malformed, and the document boundary refuses it naming the group. An
    /// author who needs one finds out at `--check` rather than by a gauge
    /// never appearing.
    @Test("A filter value cannot contain the separator, and says so")
    func separatorInValue() {
        #expect(FieldPath.selection("note=a,b") == .malformed)
        #expect(FieldPath.each(["rows": [["note": "a,b", "n": 1]]], "rows[note=a,b].n").isEmpty)
    }

    // MARK: - What a filter can compare

    @Test("A filter compares the values JSON actually carries")
    func comparableValues() {
        #expect(FieldPath.comparable("text") == "text")
        #expect(FieldPath.comparable(300) == "300")
        #expect(FieldPath.comparable(300.0) == "300", "an integral number compared as a decimal")
        #expect(FieldPath.comparable(1.5) == "1.5")
        #expect(FieldPath.comparable(true) == "true")
        #expect(FieldPath.comparable(false) == "false")
        #expect(FieldPath.comparable(nil) == nil)
        #expect(FieldPath.comparable(Double.nan) == nil)
        #expect(FieldPath.comparable(Double.infinity) == nil)
        #expect(FieldPath.comparable(["a": 1]) == nil, "an object compared as something")
        #expect(FieldPath.comparable([1, 2]) == nil, "an array compared as something")
    }

    /// A boolean read out of parsed JSON rather than written as a literal.
    /// `JSONSerialization` hands back `NSNumber` for both booleans and
    /// integers, and a bool bridges to `Int` as 1 — so a filter on a flag
    /// would compare against "1" if the bool were not decided first.
    @Test("A flag from parsed JSON compares as true or false")
    func flagFromJSON() throws {
        let data = Data(#"{"rows":[{"live":true,"n":5},{"live":false,"n":9}]}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(FieldPath.int(json, "rows[live=true].n") == 5)
        #expect(FieldPath.int(json, "rows[live=false].n") == 9)
    }

    /// And the counts, read the same way, so the string coercion is exercised
    /// against real parsed JSON rather than Swift literals.
    @Test("Counts reported as strings are still numbers")
    func countsAsStrings() throws {
        let data = Data(#"{"usages":[{"scope":"C","detail":{"limit":"2048","remaining":"1536"}}]}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(FieldPath.int(json, "usages[scope=C].detail.remaining") == 1536)
    }
}
