import Foundation
import Testing
@testable import Antarium

/// `--check` is what the README tells a harness author to run before
/// restarting. For a quota-only descriptor the quota block is the entire point
/// of the file, and it used to report nothing about it: an endpoint of
/// "not a url" passed with no problems and failed at the first fetch instead,
/// which is the wrong moment and the wrong place to learn it.
@Suite("Harness checking covers the quota block")
struct QuotaCheckTests {

    private func check(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Int32 {
        var quota: [String: Any] = [
            "endpoint": "https://example.invalid/usage",
            "credential": ["kind": "env", "name": "EXAMPLE_TOKEN"],
            "windows": ["root": "usage", "usedPercent": "percent"],
            "setupHint": "Add your API key to example.json.",
        ]
        mutate(&quota)
        let document: [String: Any] = [
            "formatVersion": 1, "id": "example", "name": "Example",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": quota,
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-check-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return HarnessCheck.run(url.path)
    }

    @Test("A well-formed quota block passes")
    func validQuotaPasses() throws {
        #expect(try check() == 0)
    }

    @Test("An endpoint that is not an https URL is a problem, not a runtime surprise")
    func endpointMustBeHTTPS() throws {
        #expect(try check { $0["endpoint"] = "not a url" } != 0)
        #expect(try check { $0["endpoint"] = "http://example.invalid/usage" } != 0)
        #expect(try check { $0["endpoint"] = "https:///nohost" } != 0)
    }

    @Test("A credential missing the field its kind needs is a problem")
    func credentialsNeedTheirCompanions() throws {
        #expect(try check { $0["credential"] = ["kind": "env"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "textFile"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "jsonFile", "path": "~/x.json"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "command"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "telepathy", "name": "X"] } != 0)
        // A quota endpoint that needs no credential at all is legitimate.
        #expect(try check { $0["credential"] = nil } == 0)
    }

    @Test("Windows that name no figure cannot chart anything")
    func windowsMustDeclareAFigure() throws {
        #expect(try check { $0["windows"] = ["root": "usage"] } != 0)
        // `used` without `limit` is a ratio with no denominator.
        #expect(try check { $0["windows"] = ["root": "usage", "used": "n"] } != 0)
        for shape in [["root": "usage", "percentRemaining": "left"],
                      ["root": "usage", "used": "n", "limit": "cap"],
                      ["single": "credits", "balance": "amount"]] {
            #expect(try check { $0["windows"] = shape } == 0, "rejected a valid shape: \(shape)")
        }
    }

    @Test("A badge the menu bar cannot fit is a problem")
    func badgesMustFit() throws {
        #expect(try check {
            $0["windows"] = ["root": "usage", "usedPercent": "p", "badges": ["w": "SESSION"]]
        } != 0)
        #expect(try check {
            $0["windows"] = ["root": "usage", "usedPercent": "p", "badges": ["w": ""]]
        } != 0)
        #expect(try check {
            $0["windows"] = ["root": "usage", "usedPercent": "p", "badges": ["w": "5H"]]
        } == 0)
    }
}
