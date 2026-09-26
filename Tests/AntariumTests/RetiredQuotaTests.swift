import Foundation
import Testing
@testable import Antarium

/// A reading that outlived the item that fetched it.
///
/// Switching an agent off disposes its menu bar item, and disposal removes its
/// reading. A fetch already in flight finishes afterwards, holds the item
/// strongly, and publishes — and by then there is no item left to publish
/// again. So the dashboard kept drawing that agent's gauge and plan label,
/// frozen at whatever the last fetch returned, until the app was relaunched.
///
/// Enforced in the store rather than as a flag on the item, because this is
/// the side a test can reach: constructing an `AgentItem` needs a status bar,
/// which is why the wiring between disposal and removal was noted in that file
/// as held by reading rather than by a test.
@Suite("A disabled provider's reading cannot come back", .serialized)
@MainActor
struct RetiredQuotaTests {

    private func snapshot(_ id: String, used: Double = 0.5) -> Snapshot {
        Snapshot(providerID: id,
                 gauges: [Gauge(id: "w", badge: "5H", title: "Session", used: used)],
                 extras: [], accountLabel: "test plan", fetchedAt: Date())
    }

    private func store() -> QuotaStore {
        let store = QuotaStore.shared
        store.remove(providerID: "synthetic")
        store.admit(providerID: "synthetic")
        return store
    }

    /// The race, in order.
    @Test("A fetch that lands after disposal is refused")
    func lateFetchIsRefused() {
        let store = store()
        store.set(providerID: "synthetic", snapshot: snapshot("synthetic"))
        #expect(store.snapshot(for: "synthetic") != nil, "the reading never arrived")

        store.remove(providerID: "synthetic")            // dispose()
        store.set(providerID: "synthetic", snapshot: snapshot("synthetic", used: 0.9))

        #expect(store.snapshot(for: "synthetic") == nil,
                "a reading arrived after the provider's item was gone")
    }

    /// The same for a failed fetch, which publishes down a different path.
    @Test("A failure that lands after disposal is refused")
    func lateFailureIsRefused() {
        let store = store()
        store.remove(providerID: "synthetic")
        store.set(providerID: "synthetic", error: .badResponse("late"),
                  last: snapshot("synthetic"))
        #expect(store.snapshot(for: "synthetic") == nil)
        #expect(store.errors["synthetic"] == nil,
                "an error arrived after the provider's item was gone")
    }

    /// And the other direction, which would be the worse bug: switching the
    /// agent back on has to work, for the rest of the session and not just
    /// until the next restart.
    @Test("Switching the agent on again accepts readings")
    func readmissionWorks() {
        let store = store()
        store.remove(providerID: "synthetic")
        store.admit(providerID: "synthetic")             // a new item exists
        store.set(providerID: "synthetic", snapshot: snapshot("synthetic", used: 0.25))
        let back = store.snapshot(for: "synthetic")
        #expect(back != nil, "the provider was switched back on and stayed silent")
        #expect(back?.gauges.first?.used == 0.25)
    }

    /// Retiring one provider does not silence another.
    @Test("One provider retiring leaves the others alone")
    func retirementIsPerProvider() {
        let store = store()
        store.admit(providerID: "other")
        store.remove(providerID: "synthetic")
        store.set(providerID: "other", snapshot: snapshot("other"))
        #expect(store.snapshot(for: "other") != nil,
                "retiring one provider refused another's reading")
        store.remove(providerID: "other")
    }

    /// A provider nothing has ever retired is accepted without being admitted,
    /// or the first reading of every launch would be dropped.
    @Test("A provider that has never been retired needs no admission")
    func freshProvidersAreAccepted() {
        let store = QuotaStore.shared
        store.remove(providerID: "never-seen")
        store.admit(providerID: "never-seen")
        store.remove(providerID: "never-seen")
        // A genuinely untouched id.
        store.set(providerID: "untouched-\(UUID().uuidString)", snapshot: snapshot("x"))
        let id = "first-launch-\(UUID().uuidString)"
        store.set(providerID: id, snapshot: snapshot(id))
        #expect(store.snapshot(for: id) != nil,
                "a provider's first reading was refused")
        store.remove(providerID: id)
    }
}
