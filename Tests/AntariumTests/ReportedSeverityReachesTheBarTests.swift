import AppKit
import Foundation
import Testing
@testable import Antarium

/// A window the service called spent is coloured spent, whatever its number says.
///
/// This is the coherence check for `criticalWhen` and `criticalWhenEquals`. Both
/// set `reportedSeverity`, and both are tested at the rule and in the fixtures —
/// but every other test in this suite passes `reportedSeverity: .normal`, so
/// nothing carried a status-driven critical along the path that ends in a colour.
/// If `StatusRender` or `Renderer` dropped it, every rule added for it would be
/// invisible in the menu bar and every one of those tests would still pass.
///
/// The case that matters is a meter with plenty of headroom: OpenCode reports a
/// rate-limited window at forty per cent used, and forty per cent alone is not
/// even "low". The tool this app is measured against fixed the same defect in its
/// own touch bar on 2026-09-25 — colouring by the displayed number rather than by
/// the quota's status — which is what prompted looking.
@Suite("A status-driven critical reaches the colour", .serialized)
@MainActor
struct ReportedSeverityReachesTheBarTests {

    /// Forty per cent used: sixty per cent left, which is `normal` on headroom
    /// alone. Any colour other than critical here means the status was dropped.
    private func spentButRoomy() -> Snapshot {
        Snapshot(providerID: "opencode", gauges: [
            Gauge(id: "rolling", badge: "ROLL", title: "Rolling", used: 0.4,
                  reportedSeverity: .critical),
        ], extras: [], accountLabel: nil, fetchedAt: Date())
    }

    private func roomyAndFine() -> Snapshot {
        Snapshot(providerID: "opencode", gauges: [
            Gauge(id: "rolling", badge: "ROLL", title: "Rolling", used: 0.4),
        ], extras: [], accountLabel: nil, fetchedAt: Date())
    }

    /// Two colours compared like with like.
    ///
    /// `NSColor` from a palette is a dynamic catalog colour, and two calls that
    /// should give "the same" colour are different instances that compare
    /// unequal — which is how the first version of this suite passed here and
    /// failed under `verify.sh`'s other configurations. Resolved into sRGB first,
    /// which is the same fix a colour test in this repository already needed.
    private func rgba(_ color: NSColor) -> [CGFloat] {
        guard let resolved = color.usingColorSpace(.sRGB) else { return [] }
        return [resolved.redComponent, resolved.greenComponent,
                resolved.blueComponent, resolved.alphaComponent]
    }

    /// The mode is always passed. Its default is `Settings.meterMode`, so a test
    /// that omits it is a test of whatever this Mac is set to — which the comment
    /// on `StatusRender.rows` says in as many words, and which I did anyway.
    private func rows(_ snapshot: Snapshot, mode: MeterMode = .used) -> [StatusRender.Row] {
        StatusRender.rows(for: snapshot, mode: mode)
    }

    @Test("Headroom alone would call this window comfortable")
    func headroomAloneIsNormal() {
        #expect(Severity.forRemaining(0.6) == .normal,
                "the premise is wrong: sixty per cent left is not comfortable")
        #expect(roomyAndFine().gauges[0].severity == .normal)
    }

    /// The gauge itself, which is where `max` of the two is taken.
    @Test("The gauge is critical because the service said so")
    func gaugeIsCritical() {
        #expect(spentButRoomy().gauges[0].severity == .critical)
    }

    /// The row the menu bar draws from, in both meter modes — the fill differs
    /// between them and the severity must not.
    @Test("The row carries it whichever way the meter is set", arguments: MeterMode.allCases)
    func rowCarriesIt(mode: MeterMode) throws {
        let row = try #require(rows(spentButRoomy(), mode: mode).first)
        #expect(row.severity == .critical,
                Comment(rawValue: "mode \(mode): the status was dropped on the way to the row"))
        // And the fill is still the real figure — marking a window spent must not
        // move the bar, only its colour.
        let fill = try #require(row.fill)
        #expect(abs(fill - (mode == .used ? 0.4 : 0.6)) < 0.0001,
                Comment(rawValue: "mode \(mode): fill \(fill) is not the reported figure"))
    }

    /// And the colour, which is the end of the path.
    @Test("The colour is the critical one, not the ordinary one")
    func colourIsCritical() throws {
        let critical = rgba(Renderer.color(for: .critical, agentID: "opencode", row: 0))
        let normal = rgba(Renderer.color(for: .normal, agentID: "opencode", row: 0))
        #expect(!critical.isEmpty, "a palette colour could not be resolved")
        #expect(critical != normal, "critical and normal draw the same colour")
        let row = try #require(rows(spentButRoomy()).first)
        #expect(rgba(Renderer.color(for: row.severity, agentID: "opencode", row: 0)) == critical,
                "a window the service called spent drew the ordinary colour")
    }

    /// The inverse, so the assertion above is about the status rather than about
    /// everything being critical: an ordinary window at the same figure draws the
    /// ordinary colour.
    @Test("An ordinary window at the same figure draws the ordinary colour")
    func ordinaryStaysOrdinary() throws {
        let row = try #require(rows(roomyAndFine()).first)
        #expect(row.severity == .normal)
        #expect(rgba(Renderer.color(for: row.severity, agentID: "opencode", row: 0))
                == rgba(Renderer.color(for: .normal, agentID: "opencode", row: 0)))
    }

    /// Headroom still wins where it is worse, so the `max` works in both
    /// directions rather than the status simply overriding.
    @Test("A window with no headroom is critical even when the service says nothing")
    func headroomStillDecides() {
        let empty = Snapshot(providerID: "opencode", gauges: [
            Gauge(id: "rolling", badge: "ROLL", title: "Rolling", used: 0.98),
        ], extras: [], accountLabel: nil, fetchedAt: Date())
        #expect(empty.gauges[0].severity == .critical)
        #expect(rows(empty).first?.severity == .critical)
    }

    /// The shipped descriptor, end to end: OpenCode's own rule, its own reply,
    /// through the mapping to the colour. This is the whole claim in one case.
    @Test("OpenCode's rate-limited window draws the critical colour")
    func opencodeEndToEnd() throws {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "opencode" })
        let provider = try #require(DescriptorProvider(descriptor))
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(#"""
        {"usage":{"rolling":{"status":"rate-limited","percent":40,
                             "resetsAt":"2026-09-27T00:00:00.000Z"}}}
        """#.utf8)) as? [String: Any])
        let snapshot = try provider.makeSnapshot(reply)
        let gauge = try #require(snapshot.gauges.first)
        #expect(abs(gauge.used - 0.4) < 0.0001, "the figure the service gave was changed")
        let row = try #require(rows(snapshot).first)
        #expect(rgba(Renderer.color(for: row.severity, agentID: "opencode", row: 0))
                == rgba(Renderer.color(for: .critical, agentID: "opencode", row: 0)),
                "a blocked OpenCode window at forty per cent drew a comfortable colour")
    }
}
