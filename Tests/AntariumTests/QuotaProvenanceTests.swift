import Foundation
import Testing
@testable import Antarium

/// Where a quota mapping's field paths came from.
///
/// A descriptor with `verified: false` has never been held against a live
/// account. That is recorded honestly and the row says so, but it leaves one
/// question open: how does anyone check the mapping is right without signing
/// up for the service? The answer is to read the vendor's reference and
/// compare — which needs the reference's address, and that was consulted when
/// each mapping was written and then not written down.
///
/// These are the citations, and what they have to satisfy.
@Suite("Quota mappings cite where they were read from")
struct QuotaProvenanceTests {

    private var quotaDescriptors: [HarnessDescriptor] {
        HarnessCLI.bundledDescriptors().filter { $0.quota != nil }
    }

    @Test("There are quota descriptors to say anything about")
    func thereAreSubjects() {
        #expect(quotaDescriptors.count >= 10,
                Comment(rawValue: "only \(quotaDescriptors.count) quota descriptors were found"))
    }

    /// An http URL, a bare hostname or a sentence would all be worse than
    /// nothing: they look like provenance and cannot be followed.
    @Test("Every citation is an https URL")
    func citationsAreURLs() {
        var checked = 0
        for descriptor in quotaDescriptors {
            guard let cited = descriptor.quota?.documentation else { continue }
            checked += 1
            #expect(cited.hasPrefix("https://"),
                    Comment(rawValue: "\(descriptor.id) cites \(cited), which is not an https URL"))
            #expect(URL(string: cited)?.host?.contains(".") == true,
                    Comment(rawValue: "\(descriptor.id) cites \(cited), which has no host"))
            #expect(!cited.contains(" "),
                    Comment(rawValue: "\(descriptor.id)'s citation contains a space"))
        }
        #expect(checked >= 4,
                Comment(rawValue: "only \(checked) descriptors cite a source, so this proved little"))
    }

    /// The four whose response shape was read field by field against the
    /// vendor's own reference. Named individually rather than counted, so
    /// dropping one is a failure rather than a smaller number.
    ///
    /// Each was confirmed exactly: the endpoint, the nesting, the field names
    /// and whether the value arrives as a number or a string — DeepSeek and
    /// Vercel both state their amounts as strings, which is why `FieldPath`
    /// accepting one is load-bearing rather than defensive.
    @Test("The mappings checked against a published schema still cite it",
          arguments: ["deepseek", "openrouter", "moonshot", "vercel-gateway"])
    func checkedMappingsCiteTheirSource(id: String) throws {
        let descriptor = try #require(quotaDescriptors.first { $0.id == id },
                                      Comment(rawValue: "\(id) no longer ships"))
        let cited = try #require(descriptor.quota?.documentation,
                                 Comment(rawValue: "\(id) lost the source its mapping was read from"))
        #expect(cited.hasPrefix("https://"))
    }

    /// A string value is not an unusual case to be defensive about: two of
    /// the four vendors above publish their balance that way, so a reader
    /// that took only JSON numbers would report nothing for either and look
    /// exactly like an account with no credit.
    @Test("A balance published as a string reads as the same amount as a number")
    func stringAmountsAreRead() {
        #expect(FieldPath.numeric("95.50") == 95.50)
        #expect(FieldPath.numeric(95.50) == 95.50)
        #expect(FieldPath.numeric("0") == 0, "a zero balance must not read as absent")
        #expect(FieldPath.numeric("") == nil)
        #expect(FieldPath.numeric("not a number") == nil)
        // Distinct from zero, or "no figure" and "no credit" become the same.
        #expect(FieldPath.numeric("1e400") == nil, "an unrepresentable amount is not a figure")
    }
}

/// What a descriptor provider says when the reply carries windows it was not
/// written to read.
///
/// "Reported no usage window" is true and unactionable for the account that
/// hits it most often: a plan whose limits are all of a kind the mapping does
/// not name reads exactly like a plan with no limits at all. Z.ai is the
/// concrete case — its mapping names `TOKENS_LIMIT` and `TIME_LIMIT`, and
/// other tools have reported accounts whose replies carry a different kind
/// entirely. The mapping is not changed on that evidence, because a field
/// path taken from another tool's issue tracker is a guess about somebody
/// else's product. What changes is that the message says what it saw.
@Suite("An unreadable reply says what it did contain")
struct UnreadableWindowMessageTests {

