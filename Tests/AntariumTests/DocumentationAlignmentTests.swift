import Foundation
import Testing
@testable import Antarium

/// AGENTS.md requires a descriptor change to land across the SDK, schema,
/// decoder, migration, documentation, fixtures and tests together. Every part
/// of that is enforced by something except the documentation, which is the
/// part a reader relies on and the easiest to forget. This closes it.
@Suite("Documentation tracks the schema")
struct DocumentationAlignmentTests {

    /// The repository, found from this file rather than the working directory,
    /// which differs between `swift test` and the script runner.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)            // Tests/AntariumTests/<this>
            .deletingLastPathComponent()           // Tests/AntariumTests
            .deletingLastPathComponent()           // Tests
            .deletingLastPathComponent()           // repository root
    }

    private func schemaFields(_ definition: String) throws -> [String] {
        let url = repositoryRoot.appendingPathComponent("Resources/harness.schema.json")
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try #require(object["$defs"] as? [String: Any])
        let block = try #require(defs[definition] as? [String: Any])
        let properties = try #require(block["properties"] as? [String: Any])
        return properties.keys.sorted()
    }

    @Test("Every quota window field the schema accepts is explained in the docs")
    func quotaWindowFieldsAreDocumented() throws {
        let documentation = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/TECHNICAL.md"),
            encoding: .utf8)
        let undocumented = try schemaFields("windows").filter {
            !documentation.contains("`\($0)`")
        }
        let missing = undocumented.joined(separator: ", ")
        #expect(undocumented.isEmpty,
                "quota.windows fields with no explanation in docs/TECHNICAL.md: \(missing)")
    }

    @Test("The validator, the schema and the SDK accept the same window fields")
    func schemaAndValidatorAgree() throws {
        // A field the schema allows but the validator rejects is reported to
        // the user as a typo in their own file; the reverse is silently
        // ignored. Both are worse than a build failure here.
        let schema = Set(try schemaFields("windows"))
        let validator = Set(HarnessCheck.knownFields(at: "quota.windows") ?? [])
        let schemaOnly = schema.subtracting(validator).sorted()
        let validatorOnly = validator.subtracting(schema).sorted()
        #expect(schema == validator,
                "schema only: \(schemaOnly); validator only: \(validatorOnly)")
    }

    @Test("Every quota credential kind the schema names is one the provider reads")
    func credentialKindsAgree() throws {
        let url = repositoryRoot.appendingPathComponent("Resources/harness.schema.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let defs = try #require(object?["$defs"] as? [String: Any])
        let credential = try #require(defs["credential"] as? [String: Any])
        let properties = try #require(credential["properties"] as? [String: Any])
        let kind = try #require(properties["kind"] as? [String: Any])
        let kinds = Set(try #require(kind["enum"] as? [String]))
        #expect(kinds == ["env", "textFile", "jsonFile", "command"])
    }
}

/// The validator's idea of what a descriptor may contain, against the
/// schema's.
///
/// `--check` reports any key it does not know as "not a field; it will be
/// ignored". When a field is added to the runtime and the schema but not to
/// that list, the tool tells the one person writing such a descriptor that
/// their working field does nothing — which is worse than silence, and is
/// what happened to `quota.command`, `args`, `method` and `body`.
@Suite("The validator and the schema describe the same descriptor")
struct ValidatorSchemaAlignmentTests {

    /// Each validator key path against the schema definition that describes
    /// the same object. Paths the schema models inline, or not at all, are
    /// left out rather than asserted loosely.
    private static let pairs: [(path: String, definition: String)] = [
        ("quota", "quota"),
        ("quota.windows", "windows"),
        ("quota.credential", "credential"),
        ("source", "source"),
        ("map", "map"),
        ("process", "process"),
        ("selection", "selection"),
        ("focus", "focus"),
        ("presentation", "presentation"),
        ("compatibility", "compatibility"),
    ]

    /// A parameterised test over an empty list passes. Both tests below take
    /// their arguments from `pairs`, so emptying it would turn the whole
    /// alignment check into two green ticks — which is the failure this
    /// suite exists to prevent, one level out.
    @Test("Every object with a key list is compared")
    func everyObjectIsCompared() {
        #expect(Self.pairs.count >= 10,
                "only \(Self.pairs.count) objects are compared")
        #expect(Set(Self.pairs.map(\.path)).count == Self.pairs.count,
                "an object is listed twice, so one of them is not being checked")
    }

    private func schemaProperties(_ definition: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/harness.schema.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try #require(json["$defs"] as? [String: Any])
        let object = try #require(defs[definition] as? [String: Any],
                                  "the schema has no definition named \(definition)")
        let properties = try #require(object["properties"] as? [String: Any])
        return Set(properties.keys)
    }

    @Test("Every schema field is one the validator knows",
          arguments: ValidatorSchemaAlignmentTests.pairs)
    func schemaFieldsAreKnown(_ pair: (path: String, definition: String)) throws {
        let known = try #require(HarnessCheck.known[pair.path],
                                 "the validator has no key list for \(pair.path)")
        let missing = try schemaProperties(pair.definition).subtracting(known)
        #expect(missing.isEmpty, Comment(rawValue:
            "\(pair.path) accepts \(missing.sorted()) in the schema, and --check would "
            + "call each of them \"not a field; it will be ignored\""))
    }

    /// And the other direction, so the validator cannot quietly accept a key
    /// nothing else describes.
    @Test("Every field the validator knows is in the schema",
          arguments: ValidatorSchemaAlignmentTests.pairs)
    func knownFieldsAreInTheSchema(_ pair: (path: String, definition: String)) throws {
        let known = try #require(HarnessCheck.known[pair.path])
        let extra = known.subtracting(try schemaProperties(pair.definition))
        #expect(extra.isEmpty, Comment(rawValue:
            "\(pair.path) accepts \(extra.sorted()) and the schema does not describe them"))
    }
}

