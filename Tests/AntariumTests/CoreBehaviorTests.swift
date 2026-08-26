import AppKit
import Foundation
import Testing
@testable import Antarium

private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "") {
    #expect(value(), Comment(rawValue: message))
}

private func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "") {
    #expect(!value(), Comment(rawValue: message))
}

private func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T,
                                           _ rhs: @autoclosure () -> T,
                                           _ message: String = "") {
    #expect(lhs() == rhs(), Comment(rawValue: message))
}

private func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () -> T,
                                              _ rhs: @autoclosure () -> T,
                                              _ message: String = "") {
    #expect(lhs() != rhs(), Comment(rawValue: message))
}

private func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "") {
    #expect(value() == nil, Comment(rawValue: message))
}

private func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "") {
    #expect(value() != nil, Comment(rawValue: message))
}

@Suite("Core behavior")
struct CoreBehaviorTests {
    private func row(_ id: String, _ state: AgentRow.State) -> AgentRow {
        AgentRow(id: id, agentID: "test", name: id, cwd: "/tmp", state: state)
    }

    @MainActor @Test func stoppedTransitionsOnlyReportWorkThatActuallyStopped() {
        let working = ["a": row("a", .working)]
        XCTAssertEqual(AgentStore.stopped(previous: working,
                                          current: [row("a", .waiting)]).map(\.id), ["a"])
        XCTAssertEqual(AgentStore.stopped(previous: working, current: []).map(\.id), ["a"])
        XCTAssertTrue(AgentStore.stopped(previous: working,
                                         current: [row("a", .working)]).isEmpty)
        XCTAssertTrue(AgentStore.stopped(previous: ["a": row("a", .waiting)],
                                         current: [row("a", .waiting)]).isEmpty)
        XCTAssertTrue(AgentStore.stopped(previous: [:],
                                         current: [row("a", .waiting)]).isEmpty)
        XCTAssertTrue(AgentStore.stopped(previous: ["a": row("a", .working)],
                                         current: [row("a", .looping)]).isEmpty)
        XCTAssertEqual(AgentStore.stopped(previous: ["a": row("a", .looping)],
                                          current: [row("a", .waiting)]).count, 1)

        // Two processes may share one project directory. A completion belongs
        // to its stable session identity and must not stop the sibling row.
        let simultaneous = ["session-a": row("session-a", .working),
                            "session-b": row("session-b", .working)]
        XCTAssertEqual(AgentStore.stopped(
            previous: simultaneous,
            current: [row("session-a", .waiting), row("session-b", .working)])
            .map(\.id), ["session-a"])
    }

    @Test func stateMachineUsesEvidenceBeforeInference() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = now.addingTimeInterval(-5)
        let old = now.addingTimeInterval(-4_000)

