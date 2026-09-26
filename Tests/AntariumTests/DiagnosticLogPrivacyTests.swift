import Foundation
import Testing
@testable import Antarium

@Suite("Diagnostic logging minimization")
struct DiagnosticLogPrivacyTests {
    @Test("Provider diagnostics never retain account plan labels or usage measurements")
    func providerPrivacy() throws {
        let lines = try Log.capture {
            let codex = try CodexProvider.makeSnapshot(["plan_type":"fixture-private-plan","primary_window":["used_percent":37.375,"limit_window_seconds":18000]])
            #expect(codex.accountLabel?.contains("fixture-private-plan") == true)
            let cursor = try CursorProvider.makeSnapshot(["planUsage":["totalPercentUsed":37.375]],planName:"fixture-private-plan")
            #expect(cursor.accountLabel == "fixture-private-plan")
        }
        #expect(!lines.isEmpty)
        #expect(!lines.joined().contains("fixture-private-plan"))
        #expect(!lines.joined().contains("37.4"))
    }
    @Test("HTTP diagnostics report status without retaining private service hostnames")
    func serviceHostPrivacy() throws {
        let response = try #require(HTTPURLResponse(url:URL(string:"https://example.invalid")!,statusCode:200,httpVersion:nil,headerFields:nil))
        let lines = try Log.capture { try UsageHTTP.check(response,host:"fixture-private-service.internal") }
        #expect(lines.joined().contains("200"))
        #expect(!lines.joined().contains("fixture-private-service"))
    }
    @Test("Duplicate session diagnostics keep the warning without retaining session identifiers")
    func duplicatePrivacy() {
        let row = AgentRow(id:"fixture-private-row",agentID:"fixture-private-harness",name:"Synthetic",cwd:"",state:.unobserved)
        let lines = Log.capture { #expect(AgentScan.uniqued([row,row]).count == 2) }
        #expect(!lines.isEmpty)
        #expect(!lines.joined().contains("fixture-private"))
    }

}
