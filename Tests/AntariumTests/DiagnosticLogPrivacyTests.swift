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

    /// And the rule behind those three, read off every call site rather than
    /// exercised at one.
    ///
    /// The cases above catch a plan label, a hostname and a session id, each at
    /// the place it was once leaked. The log file is the other artefact a user
    /// attaches to a bug report, and what it must not carry is the same thing the
    /// diagnostic report must not: the path to their home, which is their account
    /// name. Every `Log` call in the app interpolates counts, booleans and status
    /// codes — that discipline is real and nothing held it, so a call added later
    /// could put a path in the file with every existing test still passing.
    ///
    /// Derived rather than listed, which is what caught the tenth unabbreviated
    /// path in the report after a sweep of one file missed it.
    @Test("No log message carries a filesystem path")
    func logsCarryNoPaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var examined = 0, offenders: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.contains("Log.info(") || code.contains("Log.warn(")
                        || code.contains("Log.error(") || code.contains("Log.debug(") else { continue }
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                examined += 1
                // Only what is interpolated into the message, which is the part
                // that reaches the file.
                for fragment in code.components(separatedBy: "\\(").dropFirst() {
                    let expression = fragment.components(separatedBy: ")").first ?? fragment
                    // Plain substrings: a regular expression here needs escapes
                    // the Swift literal fights over, and ".path" as text is
                    // exactly what is being looked for.
                    let pathish = [".path", "cwd", ".url", "directory", "homeDirectory"]
                    if pathish.contains(where: { expression.contains($0) }) {
                        offenders.append("\(url.lastPathComponent): \(code.prefix(90))")
                    }
                }
            }
        }
        #expect(examined >= 20,
                Comment(rawValue: "only \(examined) log calls were examined, so this proved little"))
        #expect(offenders.isEmpty,
                Comment(rawValue: "a log message carries a path, which is the user's account name "
                        + "in a file they attach to bug reports: "
                        + offenders.prefix(3).joined(separator: " / ")))
    }
}
