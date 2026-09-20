import AppKit
import Testing
@testable import Antarium

@Suite("Notification window ownership", .serialized)
struct AlertLifetimeTests {
    @Test("Alert callbacks must not retain their own window after its owner releases it")
    @MainActor func windowLifetime() {
        _ = NSApplication.shared
        let presenter = AgentAlert()
        let row = AgentRow(id: "synthetic-alert", agentID: "fixture", name: "Synthetic", cwd: "/fixture", state: .waiting)
        weak var observed: NSPanel?
        autoreleasepool {
            let panel = presenter.makePanel(row)
            observed = panel
            #expect(observed != nil)
        }
        #expect(observed == nil)
    }
}
