import Foundation
import Testing
@testable import Antarium

/// Responses carrying numbers no account produces.
///
/// Not a security suite — these are the shapes a service returns when
/// something has gone wrong at its end, or when a field means something other
/// than what it was read as. What makes them worth their own file is the
/// failure mode: `Int(someDouble)` traps when the value is outside `Int`'s
/// range, so a single absurd JSON number took the whole menu bar down rather
/// than reporting a window it could not read. A crash is not a way of
/// declining to answer.
///
/// Every one of these ran against the parsers as they were and exited on
/// SIGTRAP.
@Suite("A response with absurd numbers in it is refused, not fatal")
struct HostileResponseTests {

    /// Larger than `Int.max` by twelve orders of magnitude, and perfectly
    /// legal JSON.
    private let absurd = 1e30

    @Test("A bound is what makes the conversions below safe")
    func windowsAreBounded() {
        #expect(FieldPath.seconds(absurd) == nil)
        #expect(FieldPath.seconds(.nan) == nil)
        #expect(FieldPath.seconds(.infinity) == nil)
        #expect(FieldPath.seconds(0) == nil, "a window of no length is not a window")
        #expect(FieldPath.seconds(-3600) == nil)
        // And an ordinary window is untouched, or the bound would be a way of
        // reporting nothing at all.
        #expect(FieldPath.seconds(18_000) == 18_000)
        #expect(FieldPath.seconds(FieldPath.maxWindowSeconds) == FieldPath.maxWindowSeconds)
    }

    @Test("A Cursor bucket with an unreadable maximum is skipped, not fatal")
    func cursorLegacyAbsurdMaximum() throws {
        #expect(throws: (any Error).self) {
            _ = try CursorProvider.makeSnapshotFromLegacy(
                ["premium": ["maxRequestUsage": absurd, "numRequests": 5]], planName: nil)
        }
    }

    /// And one bad bucket does not take the good ones with it.
    @Test("A readable Cursor bucket survives an unreadable one beside it")
    func cursorLegacyMixed() throws {
        let snapshot = try CursorProvider.makeSnapshotFromLegacy([
            "premium": ["maxRequestUsage": absurd, "numRequests": 5],
            "standard": ["maxRequestUsage": 100, "numRequests": 25],
        ], planName: nil)
        #expect(snapshot.gauges.map(\.id) == ["standard"])
        #expect(snapshot.gauges.first?.used == 0.25)
    }

    /// Two buckets at the same percentage used to produce a different primary
    /// gauge on each launch: the buckets come out of a dictionary, whose order
    /// differs between processes, and Swift's sort is not stable. Same
    /// account, same response, a menu bar that changed its mind.
    @Test("Two Cursor buckets at the same percentage always pick the same one")
    func cursorLegacyTiesAreStable() throws {
        let response: [String: Any] = [
            "alpha": ["maxRequestUsage": 100, "numRequests": 50],
            "beta": ["maxRequestUsage": 200, "numRequests": 100],
            "gamma": ["maxRequestUsage": 10, "numRequests": 5],
        ]
        let snapshot = try CursorProvider.makeSnapshotFromLegacy(response, planName: nil)
        #expect(snapshot.gauges.first?.id == "alpha", "ties broke somewhere other than the name")

        // Driven through the dictionary the response arrives as, the ordering
        // cannot be made to fail: within one process a dictionary of these
        // keys yields the same order every time, so the assertion above holds
        // whether ties are broken or not and only differs between machines.
        // The decision is a function over an array for that reason, and this
        // is the input it could never have received by accident.
        func gauge(_ id: String, _ used: Double) -> Gauge {
            Gauge(id: id, badge: "", title: id, used: used)
        }
        #expect(CursorProvider.ordered(
            [gauge("beta", 0.5), gauge("alpha", 0.5), gauge("gamma", 0.9)])
            .map(\.id) == ["gamma", "alpha", "beta"],
                "the fullest bucket did not come first, or the tie kept its input order")
    }

    @Test("A Codex window of absurd length is unnamed rather than fatal")
    func codexAbsurdWindow() throws {
        let snapshot = try CodexProvider.makeSnapshot([
            "rate_limit": ["primary_window": ["used_percent": 40,
                                              "limit_window_seconds": absurd]],
        ])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.used == 0.4, "the figure it could read was dropped with the one it could not")
        #expect(gauge.windowSeconds == nil)
        #expect(gauge.title == "Usage", "a window it could not read was given a name anyway")
    }

    @Test("A Codex reset in the year ten billion is no reset at all")
    func codexAbsurdReset() throws {
        for key in ["reset_at", "resets_at_epoch", "reset_after_seconds", "resets_in_seconds"] {
            let snapshot = try CodexProvider.makeSnapshot([
                "rate_limit": ["primary_window": ["used_percent": 40, key: absurd]],
            ])
            let gauge = try #require(snapshot.gauges.first)
            #expect(gauge.resetsAt == nil, Comment(rawValue: "\(key) produced a reset date"))
            #expect(gauge.used == 0.4)
        }
    }

    /// The ordinary values still arrive, or the bounds above would be a way
    /// of reporting nothing at all.
    @Test("A plausible Codex window is named and dated as before")
    func codexOrdinaryWindow() throws {
        let soon = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let snapshot = try CodexProvider.makeSnapshot([
            "rate_limit": ["primary_window": ["used_percent": 40,
                                              "limit_window_seconds": 18_000,
                                              "reset_at": soon]],
        ])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.title == "Session (5 hours)")
        #expect(gauge.windowSeconds == 18_000)
        #expect(gauge.resetsAt != nil)
    }

    @Test("A descriptor badge falls back rather than converting an absurd window")
    func descriptorBadge() {
        #expect(DescriptorProvider.badge(seconds: absurd, fallback: "weekly") == "WEE")
        #expect(DescriptorProvider.badge(seconds: .nan, fallback: "weekly") == "WEE")
        #expect(DescriptorProvider.badge(seconds: 18_000, fallback: "weekly") == "5H")
        #expect(DescriptorProvider.badge(seconds: 604_800, fallback: "weekly") == "7D")
    }
}
