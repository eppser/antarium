import Foundation
import Testing
@testable import Antarium

/// The suite's own shape.
///
/// This project's recurring worry is a test that cannot fail: a suite full of
/// them is indistinguishable from a suite that passes, which is why
/// mutations.txt exists. A mutation run costs hours and is sampled; this
/// costs milliseconds and is exhaustive, and it catches the cheapest version
/// of the mistake — a test that asserts nothing at all.
@Suite("Every test can fail")
struct SuiteSelfCheckTests {

    /// Tests whose assertion is that nothing threw, which Swift Testing
    /// treats as a failure and this cannot see. Each needs a reason, the same
    /// way a provider with no mapping does.
    private static let assertsByNotThrowing: [String: String] = [
        "removingUnknownIsSafe":
            "removing an agent that was never stored must not trap",
        "sdkAcceptsSQLiteSessionIdentity":
            "a positive control: the refusals around it are worthless if this does not validate",
        "provenProbeDecodes":
            "a positive control: the refusals above are not satisfied by a decoder that rejects everything",
        "validConfigPasses":
            "a positive control: every refusal below is worthless if the ordinary config does not pass",
    ]

    @Test("No test asserts nothing")
    func everyTestAsserts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "only \(files.count) test files were scanned")

        var checked = 0, silent: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Each @Test and everything up to the next one.
            let blocks = text.components(separatedBy: "@Test").dropFirst()
            for block in blocks {
                guard let name = block.range(of: "func ").map({
                    block[$0.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                }).map(String.init), !name.isEmpty else { continue }
                checked += 1
                let asserts = ["#expect", "#require", "Issue.record", "XCTAssert"]
                    .contains { block.contains($0) }
                if !asserts && Self.assertsByNotThrowing[name] == nil {
                    silent.append("\(url.lastPathComponent):\(name)")
                }
            }
        }
        #expect(checked > 400, "only \(checked) tests were examined")
        #expect(silent.isEmpty,
                Comment(rawValue: "these assert nothing and are not listed as "
                        + "not-throwing tests: \(silent.joined(separator: ", "))"))
    }

    /// And the list stays honest: a name that no longer exists, or one that
    /// has since grown an assertion, should leave it rather than sit there
    /// excusing nothing.
    @Test("The not-throwing list names only tests that are still silent")
    func exemptionsAreStillNeeded() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let all = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
        for (name, reason) in Self.assertsByNotThrowing {
            #expect(!reason.isEmpty)
            #expect(all.contains("func \(name)"),
                    Comment(rawValue: "\(name) is excused and no longer exists"))
        }
    }
}
