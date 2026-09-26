import Foundation
import Testing
@testable import AntariumHarnessSDK

/// `validate()` is what somebody writing a harness runs before shipping it.
/// If it accepts a configuration the app will reject, they find out from a
/// user rather than from the tool. Five of its six rules had nothing holding
/// them.
@Suite("The SDK refuses configurations the app would reject")
struct SDKValidationTests {

    private func config(id: String = "synthetic", name: String = "Synthetic",
                        source: HarnessConfig.Source = .init(kind: .none, path: ""),
                        process: HarnessConfig.ProcessRule = .init(pathContains: ["/synthetic/"]),
                        map: HarnessConfig.Mapping? = nil) -> HarnessConfig {
        HarnessConfig(id: id, name: name, process: process, source: source, map: map)
    }

    /// The positive control. Every refusal below is worthless if the ordinary
    /// configuration does not pass.
    @Test("A complete configuration validates")
    func validConfigPasses() throws {
        try config().validate()
    }

    @Test("An id that is empty or only spaces is refused", arguments: ["", "   ", "\t\n"])
    func emptyID(_ id: String) {
        #expect(throws: (any Error).self) { try config(id: id).validate() }
    }

    @Test("A name that is empty or only spaces is refused", arguments: ["", "  "])
    func emptyName(_ name: String) {
        #expect(throws: (any Error).self) { try config(name: name).validate() }
    }

    /// A SQLite source without a query has nothing to run, and without
    /// columns nothing to read out of the result. Either alone is a harness
    /// that reports nothing and says nothing about why.
    @Test("A SQLite source needs both a query and its columns")
    func incompleteSQLite() throws {
        var source = HarnessConfig.Source(kind: .sqlite, path: "/tmp/x.sqlite")
        #expect(throws: (any Error).self) { try config(source: source).validate() }

        source.query = "SELECT 1"
        #expect(throws: (any Error).self) { try config(source: source).validate() }

        source.query = nil
        source.columns = ["cwd"]
        #expect(throws: (any Error).self) { try config(source: source).validate() }

        source.query = "SELECT 1"
        try config(source: source).validate()
    }

    @Test("A command source needs a command")
    func missingCommand() throws {
        var source = HarnessConfig.Source(kind: .command, path: "")
        #expect(throws: (any Error).self) { try config(source: source).validate() }
        source.command = ""
        #expect(throws: (any Error).self) { try config(source: source).validate() }
        source.command = "synthetic-tool"
        try config(source: source).validate()
    }

    /// One process, many conversations. Without a way to tell them apart the
    /// harness reports one session for all of them, which is the failure this
    /// rule exists to prevent.
    @Test("A multi-session harness needs a way to identify a session")
    func multiSessionNeedsIdentity() throws {
        var config = self.config(source: .init(kind: .jsonl, path: "/tmp", glob: "*.jsonl"))
        config.multiSession = true
        #expect(throws: (any Error).self) { try config.validate() }

        var identified = config
        var map = HarnessConfig.Mapping()
        map.sessionID = "sessionId"
        identified.map = map
        try identified.validate()
    }

    /// Binding a session to the file a process has open only means anything
    /// when sessions are files.
    @Test("Open-file binding needs a file source")
    func bindingNeedsFileSource() throws {
        var rule = HarnessConfig.ProcessRule(pathContains: ["/synthetic/"])
        rule.sessionBinding = .openSourceFile
        #expect(throws: (any Error).self) {
            try config(source: .init(kind: .sqlite, path: "/tmp/x.sqlite"), process: rule)
                .validate()
        }
        try config(source: .init(kind: .jsonl, path: "/tmp", glob: "*.jsonl"), process: rule)
            .validate()
    }
}