    private func provider(_ id: String) throws -> DescriptorProvider {
        let descriptor = try #require(
            HarnessCLI.bundledDescriptors().first { $0.id == id && $0.quota != nil },
            Comment(rawValue: "\(id) no longer ships a quota block"))
        return try #require(DescriptorProvider(descriptor),
                            Comment(rawValue: "\(id) no longer builds a provider"))
    }

    @Test("Window names the mapping does not know are reported back")
    func unknownWindowsAreNamed() throws {
        let zai = try provider("zai")
        let reply: [String: Any] = ["data": ["limits": [
            ["type": "CREDIT_LIMIT", "unit": 3, "percentage": 40],
            ["type": "CREDIT_LIMIT", "unit": 6, "percentage": 12]]]]
        do {
            _ = try zai.makeSnapshot(reply)
            Issue.record("a reply with no readable window produced a snapshot")
        } catch let error as ProviderError {
            let text = "\(error)"
            #expect(text.contains("CREDIT_LIMIT"),
                    Comment(rawValue: "the message does not say what it saw: \(text)"))
        }
    }

    /// And a reply that genuinely carries nothing says that instead, or the
    /// two situations would read the same from the other direction.
    @Test("A reply with no windows at all is not described as unreadable ones")
    func emptyRepliesSayNothingExtra() throws {
        let zai = try provider("zai")
        do {
            _ = try zai.makeSnapshot(["data": ["limits": []]])
            Issue.record("an empty reply produced a snapshot")
        } catch let error as ProviderError {
            let text = "\(error)"
            #expect(!text.contains("The reply named:"),
                    Comment(rawValue: "an empty reply listed windows: \(text)"))
        }
    }

    /// Built here rather than taken from what ships: every shipped descriptor
    /// names a window from at most two fields, and the bounds below are about
    /// a descriptor that names one from five. A contributed harness is a file
    /// somebody else writes.
    private func synthetic(key: [String], keys: [String]) throws -> DescriptorProvider {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "synthetic-quota", "name": "Synthetic", "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/usage",
                      "windows": ["list": "limits", "key": key, "keys": keys,
                                  "usedPercent": "percentage"]],
        ]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return try #require(DescriptorProvider(descriptor))
    }

    /// The names are vendor text on their way to a menu item, and a reply can
    /// carry a great many of them, each built from several fields.
    @Test("The names repeated back are bounded in number and in length")
    func namesAreBounded() throws {
        let parts = ["a", "b", "c", "d", "e"]
        let provider = try synthetic(key: parts, keys: ["nothing-matches-this"])
        let limits = (0..<200).map { _ -> [String: Any] in
            var window: [String: Any] = ["percentage": 1]
            for part in parts { window[part] = String(repeating: "L", count: 500) }
            return window
        }
        do {
            _ = try provider.makeSnapshot(["limits": limits])
            Issue.record("a reply with no readable window produced a snapshot")
        } catch let error as ProviderError {
            let text = "\(error)"
            #expect(text.count < 600,
                    Comment(rawValue: "the message ran to \(text.count) characters"))
        }
    }

    /// A window whose name is the empty string is nameable — an object key
    /// can be "" — and listing it back would put a stray comma in the
    /// message where a name should be.
    @Test("A window with no name of its own is not listed as a blank")
    func blankNamesAreNotListed() throws {
        let provider = try synthetic(key: ["label"], keys: ["nothing-matches-this"])
        let reply: [String: Any] = ["limits": [
            ["label": "", "percentage": 1],
            ["label": "real-window", "percentage": 2]]]
        do {
            _ = try provider.makeSnapshot(reply)
            Issue.record("a reply with no readable window produced a snapshot")
        } catch let error as ProviderError {
            let text = "\(error)"
            #expect(text.contains("real-window"))
            #expect(!text.contains(": ,") && !text.contains(", ,") && !text.contains(", ."),
                    Comment(rawValue: "a nameless window was listed as a blank: \(text)"))
        }
    }
}