/// Two documented claims that changed under the documentation.
///
/// The quota section said a descriptor "makes one authenticated GET" and that
/// an endpoint "must be https with a host". Both were true when written and
/// neither survived this month — a POST is describable now, and http to this
/// machine is accepted. The new paragraphs were appended a hundred lines
/// further down, so the file said both things at once.
@Suite("The quota documentation says what the code does")
struct QuotaDocumentationTests {

    private func technical() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"),
                          encoding: .utf8)
    }

    /// Stated as an absence, because the failure was a stale sentence left
    /// standing beside a new one rather than a missing explanation.
    @Test("Nothing claims a quota endpoint must be https")
    func noHttpsOnlyClaim() throws {
        let text = try technical()
        #expect(!text.contains("must be `https` with a host"),
                "the scheme rule changed and this sentence did not")
        #expect(text.contains("https, or http to this machine"),
                "the scheme rule is not stated anywhere")
    }

    @Test("Nothing claims a quota is always a GET")
    func noGetOnlyClaim() throws {
        let text = try technical()
        #expect(!text.contains("makes one authenticated GET"),
                "a POST is describable and this sentence says otherwise")
        #expect(text.contains(#"`method: "POST"`"#),
                "the posted form is not documented")
    }

    /// And the command form, which is the third transport and the newest.
    @Test("The command form is documented")
    func commandFormDocumented() throws {
        #expect(try technical().contains("`quota.command`")
                || (try technical()).contains("an `endpoint`, or a `command`"))
    }

    /// The walkthrough exists and names the two commands that make a mapping
    /// checkable with nothing installed, which is the whole point of it.
    ///
    /// Scoped to the section rather than the file. Both commands appear
    /// elsewhere in this document, so a whole-file `contains` passed with the
    /// step deleted — the same mistake as matching a path as a substring, and
    /// the mutation that removed the step survived it.
    @Test("Adding a provider is written down, with the commands that verify it")
    func walkthroughExists() throws {
        let text = try technical()
        let start = try #require(text.range(of: "### Adding a quota provider"),
                                 "the walkthrough is gone")
        let after = text[start.upperBound...]
        let end = after.range(of: "\n### ")?.lowerBound ?? after.endIndex
        let section = String(after[..<end])

        #expect(section.contains("--check"),
                "the walkthrough does not say how to check the descriptor")
        #expect(section.contains("--verify-harness-quota"),
                "the walkthrough does not say how to check the mapping")
        #expect(section.contains("mutations.txt"),
                "the walkthrough stops at a fixture, which only proves today")
        #expect(section.contains("ECOSYSTEM"),
                "the walkthrough does not say where a guessed mapping ends up")
        #expect(section.count > 400, "the walkthrough is \(section.count) characters")
    }
}

