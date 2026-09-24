import Foundation
import Testing
@testable import Antarium

/// The order a harness's sessions are listed in.
///
/// Read by position, not just by content. `session(_:forCwd:)` answers with
/// `first`; the dashboard uses each session's rank to decide which row
/// carries the process's memory, and as part of a row's identity when it has
/// no session id of its own. So an order that is not total is not a cosmetic
/// problem: the memory figure moves to another row, and a row whose id
/// changes is a row the dashboard has not seen before.
///
/// The key was `lastActivity ?? .distantPast` alone, and a harness whose
/// source carries no activity field gives every session the same one.
@Suite("Sessions come back in one order")
struct SessionOrderTests {

    private func session(id: String? = nil, cwd: String? = nil, title: String? = nil,
                         source: String? = nil, activity: Date? = nil)
        -> HarnessEngine.Session {
        var s = HarnessEngine.Session()
        s.sessionID = id
        s.cwd = cwd
        s.title = title
        s.sourceFile = source
        s.lastActivity = activity
        return s
    }

    /// Shuffled repeatedly, because the failure is an order that depends on
    /// the input's order and one arrangement agreeing with itself proves
    /// nothing.
    ///
    /// Compared on an identity this test builds, never on `orderingKey`.
    /// Doing it the obvious way hid a mutation: narrow the key to
    /// `sessionID ?? ""` and every session in the cwd-only and title-only
    /// cases below collapses to the same empty key — at which point two
    /// differently-ordered lists map to equal arrays of empty strings and the
    /// comparison passes while the order is exactly as unstable as before.
    private func identity(_ s: HarnessEngine.Session) -> String {
        s.sessionID ?? s.cwd ?? s.title ?? s.sourceFile ?? "?"
    }

    private func isStable(_ sessions: [HarnessEngine.Session]) -> Bool {
        let wanted = sessions.sorted(by: HarnessEngine.byRecency).map(identity)
        for _ in 0..<25
        where sessions.shuffled().sorted(by: HarnessEngine.byRecency).map(identity) != wanted {
            return false
        }
        return true
    }

    /// The case that was wrong: a harness that reports no activity at all.
    @Test("Sessions with no recorded activity keep one order")
    func noActivityAtAll() {
        let sessions = (1...6).map { session(id: "s\($0)", cwd: "/synthetic/p\($0)") }
        #expect(isStable(sessions), "sessions with no activity came back reshuffled")
    }

    /// And when they share a timestamp, which two sessions written in the
    /// same pass routinely do.
    @Test("Sessions sharing a timestamp keep one order")
    func sharedTimestamp() {
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = (1...6).map { session(id: "s\($0)", activity: same) }
        #expect(isStable(sessions), "sessions sharing a timestamp came back reshuffled")
    }

    /// Each fallback in turn, since a session may have only one of them.
    @Test("Whatever identity a session has is enough to order it")
    func eachFallback() {
        #expect(isStable((1...5).map { session(cwd: "/synthetic/p\($0)") }))
        #expect(isStable((1...5).map { session(title: "conversation \($0)") }))
        #expect(isStable((1...5).map { session(source: "/synthetic/s\($0).json") }))
    }

    /// The tie-break must not have replaced the ordering: recency still
    /// decides whenever it can, or `first` would stop meaning "most recent".
    @Test("Recency still comes first")
    func recencyStillWins() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_700_009_999)
        // The later session sorts first even though its key sorts last.
        let ordered = [session(id: "aaa", activity: old), session(id: "zzz", activity: new)]
            .sorted(by: HarnessEngine.byRecency)
        #expect(ordered.map(\.sessionID) == ["zzz", "aaa"])
        // And a session with no activity sorts behind one that has some.
        let mixed = [session(id: "aaa"), session(id: "zzz", activity: old)]
            .sorted(by: HarnessEngine.byRecency)
        #expect(mixed.map(\.sessionID) == ["zzz", "aaa"])
    }

    /// The key prefers the strongest identity available, so two sessions in
    /// one directory are still told apart.
    @Test("A session id outranks the directory two sessions share")
    func idOutranksDirectory() {
        let a = session(id: "second", cwd: "/synthetic/shared")
        let b = session(id: "first", cwd: "/synthetic/shared")
        #expect(a.orderingKey == "second" && b.orderingKey == "first")
        #expect([a, b].sorted(by: HarnessEngine.byRecency).map(\.sessionID) == ["first", "second"])
    }

    /// A session with nothing to identify it is the one case that cannot be
    /// ordered, and it should say so rather than appear to work.
    @Test("A session with no identity has an empty key")
    func nothingToOrderBy() {
        #expect(session().orderingKey == "")
    }
}
