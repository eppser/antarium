import Foundation
import Testing
@testable import Antarium

/// Honouring the variable an agent uses to move its own data directory.
///
/// The rule is a pure function over an injected environment, which is the whole
/// point: it is tested on a machine with none of these agents installed and no
/// such variable set. Setting one in the test process would leak into every
/// other suite and would make the result depend on the order they run in.
@Suite("A harness follows its agent's relocation variable")
struct RelocationTests {

    private func rule(_ env: String, _ replaces: String)
        -> HarnessDescriptor.Source.Relocation {
        HarnessDescriptor.Source.Relocation(env: env, replaces: replaces)
    }

    private func resolve(_ path: String, _ relocation: HarnessDescriptor.Source.Relocation?,
                         _ environment: [String: String] = [:]) -> String {
        HarnessDescriptor.Source.resolve(path, relocate: relocation, environment: environment)
    }

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    @Test("The variable replaces the prefix it stands for")
    func variableReplacesPrefix() {
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "/custom/codex"]) == "/custom/codex/sessions")
    }

    @Test("An unset variable leaves the path as written")
    func unsetLeavesPath() {
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"))
                == home + "/.codex/sessions")
    }

    /// Empty and whitespace are not a relocation. A variable exported without a
    /// value would otherwise send every read to `/sessions`.
    @Test("An empty variable is not a relocation", arguments: ["", "   ", "\n", "\t "])
    func emptyIsNotARelocation(value: String) {
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": value]) == home + "/.codex/sessions",
                Comment(rawValue: "a variable set to \(value.debugDescription) moved the path"))
    }

    @Test("No declared relocation leaves the path as written")
    func noRuleLeavesPath() {
        #expect(resolve("~/.codex/sessions", nil, ["CODEX_HOME": "/custom"])
                == home + "/.codex/sessions")
    }

    /// A boundary, not a string prefix — the mistake `abbreviatingHome` made in
    /// reverse, where a home of `/Users/sam` matched `/Users/sammy`.
    @Test("The prefix is matched on a path boundary", arguments: [
        "~/.codex-backup/sessions", "~/.codexfoo", "~/.codexsessions",
    ])
    func prefixIsABoundary(path: String) {
        #expect(resolve(path, rule("CODEX_HOME", "~/.codex"), ["CODEX_HOME": "/custom/codex"])
                == path.expandingTilde,
                Comment(rawValue: "\(path) was relocated by a rule for ~/.codex"))
    }

    @Test("A path that is exactly the prefix becomes the variable's value")
    func exactPrefix() {
        #expect(resolve("~/.codex", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "/custom/codex"]) == "/custom/codex")
    }

    /// A trailing slash in the variable must not double up. Shell users write
    /// both, and `//sessions` is a different path to some readers.
    @Test("A trailing slash in the variable is not doubled")
    func trailingSlash() {
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "/custom/codex/"]) == "/custom/codex/sessions")
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "/custom/codex///"]) == "/custom/codex/sessions")
        // And the one value that strips to nothing: the root itself. A root
        // with nothing after it is the root, not the empty path.
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "/"]) == "/sessions")
        #expect(resolve("~/.codex", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "/"]) == "/")
    }

    /// A variable holding a home-relative path is expanded too, since that is
    /// what a shell profile usually writes.
    @Test("A variable holding a tilde is expanded")
    func tildeInVariable() {
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["CODEX_HOME": "~/elsewhere/codex"])
                == home + "/elsewhere/codex/sessions")
    }

    /// Another variable being set does not move this harness.
    @Test("An unrelated variable is ignored")
    func unrelatedVariable() {
        #expect(resolve("~/.codex/sessions", rule("CODEX_HOME", "~/.codex"),
                        ["KIMI_CODE_HOME": "/custom/kimi"]) == home + "/.codex/sessions")
    }
}

/// The declarations that ship, and the refusal of one that could never work.
@Suite("The shipped relocations are the ones their agents document")
struct ShippedRelocationTests {

    private var descriptors: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    /// The pairs, as data, because they are facts about other people's tools.
    static let expected: [(id: String, env: String, replaces: String)] = [
        ("codex", "CODEX_HOME", "~/.codex"),
        ("codex-desktop", "CODEX_HOME", "~/.codex"),
        ("kimi", "KIMI_CODE_HOME", "~/.kimi-code"),
        ("hermes", "HERMES_HOME", "~/.hermes"),
        ("openclaw", "OPENCLAW_PROFILE", "~/.openclaw"),
    ]