/// The worked example in the documentation, run.
///
/// It is the only complete descriptor a reader is given, and the one thing
/// they will copy. An example that has quietly stopped decoding — a field
/// renamed, a rule tightened — is worse than none: they would follow it
/// exactly and be told their own file is wrong.
///
/// Taken out of the document rather than repeated here, so the thing under
/// test is the thing they read.
@Suite("The documented LiteLLM example works")
struct WorkedExampleTests {

    private func documentedDescriptor() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"),
                              encoding: .utf8)
        let heading = try #require(text.range(of: "### A worked example"),
                                   "the worked example is gone")
        let after = text[heading.upperBound...]
        let open = try #require(after.range(of: "```json"), "the example carries no descriptor")
        let close = try #require(after[open.upperBound...].range(of: "```"),
                                 "the example's code block is unterminated")
        let json = String(after[open.upperBound..<close.lowerBound])
        return try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            "the documented example is not a JSON object")
    }

    @Test("It decodes as a descriptor")
    func exampleDecodes() throws {
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: try documentedDescriptor())).descriptor
        #expect(descriptor.quota?.endpoint?.hasPrefix("http://127.0.0.1") == true)
        #expect(descriptor.quota?.credential?.kind == "textFile")
    }

    /// And `--check` passes it, since that is the first thing a reader will
    /// run. It exercises the loopback rule too: an example the validator
    /// rejects is the failure this whole example was written after.
    @Test("--check accepts it")
    func exampleChecksClean() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worked-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: try documentedDescriptor()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HarnessCheck.run(url.path) == 0)
    }

    /// The mapping, against the reply LiteLLM's own documentation shows.
    /// Synthetic figures; the shape is theirs.
    @Test("It charts a key with a budget")
    func exampleMapsAReply() throws {
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: try documentedDescriptor())).descriptor
        let provider = try #require(DescriptorProvider(descriptor))
        let snapshot = try provider.makeSnapshot(
            ["key": "sk-synthetic", "info": ["spend": 2.5, "max_budget": 10.0]])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.title == "Key budget")
        #expect(gauge.badge == "KEY")
        #expect(abs(gauge.used - 0.25) < 0.0001, "2.5 of 10 was charted as \(gauge.used)")
    }

    /// The case the documentation warns about: no budget set, so no
    /// denominator, so nothing charted. A spend figure with no cap is not a
    /// meter, and drawing one would be a bar against a number nobody stated.
    @Test("A key with no budget charts nothing rather than guessing one")
    func noBudgetChartsNothing() throws {
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: try documentedDescriptor())).descriptor
        let provider = try #require(DescriptorProvider(descriptor))
        #expect(throws: (any Error).self) {
            _ = try provider.makeSnapshot(
                ["key": "sk-synthetic", "info": ["spend": 2.5, "max_budget": NSNull()]])
        }
    }

    /// And the documentation says both of those things, since the example is
    /// only safe to copy if the reader is told when it will show nothing.
    @Test("The example says what happens with no budget")
    func exampleExplainsTheEmptyCase() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"),
                              encoding: .utf8)
        let heading = try #require(text.range(of: "### A worked example"))
        let after = text[heading.upperBound...]
        // The prose, not the descriptor. `max_budget` appears in the example
        // itself, so a check over the whole section is satisfied by the JSON
        // and says nothing about whether the reader was told what it does —
        // which is what this is for. The first version did exactly that, and
        // the mutation removing the explanation survived it.
        let open = try #require(after.range(of: "```json"))
        let close = try #require(after[open.upperBound...].range(of: "```"))
        let prose = String(after[close.upperBound...].prefix(2_000))
        #expect(prose.contains("max_budget"),
                "the prose does not mention the field that decides whether anything is drawn")
        #expect(prose.contains("no denominator") || prose.contains("nothing is charted"),
                "the prose does not say that a key with no budget shows nothing")
        #expect(prose.contains("quota-fixture.json"),
                "the example does not say how to check it against a real reply")
    }
}

