import Foundation
import Testing
@testable import Antarium

/// The label beside every row. It is the most-read string this app produces
/// and it had no tests, so nothing noticed that a dated model id put the date
/// in the menu bar.
@Suite("Model labels are short enough to sit in a row")
struct ModelLabelTests {

    @Test("Claude models read as family and version", arguments: [
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-opus-4-5", "Opus 4.5"),
        ("claude-haiku-3-5", "Haiku 3.5"),
        ("claude-fable-5", "Fable 5"),
    ])
    func claudeModels(_ id: String, _ expected: String) {
        #expect(Pricing.shortName(id) == expected)
    }

    /// Claude Code reports dated ids — `claude-haiku-4-5-20251001` is the
    /// shipped id for Haiku 4.5. Joining every component after the family put
    /// the date straight into the bar.
    @Test("A dated model id does not carry the date into the label", arguments: [
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-opus-4-1-20250805", "Opus 4.1"),
        ("claude-sonnet-4-20250514", "Sonnet 4"),
    ])
    func datedModels(_ id: String, _ expected: String) {
        #expect(Pricing.shortName(id) == expected)
    }

    @Test("A context-window suffix is not part of the name")
    func bracketSuffix() {
        #expect(Pricing.shortName("claude-sonnet-4-5[1m]") == "Sonnet 4.5")
        #expect(Pricing.shortName("claude-opus-5[200k]") == "Opus 5")
    }

    @Test("A provider prefix is routing, not identity", arguments: [
        ("~openai/gpt-5", "GPT 5"),
        ("mlx-community/Qwen3", "Qwen3"),
        ("openrouter/deepseek-chat", "Deepseek Chat"),
    ])
    func providerQualified(_ id: String, _ expected: String) {
        #expect(Pricing.shortName(id) == expected)
    }

    @Test("Churn words are dropped and the name stays to two words")
    func compact() {
        #expect(Pricing.shortName("gpt-5-latest") == "GPT 5")
        #expect(Pricing.shortName("glm-4-6-preview") == "GLM 4")
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(Pricing.shortName(nil) == nil)
        #expect(Pricing.shortName("") == nil)
    }

    /// Every prefix the app ships a price for has to produce a label, or a
    /// priced row shows a cost with no model beside it.
    @Test("Every shipped model prefix yields a label")
    func shippedPrefixesAllLabel() throws {
        let url = try #require(AppResources.bundle.url(forResource: "pricing",
                                                       withExtension: "json"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let models = try #require(object["models"] as? [[String: Any]])
        #expect(models.count > 1)
        for entry in models {
            let prefix = try #require(entry["prefix"] as? String)
            let label = try #require(Pricing.shortName(prefix),
                                     Comment(rawValue: "\(prefix) has no label"))
            #expect(!label.isEmpty)
            // A menu bar row is narrow; anything long enough to push the
            // numbers off the end is a bug whatever it says.
            #expect(label.count <= 20, Comment(rawValue: "\(prefix) -> \(label)"))
        }
    }
}
