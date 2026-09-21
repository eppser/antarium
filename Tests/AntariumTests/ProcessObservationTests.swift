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

/// Bounds on the process table. Two of these guards are early exits that a
/// later check would also catch, so mutating them changes nothing — which
/// makes the outcome worth pinning rather than the line that produces it.
@Suite("Process enumeration stays within its budget")
struct ProcessBudgetTests {

    @Test("A machine reporting more processes than the budget is refused, specifically")
    func oversizedMachine() {
        #expect(throws: Processes.ObservationError.capacityExceeded) {
            // Sizing call reports far beyond the 65,536 ceiling.
            _ = try Processes.processIDs { buffer, _ in buffer == nil ? 1_000_000 : 0 }
        }
    }

    @Test("A machine at the budget is still read")
    func machineAtTheBudget() throws {
        let pids = try Processes.processIDs { buffer, _ in
            guard let buffer else { return 2 }
            let values = buffer.assumingMemoryBound(to: Int32.self)
            values[0] = 11; values[1] = 12
            return 2
        }
        #expect(pids == [11, 12])
    }

    /// `openFilePaths` takes a limit because a process can hold thousands of
    /// descriptors, and the buffer is sized from it. The paths are then
    /// deduplicated, so this needs distinct files: forty handles on one file
    /// collapse to a single path and the limit is never reached — which is
    /// how the first version of this test passed while proving nothing.
    @Test("Open file paths honour the limit they are given")
    func openFilesRespectTheLimit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var held: [FileHandle] = []
        defer { held.forEach { try? $0.close() } }
        for i in 0..<40 {
            let file = dir.appendingPathComponent("file-\(i).txt")
            try Data("x".utf8).write(to: file)
            if let handle = try? FileHandle(forReadingFrom: file) { held.append(handle) }
        }
        #expect(held.count >= 30, "could not open enough files to reach the limit")

        let few = Processes.openFilePaths(of: getpid(), limit: 5)
        #expect(few.count <= 5, "asked for 5 paths and got \(few.count)")
        // And a larger limit returns more, so the bound is a bound rather than
        // a reader that always returns almost nothing.
        let more = Processes.openFilePaths(of: getpid(), limit: 500)
        #expect(more.count > few.count, "the limit made no difference: \(few.count) vs \(more.count)")
    }

    /// The same deduplication, stated directly: many handles on one file are
    /// one path, because the caller wants to know which files are open and
    /// not how many times.
    @Test("Repeated handles on one file are a single path")
    func duplicatePathsCollapse() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID()).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var held: [FileHandle] = []
        defer { held.forEach { try? $0.close() } }
        for _ in 0..<20 {
            if let handle = try? FileHandle(forReadingFrom: file) { held.append(handle) }
        }
        let found = Processes.openFilePaths(of: getpid(), limit: 500)
            .filter { $0.hasSuffix(file.lastPathComponent) }
        #expect(found.count == 1, "one file appeared \(found.count) times")
    }

    @Test("A limit of zero or less returns nothing rather than everything")
    func nonPositiveLimit() {
        #expect(Processes.openFilePaths(of: getpid(), limit: 0).isEmpty)
        #expect(Processes.openFilePaths(of: getpid(), limit: -1).isEmpty)
    }
}