/// The README names every tool that ships, and no others.
///
/// It listed eleven while twenty-five shipped. Fourteen were missing —
/// Gemini CLI, which has a native provider of its own; every quota-only
/// account, so OpenRouter, Z.ai, DeepSeek, MiniMax, Vercel and the rest; and
/// Herdr and Orca, which somebody asked for specifically. A reader looking
/// for one of those would conclude it was not supported, which is the same
/// failure as promising one that is not there and harder to notice, because
/// nothing looks wrong.
@Suite("The README lists what ships")
struct SupportedToolsListTests {

    private var readme: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("README.md"),
                            encoding: .utf8)) ?? ""
    }

    private var shipped: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    @Test("Every shipped harness is named")
    func everyHarnessIsListed() {
        #expect(shipped.count >= 20, "only \(shipped.count) harnesses were read from the bundle")
        let text = readme
        var missing: [String] = []
        for descriptor in shipped where !text.contains(descriptor.name) {
            missing.append(descriptor.name)
        }
        #expect(missing.isEmpty,
                Comment(rawValue: "these ship and the README does not mention them: "
                        + missing.joined(separator: ", ")))
    }

    /// And the count it states is the number that ship, since a reader takes
    /// that at face value and it is the easiest thing to leave behind.
    @Test("The stated count is the number of harnesses")
    func statedCountIsRight() throws {
        let line = try #require(readme.split(separator: "\n")
            .first { $0.contains("ships harnesses for") },
            "the README no longer says how many tools it supports")
        #expect(line.contains("\(shipped.count) tools"),
                Comment(rawValue: "the README says \"\(line)\" and \(shipped.count) ship"))
    }

    /// The list does not name tools that do not ship either — a reader
    /// hunting for one of those finds nothing and concludes the app is
    /// broken rather than that the README is.
    @Test("No tool is listed that does not ship")
    func noPhantomTools() {
        let names = Set(shipped.map(\.name))
        // Scoped to the section rather than guessed from the shape of a
        // line. The first version looked at every bullet in the file and
        // reported three questions from "Great for" as tools that do not
        // ship — a check that reads the wrong part of a document says
        // nothing about the right part.
        let text = readme
        guard let start = text.range(of: "## Supported tools") else {
            Issue.record("the supported tools section is gone")
            return
        }
        let after = text[start.upperBound...]
        let end = after.range(of: "\n## ")?.lowerBound ?? after.endIndex
        var phantom: [String] = []
        for line in after[..<end].split(separator: "\n") where line.hasPrefix("- ") {
            let entry = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !entry.isEmpty && !names.contains(entry) { phantom.append(entry) }
        }
        #expect(phantom.isEmpty,
                Comment(rawValue: "listed and not shipped: \(phantom.joined(separator: ", "))"))
    }
}

/// The instructions a contributor follows name the gate this project
/// actually requires.
///
/// AGENTS.md has said "Required verification: ./verify.sh" for as long as
/// verify.sh has existed. The README offered `./test.sh` as "the full
/// project checks" and CONTRIBUTING listed the three commands verify.sh
/// wraps — so somebody following either ran the suite and a build and
/// skipped the rest: the run on a machine that has never had Antarium, the
/// one outside UTC, the mutation catalogue's applicability, every harness
/// through --check, the assembled app's resources, the first-run paths and
/// the benchmark. Instructions that ask for less than the gate are how a
/// change arrives having passed everything its author was told to run.
@Suite("The contributor instructions name the required gate")
struct VerificationInstructionsTests {