    @Test("Each harness that documents a relocation declares it",
          arguments: ShippedRelocationTests.expected)
    func declared(entry: (id: String, env: String, replaces: String)) throws {
        let descriptor = try #require(descriptors.first { $0.id == entry.id },
                                      Comment(rawValue: "\(entry.id) no longer ships"))
        let relocate = try #require(descriptor.source.relocate,
                                    Comment(rawValue: "\(entry.id) declares no relocation"))
        #expect(relocate.env == entry.env)
        #expect(relocate.replaces == entry.replaces)
    }

    /// The pair that started this: the native provider and the harness have to
    /// agree about where Codex lives, or a relocated home shows quota and no
    /// sessions.
    @Test("Codex's two halves agree about where it lives")
    func codexHalvesAgree() throws {
        let harness = try #require(descriptors.first { $0.id == "codex" })
        let relocate = try #require(harness.source.relocate)
        #expect(relocate.env == "CODEX_HOME",
                "the harness follows a different variable to the provider")
        // The provider reads the variable directly; the harness names the prefix
        // that variable stands for, and that prefix has to be the directory the
        // provider would fall back to.
        #expect(relocate.replaces == "~/.codex")
        #expect(harness.source.path.hasPrefix(relocate.replaces))
    }

    /// Every declared relocation must be able to fire, which the validator
    /// enforces at decode. Asserted over what ships too, since a descriptor
    /// edited by hand goes through the same boundary.
    @Test("Every shipped relocation names a prefix its path has")
    func everyRelocationCanFire() {
        var checked = 0
        for descriptor in descriptors {
            guard let relocate = descriptor.source.relocate else { continue }
            checked += 1
            let path = descriptor.source.path
            #expect(path == relocate.replaces || path.hasPrefix(relocate.replaces + "/"),
                    Comment(rawValue: "\(descriptor.id): \(relocate.replaces) is not a prefix "
                            + "of \(path)"))
        }
        #expect(checked == Self.expected.count,
                Comment(rawValue: "\(checked) harnesses declare a relocation and "
                        + "\(Self.expected.count) are listed"))
    }

    @Test("A relocation naming a prefix the path does not have is refused")
    func impossibleRelocationRefused() {
        let data = Data("""
        {
          "formatVersion":1,"id":"reloc-bad","name":"Reloc bad","process":{},
          "source":{"kind":"jsonl","path":"~/.somewhere/sessions","glob":"*.jsonl",
                    "relocate":{"env":"SOME_HOME","replaces":"~/.elsewhere"}}
        }
        """.utf8)
        #expect(throws: HarnessDocument.Error.self) { _ = try HarnessDocument.decode(data) }
    }

    @Test("A relocation missing either half is refused", arguments: [
        #""relocate":{"env":"SOME_HOME"}"#,
        #""relocate":{"replaces":"~/.somewhere"}"#,
        #""relocate":{"env":"","replaces":"~/.somewhere"}"#,
        #""relocate":{"env":"SOME_HOME","replaces":""}"#,
    ])
    func incompleteRelocationRefused(declaration: String) {
        let data = Data("""
        {
          "formatVersion":1,"id":"reloc-part","name":"Reloc part","process":{},
          "source":{"kind":"jsonl","path":"~/.somewhere/sessions","glob":"*.jsonl",
                    \(declaration)}
        }
        """.utf8)
        #expect(throws: HarnessDocument.Error.self,
                Comment(rawValue: "accepted \(declaration)")) {
            _ = try HarnessDocument.decode(data)
        }
    }

    /// And a well-formed one decodes and resolves.
    @Test("A well-formed relocation decodes and resolves")
    func wellFormedRelocation() throws {
        let data = Data("""
        {
          "formatVersion":1,"id":"reloc-ok","name":"Reloc ok","process":{},
          "source":{"kind":"jsonl","path":"~/.somewhere/sessions","glob":"*.jsonl",
                    "relocate":{"env":"SOME_HOME","replaces":"~/.somewhere"}}
        }
        """.utf8)
        let source = try HarnessDocument.decode(data).descriptor.source
        #expect(HarnessDescriptor.Source.resolve(source.path, relocate: source.relocate,
                                                 environment: ["SOME_HOME": "/moved"])
                == "/moved/sessions")
    }
}
