import Foundation
import Testing
@testable import Antarium

/// What this app covers of ClaudeBar's roster, checked rather than claimed.
///
/// "Add all usage APIs from ClaudeBar" has been the first ask since the
/// beginning, and until now the only record of how far it got was a commit
/// message. `docs/ECOSYSTEM.md` argues every provider it mentions, carefully,
/// but it never names ClaudeBar — so it can explain at length why something
/// was not taken while saying nothing about a provider it forgot existed.
/// A goal with no scoreboard is not measurable, and this is the scoreboard.
///
/// The roster below is ClaudeBar's own list of what it monitors, read from
/// its repository on 2026-09-24. It is literal data on purpose: it is a fact
/// about somebody else's project, so it cannot be derived from this one, and
/// writing it down is the only thing that makes the comparison possible.
/// When ClaudeBar adds a provider, this list is what has to change, and the
/// test below says what changing it costs.
@Suite("Every provider ClaudeBar monitors is accounted for")
struct ClaudeBarCoverageTests {

    /// How far this app goes for one of ClaudeBar's providers.
    enum Coverage {
        /// Reads the service's usage API. The bar shows a gauge.
        case usage
        /// The agent is recognised and gets rows, but no usage API is mapped
        /// — the service publishes none this app can read, or none at all.
        case sessionsOnly
        /// Not covered. The reason must be written down.
        case absent
    }

    /// One of ClaudeBar's providers, and what became of it here.
    struct Entry {
        let claudeBar: String
        let id: String?
        let coverage: Coverage
        /// What `ECOSYSTEM.md` calls it, where that differs. ClaudeBar says
        /// "AWS Bedrock" and the table here says "Amazon Bedrock"; the roster
        /// keeps ClaudeBar's name because the roster is ClaudeBar's.
        let documentedAs: String?

        init(_ claudeBar: String, _ id: String?, _ coverage: Coverage,
             documentedAs: String? = nil) {
            self.claudeBar = claudeBar
            self.id = id
            self.coverage = coverage
            self.documentedAs = documentedAs
        }

        var documentName: String { documentedAs ?? claudeBar }
    }

    /// ClaudeBar's twenty, and the id each corresponds to here.
    static let roster: [Entry] = [
        Entry("Claude", "claude-code", .usage),
        Entry("Codex", "codex", .usage),
        Entry("Gemini", "gemini", .usage),
        Entry("Copilot", "copilot", .usage),
        Entry("Cursor", "cursor", .usage),
        Entry("Kiro", "kiro", .usage),
        Entry("DeepSeek", "deepseek", .usage),
        Entry("MiniMax", "minimax", .usage),
        Entry("Z.ai", "zai", .usage),
        Entry("Amp Code", "ampcode", .usage),
        Entry("OpenCode Go", "opencode", .usage),
        Entry("Grok", "grok", .usage),
        Entry("Command Code", "commandcode", .usage),
        Entry("Vercel Gateway", "vercel-gateway", .usage),
        // Recognised, with rows, but no usage API mapped.
        Entry("Kimi", "kimi", .sessionsOnly),
        Entry("Oh My Pi", "pi", .sessionsOnly, documentedAs: "Omp"),
        // Not covered at all. Each is argued in ECOSYSTEM.md.
        Entry("Antigravity", nil, .absent),
        Entry("AWS Bedrock", nil, .absent, documentedAs: "Amazon Bedrock"),
        Entry("Mistral", nil, .absent),
        Entry("Alibaba", nil, .absent, documentedAs: "Alibaba Model Studio"),
    ]

    private var descriptorIDs: Set<String> {
        Set(HarnessCLI.bundledDescriptors().map(\.id))
    }

    /// The providers this app ships a usage API for: the native ones, plus
    /// every bundled descriptor that declares a quota.
    ///
    /// Read from the bundle rather than from `ProviderRegistry.all`, which
    /// also includes whatever the descriptor folder happens to hold. That
    /// distinction is not academic — the first version of this asked `all`,
    /// passed here, and failed on a machine with an unseeded home, where the
    /// registry is the seven native providers and nothing else. The question
    /// is what ships, not what this Mac has.
    private var usageIDs: Set<String> {
        let bundled = HarnessCLI.bundledDescriptors()
        return Set(ProviderRegistry.providers(from: bundled).map(\.id))
            .union(ProviderRegistry.nativeIDs)
    }

