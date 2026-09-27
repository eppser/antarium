import Foundation
import Testing
@testable import Antarium

@Suite("Harness numeric failure provenance", .serialized)
struct HarnessNumericProvenanceTests {
    @Test("Invalid usage values remain an explicit issue rather than becoming zero usage")
    func invalidUsage() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("numeric-harness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        try Data("{\"cwd\":\"/fixture\",\"input\":\"nan\"}\n".utf8).write(to: file)
        let descriptor = try HarnessDocument.decode(Data("""
        {"formatVersion":1,"id":"numeric-fixture","name":"Fixture","process":{},
         "source":{"kind":"jsonl","path":"\(root.path)","glob":"*.jsonl"},
         "map":{"cwd":"cwd","inputTokens":"input"}}
        """.utf8)).descriptor
        HarnessEngine.resetCaches()
        let session = try #require(HarnessEngine.sessions(descriptor).first)
        #expect(session.usageIssue != nil)
        var row = AgentRow(id: "fixture", agentID: "fixture", name: "Fixture", cwd: "/fixture", state: .waiting)
        AgentScan.apply(session, to: &row, descriptor, processAlive: true)
        #expect(row.sentTokens == nil)
        #expect(row.costUSD == nil)
        #expect(row.note?.contains("unavailable") == true)
    }
    @Test("Combined usage counters cannot overflow into a crash or a fabricated total")
    func combinedOverflow() {
        var session = HarnessEngine.Session()
        session.inputTokens = Int.max
        session.cacheWrite = 1
        #expect(session.sentTokens == nil)
        #expect(session.usageIssue != nil)
    }
}

/// Which reason a user is given for a missing figure.
///
/// A row whose usage could not be read has its figures nilled rather than zeroed,
/// which is the right choice and a silent one — the reason is the only thing
/// between that and a row that looks like nobody looked. Six sentences can be
/// that reason, reaching a user through the row's note, its tooltip and the
/// spoken summary.
///
/// Every test of this asked whether `usageIssue` was nil or not nil. None asked
/// which, so the order that decides it, and the sentences themselves, were free
/// to drift: two reasons collapsing onto one wording sends a user to the wrong
/// file, and a transient backlog described in a permanent reason's words sends
/// them looking for a fault that is not there.
@Suite("A missing figure says which reason it is missing for")
struct UsageIssueChoiceTests {

    /// Every sentence this can produce, from the places that set them. Named
    /// rather than derived: they are strings a user reads, and deriving them from
    /// the source would compare it with itself.
    static let sentences = [
        "Transcript contains too many model variants. Usage figures are unavailable.",
        "Transcript usage values are invalid or out of range. Usage figures are unavailable.",
        "Some transcript records exceeded the read limit. Usage figures are unavailable.",
        "Some transcript records were invalid. Usage figures are unavailable.",
        "Transcript tool count is out of range. Usage figures are unavailable.",
        TranscriptStats.backlogIssue,
    ]

    @Test("The most specific reason wins")
    func precedence() {
        let numeric = "numeric reason", read = "read reason"
        #expect(TranscriptStats.issue(numeric: numeric, read: read, backlogged: true) == numeric,
                "a read problem or a backlog was shown where a numeric one was known")
        #expect(TranscriptStats.issue(numeric: nil, read: read, backlogged: true) == read,
                "a backlog was shown where a read problem was known")
        #expect(TranscriptStats.issue(numeric: nil, read: nil, backlogged: true)
                == TranscriptStats.backlogIssue)
    }

    @Test("Nothing wrong says nothing")
    func silenceWhenFine() {
        #expect(TranscriptStats.issue(numeric: nil, read: nil, backlogged: false) == nil,
                "a row with nothing wrong was given a reason anyway")
    }

    /// A backlog is not a fault, and the sentence for it is the only one that
    /// says the figures come back on their own.
    @Test("Only the transient reason says it will resolve itself")
    func transientIsMarked() {
        for sentence in Self.sentences {
            let transient = sentence == TranscriptStats.backlogIssue
            #expect(sentence.contains("catches up") == transient,
                    Comment(rawValue: "\"\(sentence)\" \(transient ? "no longer says" : "says") "
                            + "the figures come back on their own"))
        }
    }

    /// Distinct, or two different problems read as one and the user opens the
    /// wrong file.
    @Test("No two reasons share a wording")
    func reasonsAreDistinct() {
        #expect(Set(Self.sentences).count == Self.sentences.count,
                Comment(rawValue: "two reasons share a wording: \(Self.sentences)"))
    }

    /// Each says the figures are unavailable, so a reason can never read as an
    /// explanation of a figure that is being shown.
    @Test("Every reason says the figures are unavailable")
    func everyReasonSaysUnavailable() {
        for sentence in Self.sentences {
            #expect(sentence.contains("unavailable"),
                    Comment(rawValue: "\"\(sentence)\" does not say the figures are unavailable"))
        }
    }

    /// And the sentences above are the ones the code sets, or this suite is
    /// asserting about wording nobody produces.
    @Test("The reasons tested are the reasons written")
    func sentencesAreTheRealOnes() throws {
        let source = try SourceText.read("Sources/Antarium/Core/TranscriptStats.swift")
        for sentence in Self.sentences where sentence != TranscriptStats.backlogIssue {
            #expect(source.contains(sentence),
                    Comment(rawValue: "nothing sets \"\(sentence)\" any more"))
        }
        #expect(source.contains("Self.issue(numeric: numericIssue, read: readIssue,"),
                "usageIssue no longer asks the function these test")
    }
}