        XCTAssertEqual(AgentStateMachine.state(.init(processAlive: false,
                                                     lastActivity: recent), now: now).label, "Ended")
        XCTAssertEqual(AgentStateMachine.state(.init(processAlive: false,
                                                     remote: "cloud"), now: now).label, "Cloud")
        XCTAssertEqual(AgentStateMachine.state(.init(published: .working,
                                                     lastActivity: old), now: now).label, "Working")
        XCTAssertEqual(AgentStateMachine.state(.init(published: .waiting,
                                                     lastActivity: recent), now: now).label, "Waiting")
        XCTAssertEqual(AgentStateMachine.state(.init(), now: now).label, "Waiting")
        XCTAssertEqual(AgentStateMachine.state(.init(lastActivity: recent), now: now).label, "Working")
        XCTAssertEqual(AgentStateMachine.state(.init(lastActivity: old), now: now).label, "Waiting")
        XCTAssertEqual(AgentStateMachine.state(.init(published: .waiting,
                                                     looping: true), now: now).label, "Looping")
        XCTAssertEqual(AgentStateMachine.state(.init(published: .working,
                                                     looping: true), now: now).label, "Working")
    }

    @Test func sortingAndDuplicateIDsRemainDeterministic() {
        let clashing = [row("same", .working), row("same", .waiting), row("other", .waiting)]
        let unique = AgentScan.uniqued(clashing)
        XCTAssertEqual(Set(unique.map(\.id)).count, 3)
        XCTAssertEqual(unique.count, 3)

        func active(_ id: String, _ state: AgentRow.State, _ date: Date?) -> AgentRow {
            var value = row(id, state)
            value.lastActivity = date
            return value
        }
        let sorted = AgentScan.sorted([
            active("idle-recent", .waiting, Date(timeIntervalSince1970: 2_000_000)),
            active("busy-no-time", .working, nil),
            active("busy-old", .working, Date(timeIntervalSince1970: 1_000)),
        ], by: .activity)
        XCTAssertTrue(sorted.prefix(2).allSatisfy { $0.id.hasPrefix("busy") })
        XCTAssertEqual(sorted.last?.id, "idle-recent")
    }

    @Test func loopDeclarationsAreNotTimingGuesses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(LoopWatch.isLooping(wakeAt: now.addingTimeInterval(600),
                                          stopped: false, now: now))
        XCTAssertTrue(LoopWatch.isLooping(wakeAt: now.addingTimeInterval(-120),
                                          stopped: false, now: now))
        XCTAssertFalse(LoopWatch.isLooping(wakeAt: now.addingTimeInterval(-250_000),
                                           stopped: false, now: now))
        XCTAssertFalse(LoopWatch.isLooping(wakeAt: now.addingTimeInterval(600),
                                           stopped: true, now: now))
        XCTAssertFalse(LoopWatch.isLooping(wakeAt: nil, stopped: false, now: now))
        XCTAssertTrue(LoopWatch.isLooping(declared: "goal running", wakeAt: nil, stopped: false))
    }

    @Test func tokenSemanticsNeverPresentCacheReadsAsUploadedBytes() {
        var codex = HarnessEngine.Session()
        codex.inputTokens = 145_758
        codex.cacheRead = 145_402
        codex.cacheWrite = 353
        codex.inputIncludesCacheRead = true
        XCTAssertEqual(codex.sentTokens, 709)

        codex.inputIncludesCacheRead = false
        XCTAssertEqual(codex.sentTokens, 146_111)

        var context = HarnessEngine.Session()
        context.inputTokens = 5_000
        XCTAssertEqual(context.contextTokens, 0, "Lifetime traffic is not context occupancy")
        context.measuredContext = 4_200
        XCTAssertEqual(context.contextTokens, 4_200)
    }

    @Test func fieldPathsResolveArraysNumbersAndDates() {
        let record: [String: Any] = [
            "requests": [
                ["model": "old", "tokens": 3],
                ["model": "new", "tokens": "7", "at": "2026-08-25T10:20:30Z"],
            ],
        ]
        XCTAssertEqual(FieldPath.string(record, "requests[].model"), "new")
        XCTAssertEqual(FieldPath.int(record, "requests[].tokens"), 10)
        XCTAssertEqual(FieldPath.int(record, "requests[-1].tokens"), 7)
        XCTAssertNotNil(FieldPath.date(record, "requests[].at"))
        XCTAssertNil(FieldPath.number(record, "requests[].missing"))
    }

    @Test func journalFoldingReconstructsTheDocumentWithoutDoubleCounting() {
        let folded = Journal.fold([
            ["kind": 0, "v": ["customTitle": "", "requests": [] as [Any]]],
            ["kind": 1, "k": ["customTitle"], "v": "Chronicle command usage"],
            ["kind": 2, "k": ["requests"], "v": [["requestId": "a"]] as [Any]],
            ["kind": 1, "k": ["requests", 0, "promptTokens"], "v": 26_268],
            ["kind": 2, "k": ["requests"], "v": [["requestId": "b"]] as [Any]],
        ])
        XCTAssertEqual(folded["customTitle"] as? String, "Chronicle command usage")
        let requests = folded["requests"] as? [[String: Any]]
        XCTAssertEqual(requests?.count, 2)
        XCTAssertEqual(requests?.first?["promptTokens"] as? Int, 26_268)
        XCTAssertEqual(requests?.first?["requestId"] as? String, "a")
    }

    @Test func sessionNamesDisambiguateOnlyWhenNecessary() {
        XCTAssertEqual(AgentScan.sessionName(folder: "0day", sessionID: "ses_abcQvM0",
                                             sharing: 1, fallback: "opencode"), "0day")
        XCTAssertEqual(AgentScan.sessionName(folder: "Default Project", sessionID: "ses_aayxT5",
                                             sharing: 2, fallback: "opencode"),
                       "Default Project-yxT5")
        XCTAssertNotEqual(AgentScan.sessionName(folder: "p", sessionID: "ses_1yxT5",
                                                sharing: 2, fallback: "x"),
                          AgentScan.sessionName(folder: "p", sessionID: "ses_1BcHQ",
                                                sharing: 2, fallback: "x"))
        XCTAssertEqual(AgentScan.sessionName(folder: "", sessionID: "a",
                                             sharing: 1, fallback: "opencode"), "opencode")
    }

    @Test func shellQuotingCannotBeBrokenByLabelsOrCommands() throws {
        let script = SignIn.script("printf '%s' \"$HOME\"", label: "Bob's Agent")
        XCTAssertTrue(script.contains(#"exec "$SHELL" -lc 'printf '\''%s'\'' "$HOME"'"#))
        XCTAssertTrue(script.contains(#"Bob'\''s Agent"#))
    }

    @Test func formattingIsStableAndUngrouped() {
        XCTAssertEqual(Fmt.count(10_259), "10.3k")
        XCTAssertEqual(Fmt.count(42), "42")
    }

    @Test func diagnosticTableRowsPadColumnsAndPreserveOverflow() {
        XCTAssertEqual(Diagnostics.tableRow(["A", "BB", "tail"], widths: [3, 2]),
                       "A   BB tail")
        XCTAssertEqual(Diagnostics.tableRow(["long", "B"], widths: [3, 2]),
                       "long B ")
        XCTAssertEqual(Diagnostics.tableRow([], widths: [3, 2]), "")
    }

    @Test func credentialFailuresAloneSuggestSigningIn() {
        XCTAssertTrue(ProviderError.needsAuth("x").suggestsSignIn)
        XCTAssertTrue(ProviderError.notConfigured("x").suggestsSignIn)
        XCTAssertFalse(ProviderError.transport("x").suggestsSignIn)
        XCTAssertFalse(ProviderError.badResponse("x").suggestsSignIn)
        XCTAssertFalse(ProviderError.accessDenied("x").suggestsSignIn)
    }

    @Test func blinkTimingIsClockDrivenAndDeterministic() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(Blink.isDim(at: start))
        XCTAssertTrue(Blink.isDim(at: start.addingTimeInterval(Blink.beat)))
        XCTAssertFalse(Blink.isDim(at: start.addingTimeInterval(Blink.beat * 2)))
    }

    @Test func fileAndDirectoryStampsSeeInPlaceEdits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("a.json")
        try Data(#"{"v":1}"#.utf8).write(to: file)
        let fileBefore = FileStamp.of(file)
        let directoryBefore = FileStamp.ofDirectory(root)
        try Data(#"{"v":2}"#.utf8).write(to: file)
        XCTAssertNotEqual(FileStamp.of(file), fileBefore)
        XCTAssertNotEqual(FileStamp.ofDirectory(root), directoryBefore)
        XCTAssertEqual(FileStamp.of(root.appendingPathComponent("absent.json")), "")
    }

    @Test func openCodeTabStateDistinguishesNoStateFromNoOpenTabs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(OpenCodeTabs.open(in: root))
        let state = #"{"tabs":[{"type":"session","sessionId":"one"},{"type":"settings"}]}"#
        try Data(state.utf8).write(to: root.appendingPathComponent("opencode.window.a.dat"))
        XCTAssertEqual(OpenCodeTabs.open(in: root), ["one"])
    }
}
