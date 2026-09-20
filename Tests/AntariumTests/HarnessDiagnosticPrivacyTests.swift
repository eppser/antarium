import Foundation
import Testing
@testable import Antarium

@Suite("Harness diagnostics privacy", .serialized)
struct HarnessDiagnosticPrivacyTests {
    @Test("Command errors never copy private stderr into published health or logs")
    func stderrIsNotDiagnostic() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let object:[String:Any] = ["formatVersion":1,"id":"privacy-fixture","name":"Fixture","process":[:],
            "source":["kind":"command","path":"","command":"/bin/sh","args":["-c","printf fixture-private-secret >&2; exit 7"]]]
        let descriptor = try HarnessDocument.decode(JSONSerialization.data(withJSONObject:object)).descriptor
        HarnessEngine.resetCaches(includingParsedFiles:true)
        #expect(HarnessEngine.sessions(descriptor).isEmpty)
        let health = try #require(HarnessEngine.health(for:descriptor.id))
        #expect(!health.message.contains("fixture-private-secret"))
        #expect(health.message.contains("7"))
    }
}