    @Test("The roster is ClaudeBar's twenty")
    func rosterIsComplete() {
        #expect(Self.roster.count == 20,
                Comment(rawValue: "the roster names \(Self.roster.count)"))
        #expect(Set(Self.roster.map(\.claudeBar)).count == 20, "a provider is named twice")
    }

    /// The claim that matters: a provider recorded as covered really is.
    @Test("Every provider recorded as covered reads a usage API")
    func usageProvidersExist() throws {
        let usage = usageIDs
        for entry in Self.roster where entry.coverage == .usage {
            let id = try #require(entry.id,
                                  Comment(rawValue: "\(entry.claudeBar) claims usage and names no id"))
            #expect(usage.contains(id),
                    Comment(rawValue: "\(entry.claudeBar) is recorded as covered by usage, "
                            + "but no provider with id \(id) reads one"))
        }
    }

    /// And the weaker claim, which is the one most likely to drift: an agent
    /// recognised without a usage API must still be recognised, and must
    /// genuinely lack one. If a usage API is added for it later, this fails
    /// and the roster gets corrected rather than quietly understating what
    /// ships.
    @Test("Every provider recorded as sessions-only is recognised and has no gauge")
    func sessionOnlyProvidersExist() throws {
        let descriptors = descriptorIDs, usage = usageIDs
        for entry in Self.roster where entry.coverage == .sessionsOnly {
            let id = try #require(entry.id)
            #expect(descriptors.contains(id),
                    Comment(rawValue: "\(entry.claudeBar) is recorded as recognised, "
                            + "but no descriptor has id \(id)"))
            #expect(!usage.contains(id),
                    Comment(rawValue: "\(entry.claudeBar) now reads a usage API — "
                            + "the roster still records it as sessions-only"))
        }
    }

    /// A gap has to be argued, not merely left. Each absent provider is named
    /// in ECOSYSTEM.md, which is where the reason lives.
    @Test("Every gap is named in the document that explains the gaps")
    func gapsAreExplained() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: "docs/ECOSYSTEM.md"),
                             encoding: .utf8)
        for entry in Self.roster where entry.coverage == .absent {
            #expect(entry.id == nil,
                    Comment(rawValue: "\(entry.claudeBar) is recorded as absent and names an id"))
            #expect(doc.localizedCaseInsensitiveContains(entry.documentName),
                    Comment(rawValue: "\(entry.claudeBar) is not covered and ECOSYSTEM.md "
                            + "does not say why (looked for \"\(entry.documentName)\")"))
        }
    }

    /// The document is anchored to the roster, which was the whole defect:
    /// ECOSYSTEM.md discussed each provider on its own terms and never named
    /// the list it was meant to cover, so a provider nobody thought of was
    /// indistinguishable from one deliberately declined.
    @Test("The document names the roster it is measured against")
    func documentNamesClaudeBar() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: "docs/ECOSYSTEM.md"),
                             encoding: .utf8)
        #expect(doc.contains("ClaudeBar"),
                "ECOSYSTEM.md never names ClaudeBar, so nothing ties its gaps to a roster")
    }

    /// The counts, stated once so a change to the roster has to be a
    /// deliberate edit here rather than a silent drift.
    @Test("Coverage stands at fourteen usage, two recognised, four open")
    func coverageCounts() {
        let usage = Self.roster.filter { $0.coverage == .usage }.count
        let sessions = Self.roster.filter { $0.coverage == .sessionsOnly }.count
        let absent = Self.roster.filter { $0.coverage == .absent }.count
        #expect(usage == 14, Comment(rawValue: "usage coverage is \(usage)"))
        #expect(sessions == 2, Comment(rawValue: "sessions-only is \(sessions)"))
        #expect(absent == 4, Comment(rawValue: "open gaps number \(absent)"))
        #expect(usage + sessions + absent == Self.roster.count)
    }

    /// And the document says the same numbers, in digits so there is
    /// something to compare. The sentence one section earlier said "Nine of
    /// the twenty-two" for two years' worth of descriptors ago.
    @Test("The document states the coverage it is measured at")
    func documentedCounts() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: "docs/ECOSYSTEM.md"),
                             encoding: .utf8)
        let usage = Self.roster.filter { $0.coverage == .usage }.count
        let sentence = "\(usage) of the \(Self.roster.count) are read for usage here"
        #expect(doc.contains(sentence),
                Comment(rawValue: "ECOSYSTEM.md should say \"\(sentence)\""))
    }

    /// This app also reads usage APIs ClaudeBar does not, so the comparison
    /// is not mistaken for a ceiling.
    @Test("Providers beyond ClaudeBar's roster also ship")
    func coverageExceedsTheRoster() {
        let rostered = Set(Self.roster.compactMap(\.id))
        let extra = usageIDs.subtracting(rostered)
        #expect(!extra.isEmpty,
                "every usage provider here came from ClaudeBar's roster, which would make this app a strict subset")
    }
}
