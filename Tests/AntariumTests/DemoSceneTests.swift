import Foundation
import Testing
@testable import Antarium

/// The README animation is drawn from an invented roster. It is published on
/// the landing page, so it is held to the same rules as the app: a figure the
/// app could not have produced from the row's own evidence does not appear.
@MainActor
struct DemoSceneTests {
    private let home = "/Users/example"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Every step of the story has rows, and every row lives under the home it was given")
    func rowsStayUnderTheSuppliedHome() {
        for step in DemoScene.steps {
            let rows = DemoScene.rows(step: step, home: home, now: now)
            #expect(!rows.isEmpty)
            for row in rows {
                #expect(row.cwd.hasPrefix(home + "/"), "\(row.cwd) escapes the synthetic home")
            }
        }
    }

    @Test("A cost appears only where the bundled price table can produce one")
    func costsComeFromThePriceTable() {
        for step in DemoScene.steps {
            for row in DemoScene.rows(step: step, home: home, now: now) {
                guard let rate = Pricing.rate(for: row.model) else {
                    #expect(row.costUSD == nil, "\(row.coreName) shows a cost with no price")
                    continue
                }
                let expected = (Double(row.sentTokens ?? 0) * rate.input
                                + Double(row.receivedTokens ?? 0) * rate.output) / 1_000_000
                #expect(row.costUSD == expected)
            }
        }
    }

    @Test("Context never exceeds its window")
    func contextFits() {
        for step in DemoScene.steps {
            for row in DemoScene.rows(step: step, home: home, now: now) {
                if let tokens = row.contextTokens, let window = row.contextWindow {
                    #expect(tokens >= 0 && tokens <= window)
                }
            }
        }
    }

    @Test("The session the banner announces was working and then stopped")
    func announcedSessionActuallyFinishes() {
        let before = DemoScene.rows(step: 0, home: home, now: now)
        let after = DemoScene.rows(step: 1, home: home, now: now)
        let name = DemoScene.announced
        #expect(before.first { $0.coreName == name }?.state.isBusy == true)
        let finished = after.first { $0.coreName == name }.map { row -> Bool in
            if case .waiting = row.state { return true }
            return false
        }
        #expect(finished == true)
    }

    @Test("The menu-bar tally agrees with the rows it summarises")
    func tallyMatchesRows() {
        for step in DemoScene.steps {
            let rows = DemoScene.rows(step: step, home: home, now: now)
            let tally = CountItem.Tally(rows)
            #expect(tally.total == rows.count)
        }
    }

    @Test("Quota readings are fresh and within range")
    func snapshotsAreFresh() {
        let snapshots = DemoScene.snapshots(now: now)
        #expect(!snapshots.isEmpty)
        for snapshot in snapshots {
            #expect(!QuotaStore.isStale(snapshot.fetchedAt, now: now))
            for gauge in snapshot.gauges { #expect((0...1).contains(gauge.used)) }
        }
    }
}
