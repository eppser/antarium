import Foundation
import Testing
@testable import Antarium

/// The harness folder is the only copy of the descriptors, and it is what the
/// app reads. A command-line entry point that reads it without putting it
/// there first reports an empty machine on a new install — which is
/// indistinguishable, to the reader, from an agentless one.
///
/// This runs the built executable, because the defect is where seeding is
/// called from, not what seeding does; a unit test of the seed function passes
/// either way. `ANTARIUM_HOME` keeps it out of the settings of whoever runs it.
@Suite("Diagnostics prepare their own state", .serialized)
struct DiagnosticsSeedingTests {

    private var executable: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()                      // repository root
            .appendingPathComponent(".build/debug/Antarium")
    }

    private func run(_ arguments: [String], home: URL) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ANTARIUM_HOME"] = home.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("A diagnostic on a fresh install seeds the harnesses it is about to read")
    func statusSeedsOnAFreshInstall() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Issue.record("built executable missing at \(executable.path); run swift build first")
            return
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let text = try run(["--status"], home: home)

        let harnesses = home.appendingPathComponent("harnesses")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: harnesses.path)) ?? []
        // Not the seed manifest, which is `.seed.json` and sits beside them.
        // Counting it made this twenty-six where the app loads twenty-five —
        // invisible while the assertion below only asked whether the list was
        // empty.
        let descriptors = files.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        #expect(!descriptors.isEmpty,
                "a fresh install saw no harnesses; --status wrote \(files.count) files")
        // And it reports them, rather than reporting an empty machine.
        //
        // The count, not the word. `harnesses` also appears in the path the
        // line ends with — "harnesses 25 loaded from …/harnesses" — so
        // asserting the word passed whether or not the count was reported at
        // all, which is the whole of what this is checking.
        #expect(text.contains("harnesses \(descriptors.count) loaded"),
                "--status did not report the \(descriptors.count) harnesses it seeded")
        #expect(!text.contains("harnesses 0 loaded"))
    }
}
