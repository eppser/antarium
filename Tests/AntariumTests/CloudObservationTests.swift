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
