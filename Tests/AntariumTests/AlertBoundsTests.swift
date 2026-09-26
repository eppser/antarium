import Foundation
import Testing
@testable import Antarium

/// How many banners may be on screen, and how loud a sweep may be.
///
/// Nothing bounded either. A sweep that finds a fleet of agents finished
/// posted one borderless panel per row and played one sound per row: past
/// five the panels are off the bottom of an ordinary screen, still alive and
/// still holding a SwiftUI tree for twelve seconds, and the sounds arrive on
/// top of each other saying nothing twenty times.
@Suite("Alerts are bounded in number and in noise")
struct AlertBoundsTests {

    @Test("Below the limit, nothing is retired")
    func belowLimitRetiresNothing() {
        for showing in 0..<AgentAlert.maxVisible {
            #expect(AgentAlert.surplus(showing: showing) == 0,
                    "a banner was retired to make room that already existed")
        }
    }

    /// At the limit, one has to go for the new one to fit — the count after
    /// posting is what the limit is about.
    @Test("At the limit, exactly one is retired")
    func atLimitRetiresOne() {
        #expect(AgentAlert.surplus(showing: AgentAlert.maxVisible) == 1)
    }

    /// A backlog is cleared down to the limit rather than one at a time, so a
    /// burst does not take several sweeps to settle.
    @Test("Above the limit, the whole surplus goes")
    func aboveLimitClearsTheBacklog() {
        #expect(AgentAlert.surplus(showing: AgentAlert.maxVisible + 4) == 5)
        #expect(AgentAlert.surplus(showing: 20, limit: 5) == 16)
    }

    /// The arithmetic that was easy to get wrong: the limit counts what is on
    /// screen *after* the new banner arrives.
    @Test("The limit is what remains after posting", arguments: [1, 2, 3, 5, 9])
    func limitCountsWhatRemains(_ limit: Int) {
        for showing in 0...(limit + 3) {
            let remaining = showing - AgentAlert.surplus(showing: showing, limit: limit) + 1
            #expect(remaining <= limit,
                    "posting onto \(showing) with a limit of \(limit) left \(remaining)")
        }
    }

    /// A limit of nothing would retire every banner including the one being
    /// posted, which is a setting nobody has — but the arithmetic should not
    /// go negative if it ever did.
    @Test("A limit of zero retires everything and nothing goes negative")
    func zeroLimitIsSane() {
        #expect(AgentAlert.surplus(showing: 0, limit: 0) == 1)
        #expect(AgentAlert.surplus(showing: 3, limit: 0) == 4)
    }

    @Test("The shipped limit is a number somebody chose")
    func shippedLimit() {
        #expect(AgentAlert.maxVisible == 5)
    }
}

/// Which banners go when a new one arrives.
///
/// `post` inserts the newest at the front, so the surplus is at the back.
/// Taking it from the front instead would retire the arrival the user is
/// meant to see and keep the five they have already read — which looks like
/// the alert simply not appearing.
@Suite("The oldest banners are the ones retired")
struct AlertRetirementTests {

    @Test("Nothing is retired while there is room")
    func nothingRetiredWithRoom() {
        #expect(AgentAlert.retiring([1, 2, 3], limit: 5).isEmpty)
    }

    /// Newest first, so [5, 4, 3, 2, 1] is five banners with 1 the oldest.
    @Test("At the limit, the oldest goes")
    func oldestGoesFirst() {
        #expect(Array(AgentAlert.retiring([5, 4, 3, 2, 1], limit: 5)) == [1])
    }

    @Test("A backlog gives up its oldest, in order")
    func backlogGivesUpItsOldest() {
        #expect(Array(AgentAlert.retiring([9, 8, 7, 6, 5, 4, 3], limit: 5)) == [5, 4, 3])
    }

    /// Whenever anything survives, the newest is among the survivors.
    ///
    /// Stated this way because the banner being posted is not in the list
    /// yet: `showing[0]` is the newest of the *existing* ones. The first
    /// version of this asserted it always survives, which is false at a limit
    /// of one — where the arrival is the only thing that should remain, so
    /// every existing banner correctly goes.
    @Test("While any banner survives, the newest of them does", arguments: [2, 3, 5, 8])
    func newestSurvivesWhenAnyDo(_ limit: Int) {
        let showing = Array((0..<12).reversed())
        let retired = Set(AgentAlert.retiring(showing, limit: limit))
        let survivors = showing.filter { !retired.contains($0) }
        #expect(!survivors.isEmpty, "a limit of \(limit) left nothing at all")
        #expect(survivors.first == showing.first,
                "the newest existing banner was retired before an older one")
    }

    /// And the limit of one, which is the case that reads wrongly: the
    /// arrival is the only banner that should remain, so everything showing
    /// goes.
    @Test("A limit of one retires everything showing")
    func limitOfOneClearsTheScreen() {
        let showing = Array((0..<12).reversed())
        #expect(AgentAlert.retiring(showing, limit: 1).count == showing.count)
    }
}
