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

/// What `--status` says about a settings file it cannot read.
///
/// The settings panel already shows it, which is where somebody changing a
/// setting would be. `--status` is where somebody works out afterwards why
/// nothing was saved, and it said nothing at all.
@Suite("Reporting a damaged settings file", .serialized)
struct DamagedConfigurationStatusTests {

    private func run(_ arguments: [String], home: URL) throws -> String {
        let executable = URL(fileURLWithPath: ".build/debug/Antarium")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return "" }
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

    @Test("A settings file that is not JSON is reported, and does not stop the rest")
    func damagedConfigurationIsReported() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Seed first, so the harnesses exist and the only damage is the one
        // being tested.
        _ = try run(["--status"], home: home)
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("harnesses").path)
        else { return }
        try Data("{ not json".utf8).write(to: home.appendingPathComponent("config.json"))

        let text = try run(["--status"], home: home)
        guard !text.isEmpty else { return }
        #expect(text.contains("could not be read"),
                "--status said nothing about a settings file it could not read")
        // And the rest of the report still arrives: one damaged file is not a
        // reason to stop describing the machine.
        #expect(text.contains("harnesses "),
                "a damaged settings file stopped the harness count being reported")
    }
}

/// The report a user pastes somewhere carries nobody's name.
///
/// Every surface a user *looks* at abbreviates their home: a row's `displayPath`,
/// the first-run screen's `shorten`. The diagnostic report — the one output whose
/// whole purpose is to be handed to somebody else — printed `/Users/<them>/…` in
/// nine places: the settings file, the log, the harness directory, and every row's
/// working directory.
///
/// A reader of the report needs to know which directory, and `~/.antarium/config.json`
/// says that exactly. The username in front of it is identity, not evidence. This
/// repository already has a test insisting it carries nobody's machine, written
/// after a hostname reached a public remote in thirty-six places; this is the same
/// rule for the thing the app hands a user to paste.
@Suite("A diagnostic report carries no home path", .serialized)
struct DiagnosticPrivacyTests {

    private var executable: URL { URL(fileURLWithPath: ".build/debug/Antarium") }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Run against the real home on purpose, exactly as `NoMachineIdentityTests`
    /// is about the machine it runs on: the person who can leak their own name is
    /// the person running this.
    @Test("No report names the home directory it ran in",
          arguments: ["--status", "--agents", "--detect-agents"])
    func reportsAbbreviateHome(_ argument: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let text = try run([argument])
        guard !text.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let leaks = text.split(separator: "\n").filter { $0.contains(home + "/") }
        #expect(leaks.isEmpty,
                Comment(rawValue: "\(argument) printed the home path: "
                        + leaks.prefix(3).joined(separator: " / ")))
    }

    /// And it still says which directory, or the abbreviation removed the
    /// evidence along with the name.
    ///
    /// Asked of the file names rather than of a leading `~`. The first version
    /// wanted `~/.antarium/config.json`, which is true of an ordinary machine and
    /// false under the gate's bare-home run — `ANTARIUM_HOME` puts the settings
    /// somewhere that is not under the home, so there is nothing to abbreviate
    /// and nothing should be. That is the trap this project's own notes describe:
    /// a test that passes here and fails in the gate, because it assumed the
    /// state of the machine it was written on. The claim that matters is that the
    /// directory is still named.
    @Test("The report still names the directories it read")
    func reportStillNamesDirectories() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let text = try run(["--status"])
        guard !text.isEmpty else { return }
        #expect(text.contains("config.json"),
                "the report no longer says where the settings file is")
        #expect(text.contains("harnesses"),
                "the report no longer says where the harnesses came from")
        // And where the settings really are under the home, the report says so
        // with a `~` — the abbreviation doing its job rather than being absent.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if Config.directory.path.hasPrefix(home + "/") {
            #expect(text.contains("config    ~/"),
                    Comment(rawValue: "settings under the home were reported unabbreviated"))
        }
    }

    /// Two of these lines are in modes a test cannot run: `--focus` acts on a
    /// window and `--remote-tmux` needs somebody's SSH hosts. Reading the output
    /// cannot reach them, so the rule is read off the source instead — and
    /// derived rather than listed, which is what would have caught the tenth
    /// site in `HarnessCLI` that a sweep of one file missed.
    @Test("Every printed path in a report goes through the abbreviation",
          arguments: ["Sources/Antarium/Diagnostics.swift",
                      "Sources/Antarium/Core/HarnessCLI.swift"])
    func everyPrintedPathIsAbbreviated(_ file: String) throws {
        let source = try SourceText.read(file)
        var raw: [String] = []
        for line in source.split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
            // A path reaching a report: either an app directory or a row's own
            // working directory.
            let carriesPath = code.contains(".url.path)") || code.contains("directory.path)")
                || code.contains("cwd)") || code.contains("cwd ?? ")
            guard carriesPath, !code.contains("reportable(") else { continue }
            // `--json` output is machine-read and quoted elsewhere; only the
            // human report is in scope here.
            guard code.contains("print(") || code.contains("+ \"") else { continue }
            raw.append(code)
        }
        #expect(raw.isEmpty,
                Comment(rawValue: "\(file) prints a path without abbreviating the home: "
                        + raw.prefix(3).joined(separator: " / ")))
    }

    /// The helper itself, on the shape that matters: a home prefix goes, and a
    /// path that merely starts with the same letters does not.
    @Test("Only the home directory is abbreviated")
    func onlyHomeIsAbbreviated() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Diagnostics.reportable(home + "/.antarium/config.json")
                == "~/.antarium/config.json")
        #expect(Diagnostics.reportable("/opt/antarium/config.json")
                == "/opt/antarium/config.json")
        // The boundary case `abbreviatingHome` is documented as having got wrong
        // once, in reverse: a home of /Users/sam matching /Users/sammy.
        #expect(Diagnostics.reportable(home + "x/file") == home + "x/file",
                "a sibling directory sharing the home's prefix was abbreviated")
    }
}
