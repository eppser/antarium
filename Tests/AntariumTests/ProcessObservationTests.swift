import Foundation
import Testing
@testable import Antarium

@Suite("Process observation boundaries")
struct ProcessObservationTests {
    @Test("Failed process enumeration cannot establish an empty process table")
    func unavailableEnumeration() {
        for failedSizing in [true,false] {
            #expect(throws:(any Error).self) {
                _ = try Processes.processIDs { buffer, _ in buffer == nil && !failedSizing ? 3 : 0 }
            }
        }
    }
    @Test("A saturated PID buffer cannot silently omit running processes")
    func saturatedEnumeration() {
        var calls = 0
        #expect(throws:(any Error).self) {
            _ = try Processes.processIDs { buffer, bytes in
                calls += 1
                return buffer == nil ? 10 : bytes / 4
            }
        }
        #expect(calls <= 5)
    }
    @Test("A stable snapshot uses the reported PID count and omits non-process slots")
    func stableEnumeration() throws {
        let pids = try Processes.processIDs { buffer, _ in
            guard let buffer else { return 3 }
            let values = buffer.assumingMemoryBound(to:Int32.self)
            values[0] = 71; values[1] = 0; values[2] = 99
            return 3
        }
        #expect(pids == [71,99])
    }
    @Test("Unmeasured resident memory remains absent, while an observed zero remains zero")
    func memoryPresence() {
        #expect(Processes.residentBytes(nil) == nil)
        #expect(Processes.residentBytes(0) == 0)
        #expect(Processes.residentBytes(1_048_576) == 1_048_576)
    }
    @Test("Failed local discovery preserves unknown rows without completion alerts")
    @MainActor func failedDiscovery() {
        let row = AgentRow(id:"fixture",agentID:"fixture",name:"Synthetic",cwd:"/fixture/project",state:.working,pid:71,rssBytes:100)
        let applied = AgentStore.applyingLocal(nil,previous:[row])
        #expect(applied.rows.first?.id == row.id)
        #expect(applied.rows.first?.state.label == "Unknown")
        #expect(applied.rows.first?.rssBytes == nil)
        #expect(applied.issue != nil)
        #expect(AgentStore.stopped(previous:[row.id:row],current:applied.rows).isEmpty)
        let empty = AgentStore.applyingLocal(.init(rows:[]),previous:[row])
        #expect(empty.rows.isEmpty)
        #expect(empty.issue == nil)
    }
    @Test("A failed per-process query cannot erase that agent while other agents refresh")
    @MainActor func partialDiscovery() {
        let uncertain = AgentRow(id:"uncertain",agentID:"fixture",name:"Synthetic",cwd:"",state:.working,pid:71)
        let fresh = AgentRow(id:"fresh",agentID:"fixture",name:"Synthetic",cwd:"",state:.working,pid:99)
        let applied = AgentStore.applyingLocal(.init(rows:[fresh],unavailablePIDs:[71]),previous:[uncertain,fresh])
        #expect(Set(applied.rows.map(\.id)) == ["uncertain","fresh"])
        #expect(applied.rows.first(where:{$0.id == "uncertain"})?.state.label == "Unknown")
        #expect(applied.rows.first(where:{$0.id == "fresh"})?.state.label == "Working")
        #expect(applied.issue != nil)
    }
    @Test("Remote and failed observations cannot use a PID to focus an unrelated local process")
    func focusBoundary() {
        var row = AgentRow(id:"fixture",agentID:"fixture",name:"Synthetic",cwd:"",state:.working,pid:71)
        #expect(Focus.canRevealLocally(row))
        row.isRemote = true
        #expect(!Focus.canRevealLocally(row))
        row.isRemote = false; row.localObservationIssue = "Synthetic unavailable observation"
        #expect(!Focus.canRevealLocally(row))
    }
}
