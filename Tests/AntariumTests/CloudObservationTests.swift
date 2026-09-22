import Foundation
import Testing
@testable import Antarium

@Suite("Cloud observation boundaries")
struct CloudObservationTests {
    @Test("Missing credentials cannot establish that a cloud account has no tasks")
    func missingAuthentication() async {
        do {
            _ = try await CloudScan.codexTasks(auth:nil)
            Issue.record("Missing authentication was accepted as an empty inventory")
        } catch {}
    }
    @Test("Malformed, duplicated and paginated inventories cannot masquerade as complete")
    func incompleteInventories() {
        for payload: [String:Any] in [
            ["items":[["title":"Synthetic task without identity"]]],
            ["items":[["id":"duplicate"],["id":"duplicate"]]],
            ["items":[],"cursor":"synthetic-next-page"],
            ["items":[],"has_more":true]
        ] {
            #expect(throws: (any Error).self) { _ = try CloudScan.rows(from:payload) }
        }
    }
    @Test("Explicit zero is a valid empty inventory but an invalid timestamp is not a date")
    func typedDates() throws {
        #expect(try CloudScan.rows(from:["items":[],"cursor":NSNull()]).isEmpty)
        for value:Any in [true,Double.infinity,Double.nan,"not-a-date"] {
            #expect(throws: (any Error).self) {
                _ = try CloudScan.rows(from:["items":[["id":"synthetic","updated_at":value]]])
            }
        }
        let rows = try CloudScan.rows(from:["items":[["id":"synthetic","created_at":0,"updated_at":NSNull()]]])
        #expect(rows.first?.startedAt == Date(timeIntervalSince1970:0))
    }
    @Test("A raw prompt is not used as an account-facing task title")
    func noPromptFallback() throws {
        let rows = try CloudScan.rows(from:["items":[["id":"synthetic","prompt":"Synthetic private instruction"]]])
        #expect(rows.first?.name == "Cloud task")
    }
    @Test("A failed cloud refresh retains identity and evidence but cannot claim current work")
    @MainActor func staleRows() {
        var row = AgentRow(id:"synthetic",agentID:"fixture",name:"Synthetic",cwd:"",state:.working)
        row.isRemote = true; row.lastActivity = Date(timeIntervalSince1970:100); row.receivedTokens = 0
        let stale = CloudScan.unavailableRows([row],issue:"Synthetic unavailable observation")
        #expect(stale.first?.id == row.id)
        #expect(stale.first?.state.label == "Unknown")
        #expect(stale.first?.receivedTokens == 0)
        #expect(stale.first?.lastActivity == row.lastActivity)
        #expect(stale.first?.note == "Synthetic unavailable observation")
        #expect(AgentStore.stopped(previous:[row.id:row],current:stale).isEmpty)
    }
    @Test("Cloud diagnostics never expose arbitrary error descriptions")
    func safeIssue() {
        for error: Error in [ProviderError.transport("synthetic-secret"),ProviderError.needsAuth("synthetic-secret"),
                             NSError(domain:"synthetic",code:1,userInfo:[NSLocalizedDescriptionKey:"synthetic-secret"])] {
            #expect(!CloudScan.issue(for:error).contains("synthetic-secret"))
        }
    }
}

/// Vendor text that reaches the screen.
///
/// Every string in a cloud task's record is drawn in the dashboard: the
/// status becomes the state pill's label inside a 68pt frame, and the title
/// becomes the row name — which in full mode carries
/// `.fixedSize(horizontal: true)` and therefore cannot truncate, whatever
/// the `.lineLimit(1)` above it says. So a long title asked for a row wider
/// than the panel that contains it.
///
/// The identifier in the same record was already bounded, at 256 bytes with
/// its control characters refused. The strings that are actually rendered
/// were not bounded at all.
@Suite("Cloud task text is bounded before it is drawn")
struct CloudTextBoundsTests {

    private func row(_ overrides: [String: Any]) throws -> AgentRow {
        var item: [String: Any] = ["id": "synthetic-task"]
        item.merge(overrides) { _, new in new }
        let rows = try CloudScan.rows(from: ["items": [item], "cursor": NSNull()])
        return try #require(rows.first, "the synthetic task did not parse")
    }

    /// Named individually rather than looped over a dictionary, so a field
    /// that stops being clamped fails here instead of quietly leaving the set.
    @Test("Every drawn field is clamped, whatever the service sends")
    func everyDrawnFieldIsClamped() throws {
        let long = String(repeating: "wide", count: 2_000)   // 8,000 characters
        let parsed = try row(["title": long, "status": long,
                              "model": long, "repo": long])

        // Against a literal, not against `CloudScan.maxText`. Asserting a
        // value is within its own constant is satisfied by widening the
        // constant — mutating it to 100,000 left this suite green, which is
        // the same mistake AGENTS.md records under assertions that check the
        // author's allowlist instead of the code. 64 is a width a menu row
        // can actually draw.
        #expect(parsed.name.count <= 64,
                Comment(rawValue: "the row name is \(parsed.name.count) characters"))
        #expect(parsed.state.label.count <= 64,
                Comment(rawValue: "the pill label is \(parsed.state.label.count) characters"))
        #expect((parsed.model ?? "").count <= 64)
        #expect((parsed.sessionName ?? "").count <= 64)
    }

    /// And the clamp keeps what it read, or "bounded" could be satisfied by
    /// dropping the field. A status of "running" must still say running.
    @Test("A short value passes through unchanged")
    func shortValuesSurvive() throws {
        let parsed = try row(["title": "Fix the parser", "status": "running",
                              "model": "gpt-5", "repo": "acme/widgets"])
        #expect(parsed.name == "Fix the parser")
        #expect(parsed.state.label == "Running", "the pill lost the status it was given")
        #expect(parsed.model == "gpt-5")
        #expect(parsed.sessionName == "acme/widgets")
    }

    /// Truncation is by character, not by byte: cutting a multi-byte scalar
    /// in half would put a replacement glyph in the menu bar.
    @Test("An emoji title is cut between characters, not through one")
    func truncationIsGraphemeSafe() throws {
        let parsed = try row(["title": String(repeating: "👩‍💻", count: 200)])
        #expect(parsed.name.count <= 64)
        #expect(!parsed.name.unicodeScalars.contains("\u{FFFD}"),
                "a character was cut in half")
        #expect(parsed.name.hasPrefix("👩‍💻"))
    }

    /// And the constant itself stays a display width. The assertions above
    /// are literals so that widening it cannot satisfy them; this is the one
    /// place that pins the constant, so widening it fails exactly once and
    /// says why.
    @Test("The bound is a width a menu row can draw")
    func theBoundIsADisplayWidth() {
        #expect(CloudScan.maxText == 64,
                "the providers all bound their response text to 64 characters")
    }

    /// The identifier is matched against, never drawn, and truncating it
    /// would merge two tasks whose ids share a prefix. It keeps its own,
    /// larger bound.
    @Test("The identifier is not clamped to the display length")
    func identifierKeepsItsOwnBound() throws {
        let id = String(repeating: "a", count: 200)
        let parsed = try row(["id": id])
        #expect(parsed.id == "codex-cloud-" + id,
                "the id was shortened and two tasks could now collide")
        // And its own bound still refuses an unreasonable one.
        #expect(throws: (any Error).self) {
            _ = try CloudScan.rows(from: ["items": [["id": String(repeating: "a", count: 300)]],
                                          "cursor": NSNull()])
        }
    }
}
