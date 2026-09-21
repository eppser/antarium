import Foundation
import Testing
import AntariumHarnessSDK
@testable import Antarium

@Suite("Untrusted numeric boundaries")
struct NumericBoundaryTests {
    @Test("Nonfinite values and booleans are not numeric observations")
    func finiteNumbers() throws {
        for value: Any in ["nan", "inf", "-inf", Double.infinity, Double.nan, true] {
            #expect(FieldPath.number(["v": value], "v") == nil)
        }
        let json = try #require(JSONSerialization.jsonObject(with: Data(#"{"v":true}"#.utf8)) as? [String: Any])
        #expect(FieldPath.number(json, "v") == nil)
        #expect(FieldPath.number(["v": 0], "v") == 0)
        #expect(FieldPath.number(["v": "1.5"], "v") == 1.5)
    }
    /// `numeric` already refuses a value that arrives non-finite, so the
    /// finiteness check in `number` only earns its place on a total: finite
    /// values that overflow to infinity when summed across an array path.
    /// Nothing covered that, and removing the check left every test passing —
    /// which matters because this guard is why the quota mapping does not
    /// need its own NaN handling.
    @Test("Finite values that overflow when summed are unavailable, not infinite")
    func accumulatedOverflow() {
        let record: [String: Any] = ["w": [["v": 1e308], ["v": 1e308]]]
        #expect(FieldPath.number(record, "w[].v") == nil)
        // Two that do not overflow still add up, so the guard is not simply
        // refusing every array path.
        #expect(FieldPath.number(["w": [["v": 1.5], ["v": 2.5]]], "w[].v") == 4)
    }

    /// The same shape one level down: the integer accumulator has its own
    /// overflow check, and an array of large integers is how it is reached.
    @Test("Integers that overflow when summed are unavailable, not wrapped")
    func accumulatedIntegerOverflow() {
        let record: [String: Any] = ["w": [["v": Int.max], ["v": 1]]]
        #expect(FieldPath.int(record, "w[].v") == nil)
        #expect(FieldPath.int(["w": [["v": 2], ["v": 3]]], "w[].v") == 5)
    }

    @Test("Integer conversion is bounded and never traps on external data")
    func boundedIntegers() {
        #expect(FieldPath.int(["v": "nan"], "v") == nil)
        #expect(FieldPath.int(["v": "1e100"], "v") == nil)
        #expect(FieldPath.int(["v": -Double.greatestFiniteMagnitude], "v") == nil)
        #expect(FieldPath.int(["v": 7.75], "v") == 7)
        #expect(FieldPath.int(["v": [["n": 5e18], ["n": 5e18]]], "v[].n") == nil)
    }
    @Test("Process identifiers must be positive, integral and within the platform PID range")
    func processIdentifiers() {
        for value:Any in [Int.max,Double.infinity,true,0,-1,1.5,"1.5","999999999999999999999"] {
            #expect(FieldPath.processID(value) == nil)
        }
        #expect(FieldPath.processID(123) == 123)
        #expect(FieldPath.processID("123") == 123)
        #expect(FieldPath.processID(Int32.max) == Int32.max)
    }
    @Test("Nonfinite timestamps remain unavailable")
    func finiteDates() {
        #expect(FieldPath.epoch(.infinity) == nil)
        #expect(FieldPath.epoch(.nan) == nil)
        #expect(FieldPath.epoch(-1) == nil)
        #expect(FieldPath.epoch(1e300) == nil)
        #expect(FieldPath.date(["v": true], "v") == nil)
        #expect(FieldPath.epoch(1_700_000_000_000)?.timeIntervalSince1970 == 1_700_000_000)
    }
    @Test("The public SDK refuses to emit unsupported semantic versions")
    func sdkVersion() {
        var config = HarnessConfig(id: "fixture", name: "Fixture", process: .init(), source: .init(kind: .none, path: ""))
        config.formatVersion = 999
        #expect(throws: (any Error).self) { try config.encoded() }
    }
}