    private func document(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("Both documents name verify.sh where they describe checking a change",
          arguments: ["README.md", "CONTRIBUTING.md"])
    func documentsNameTheGate(file: String) throws {
        let text = try document(file)
        #expect(text.contains("./verify.sh"),
                Comment(rawValue: "\(file) does not tell a reader to run the gate"))

        // In a block somebody copies, not only in a sentence. Mentioning it
        // in prose and offering the old command in the block leaves a reader
        // running the old command, and the first version of this test held
        // on the sentence alone.
        let blocks = text.components(separatedBy: "```").enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
        #expect(blocks.contains { $0.contains("./verify.sh") },
                Comment(rawValue: "\(file) mentions the gate only in prose; the commands "
                        + "it offers to copy are the old ones"))
    }

    /// And AGENTS.md still calls it required, so the three documents agree
    /// rather than one of them having drifted quietly.
    @Test("The repository guide still requires it")
    func guideRequiresIt() throws {
        let text = try document("AGENTS.md")
        #expect(text.contains("## Required verification"))
        #expect(text.contains("./verify.sh"))
    }

    /// The script exists and is executable, which is the part a reader finds
    /// out the hard way.
    @Test("The gate is a script that can be run")
    func theGateExists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("verify.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path),
                "verify.sh is named by every document and is not executable")
    }
}

/// "Cost is clearly presented as an estimate" — the README, under
/// Trustworthy numbers.
///
/// It is list-price arithmetic over token counts, not a bill, and a reader
/// who takes it for one will be wrong by whatever discount, credit or
/// enterprise agreement they have. The word was in the help text wherever a
/// figure is drawn and nothing held it there; and the accessibility summary,
/// which *is* the help for anybody hearing the row rather than seeing it,
/// said "cost $1.23" with no qualifier at all.
@Suite("A cost is presented as an estimate wherever it appears")
struct CostIsAnEstimateTests {

    private func dashboard() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
    }

    /// Every drawn figure carries the word in the text beside it.
    @Test("Each cost the dashboard draws is described as estimated")
    func drawnCostsSayEstimated() throws {
        let text = try dashboard()
        // Each figure, not a tally. Counting "Estimated" against the number
        // of figures had slack in it — one help text carries the word twice,
        // for its two branches, so removing another one still satisfied the
        // count. Every drawn figure is asked for itself.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var bare: [Int] = []
        var drawn = 0
        for (index, line) in lines.enumerated() where line.contains("Pricing.money") {
            drawn += 1
            // Wide enough to reach a `.help` attached below the view that
            // draws the figure, which is ten lines away in one case and was
            // reported as bare by a tighter window.
            let from = max(0, index - 4), to = min(lines.count, index + 13)
            let near = lines[from..<to].joined(separator: "\n").lowercased()
            if !near.contains("estimated") { bare.append(index + 1) }
        }
        #expect(drawn >= 3, "only \(drawn) cost figures were found")
        #expect(bare.isEmpty,
                Comment(rawValue: "a cost is drawn with nothing calling it an estimate, "
                        + "at line(s) \(bare.map(String.init).joined(separator: ", "))"))
    }

    /// The spoken one especially: there is no tooltip to hear.
    @Test("The spoken summary says estimated")
    func spokenCostSaysEstimated() throws {
        let text = try dashboard()
        #expect(text.contains("estimated cost \\(Pricing.money(cost))"),
                "a reader hearing the row is told a cost with no qualifier")
    }

    /// And the README still makes the promise, so this is holding something
    /// somebody was told rather than a preference of mine.
    @Test("The README still promises it")
    func readmePromisesIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"),
                                encoding: .utf8)
        // Matched on the phrase rather than the sentence: the line wraps in
        // the file, so the full sentence never appears on one line and the
        // first version of this looked for something that is not there.
        #expect(readme.contains("clearly presented as an estimate"),
                "the promise this suite holds is no longer made")
    }
}
