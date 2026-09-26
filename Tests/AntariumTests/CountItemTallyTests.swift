import Foundation
import Testing
@testable import Antarium

/// The number in the menu bar, which is the whole point of the app for
/// anyone not looking at the dashboard. Four mutations of it survived: a
/// looping agent counted as idle, an unobservable one counted as finished, a
/// shell counted as waiting, and the total leaving out what it cannot see.
@Suite("The menu bar count says what is actually happening")
@MainActor
struct CountItemTallyTests {

    private func row(_ state: AgentRow.State) -> AgentRow {
        AgentRow(id: UUID().uuidString, agentID: "claude-code", name: "s",
                 cwd: "/p", state: state)
    }

    @Test("Nothing running counts as nothing")
    func empty() {
        let tally = CountItem.Tally()
        #expect(tally.total == 0)
        #expect(tally.working == 0 && tally.waiting == 0
                && tally.unknown == 0 && tally.ended == 0)
    }

    /// The signal the whole badge exists for: green means working, and the
    /// other number means an agent has stopped and wants you.
    @Test("Working and waiting are counted apart")
    func workingAndWaiting() {
        let tally = CountItem.Tally([row(.working), row(.working), row(.waiting)])
        #expect(tally.working == 2)
        #expect(tally.waiting == 1)
    }

    /// A loop pausing between rounds has not stopped. Counting it as waiting
    /// tells the user to come back to an agent that is still going.
    @Test("A looping agent is working, not waiting")
    func loopingIsWorking() {
        let tally = CountItem.Tally([row(.looping)])
        #expect(tally.working == 1)
        #expect(tally.waiting == 0, "a running loop asked for attention it does not need")
    }

    /// A shell is an agent doing something, even though nothing is being
    /// generated.
    @Test("A shell is working")
    func shellIsWorking() {
        #expect(CountItem.Tally([row(.shell)]).working == 1)
        #expect(CountItem.Tally([row(.shell)]).waiting == 0)
    }

    /// Losing sight of an agent is not the same as it finishing. Counting an
    /// unobservable row as ended reports a conclusion nobody reached.
    @Test("An agent that cannot be observed is unknown, not ended")
    func unobservedIsUnknown() {
        let tally = CountItem.Tally([row(.unobserved)])
        #expect(tally.unknown == 1)
        #expect(tally.ended == 0, "an agent we cannot see was declared finished")
    }

    @Test("A cloud task is unknown rather than counted as local work")
    func cloudIsUnknown() {
        let tally = CountItem.Tally([row(.cloud("synthetic"))])
        #expect(tally.unknown == 1)
        #expect(tally.working == 0)
    }

    @Test("An ended agent is counted as ended")
    func endedIsEnded() {
        #expect(CountItem.Tally([row(.ended)]).ended == 1)
    }

    /// The total has to include what could not be determined, or the badge
    /// reports fewer agents than the dashboard lists.
    @Test("The total counts every row, including the ones we cannot see")
    func totalIncludesUnknown() {
        let tally = CountItem.Tally([row(.working), row(.waiting),
                                     row(.unobserved), row(.cloud("synthetic")), row(.ended)])
        #expect(tally.total == 5)
        #expect(tally.working + tally.waiting + tally.unknown + tally.ended == 5)
    }

    @Test("Two tallies of the same rows are equal")
    func tallyIsValue() {
        let rows = [row(.working), row(.waiting), row(.ended)]
        #expect(CountItem.Tally(rows) == CountItem.Tally(rows))
        #expect(CountItem.Tally(rows) != CountItem.Tally([row(.working)]))
    }
}
