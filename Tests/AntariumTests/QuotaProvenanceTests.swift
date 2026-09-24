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

    /// Every mapping records the day its figures were last read against
    /// something outside this repository.
    ///
    /// The check this dates is the one nothing here can perform. A fixture is
    /// written from the mapping it tests, so it proves the mapping is applied
    /// and says nothing about whether it is right: five of the seventeen
    /// mappings in this app were wrong behind a green fixture, and MiniMax's
    /// expectations were the exact mirror of the truth for months. A date
    /// that has gone stale is the only signal available that somebody should
    /// read the fields again and ask whether they mean what they are named.
    @Test("Every quota mapping dates its last reading against an outside source")
    func everyMappingIsDated() throws {
        var checked = 0
        for descriptor in quotaDescriptors {
            let day = try #require(descriptor.quota?.checkedAt,
                                   Comment(rawValue: "\(descriptor.id) does not say when its "
                                           + "figures were last read against anything"))
            let parsed = try #require(Self.day.date(from: day),
                                      Comment(rawValue: "\(descriptor.id) dates its reading "
                                              + "\(day), which is not yyyy-MM-dd"))
            #expect(parsed <= Date().addingTimeInterval(86_400),
                    Comment(rawValue: "\(descriptor.id) was read on \(day), which is ahead"))
            checked += 1
        }
        #expect(checked >= 10,
                Comment(rawValue: "only \(checked) mappings were examined"))
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// And the date is not a substitute for the citation, nor the other way
    /// round: a mapping can be read against a vendor reference or against
    /// another implementation, and only the first of those has a URL.
    @Test("A dated mapping still says what it was read against")
    func datedMappingsNameTheirSource() {
        for descriptor in quotaDescriptors where descriptor.quota?.checkedAt != nil {
            let cited = descriptor.quota?.documentation != nil
            let explained = (descriptor.note ?? "").contains("2026-")
            #expect(cited || explained,
                    Comment(rawValue: "\(descriptor.id) dates a reading and names no reference "
                            + "and no note saying what was read"))
        }
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

    /// A citation that is absent because nobody looked, and one that is
    /// absent because the vendor publishes nothing, are different facts and
    /// used to look identical.
    ///
    /// Five of the ten are the second kind, each established by looking:
    /// OpenCode documents its models and its pricing and not this endpoint,
    /// Copilot's is GitHub's own internal one, MiniMax's own page says the
    /// quota "is shown as a usage bar in the console", Z.ai documents the
    /// plan and not the call, and Command Code documents the windows without
    /// the shape that reports them. None can ever carry a URL, and without
    /// somewhere to say so the next person re-runs the same five searches. Where a mapping
    /// cannot be checked against a reference, its fixture is the whole of
    /// the check — which is worth stating in the file that carries it.
    @Test("An uncited mapping says whether a reference exists at all")
    func uncitedMappingsExplainThemselves() throws {
        let undocumented = ["opencode", "copilot", "minimax", "zai", "commandcode"]
        for id in undocumented {
            let descriptor = try #require(quotaDescriptors.first { $0.id == id },
                                          Comment(rawValue: "\(id) no longer ships"))
            #expect(descriptor.quota?.documentation == nil,
                    Comment(rawValue: "\(id) now cites a reference — move it out of this list"))
            let note = descriptor.note ?? ""
            #expect(note.lowercased().contains("published nowhere"),
                    Comment(rawValue: "\(id) has no citation and does not say why"))
            #expect(note.contains("2026-"),
                    Comment(rawValue: "\(id) does not say when that was last checked"))
        }
    }

    /// And the ones that do cite a reference are not in that list, or "we
    /// checked and there is nothing" would be a way of not checking.
    @Test("A cited mapping is not also excused")
    func citedMappingsAreNotExcused() throws {
        var cited = 0
        for descriptor in quotaDescriptors {
            guard descriptor.quota?.documentation != nil else { continue }
            cited += 1
            let note = descriptor.note ?? ""
            #expect(!note.lowercased().contains("published nowhere"),
                    Comment(rawValue: "\(descriptor.id) both cites a reference and says "
                            + "there is none"))
        }
        #expect(cited >= 5, Comment(rawValue: "only \(cited) mappings cite a reference"))
    }

    /// The partition is total.
    ///
    /// Every quota mapping is either checked against a published shape or
    /// recorded as having none to check against. A new one that is neither
    /// is the case this exists to catch: it would ship looking exactly like
    /// the five that were verified, and nothing would say otherwise.
    @Test("Every quota mapping is either cited or excused, and nothing is neither")
    func everyMappingHasAPosition() {
        var cited: [String] = [], excused: [String] = [], neither: [String] = []
        for descriptor in quotaDescriptors {
            let note = (descriptor.note ?? "").lowercased()
            if descriptor.quota?.documentation != nil { cited.append(descriptor.id) }
            else if note.contains("published nowhere") { excused.append(descriptor.id) }
            else { neither.append(descriptor.id) }
        }
        #expect(neither.isEmpty,
                Comment(rawValue: "\(neither.sorted().joined(separator: ", ")) neither names a "
                        + "reference nor records that there is none"))
        #expect(cited.count + excused.count == quotaDescriptors.count)
        // And both halves are populated, or the rule is being satisfied by
        // putting everything in one of them.
        #expect(cited.count >= 5, Comment(rawValue: "only \(cited.count) are cited"))
        #expect(excused.count >= 5, Comment(rawValue: "only \(excused.count) are excused"))
    }

    /// The README states the partition, and the partition is checked. A
    /// number in prose is a second number unless something compares them —
    /// and this one is the claim a reader would most reasonably rely on when
    /// deciding whether to trust a figure the app shows them.
    @Test("The README's account of how mappings were checked is the real one")
    func readmeMatchesTheProvenance() throws {
        let readme = try SourceText.read("README.md")
        let cited = quotaDescriptors.filter { $0.quota?.documentation != nil }.count
        let total = quotaDescriptors.count
        #expect(readme.contains("Of the ten"),
                "the README no longer says how many providers are described by a file")
        #expect(total == 10, Comment(rawValue: "\(total) quota providers ship"))
        #expect(cited == 5, Comment(rawValue: "\(cited) of them cite a published schema"))
        #expect(readme.contains("five were compared field by field"),
                Comment(rawValue: "the README does not state that \(cited) were compared"))
        #expect(readme.contains("The other five"),
                "the README does not account for the ones with no published schema")
        // And the provider count in the features list.
        #expect(readme.contains("17 providers"),
                Comment(rawValue: "the README states a provider count other than "
                        + "\(ProviderRegistry.all.count)"))
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

    /// `CREDIT_LIMIT` stood here until its unit semantics were established
    /// and the mapping learned to read it. The window that exercises this now
    /// is one nothing claims to know, which is what the test was always
    /// about — a name being repeated back, not that particular name.
    @Test("Window names the mapping does not know are reported back")
    func unknownWindowsAreNamed() throws {
        let zai = try provider("zai")
        let reply: [String: Any] = ["data": ["limits": [
            ["type": "MYSTERY_LIMIT", "unit": 3, "percentage": 40],
            ["type": "MYSTERY_LIMIT", "unit": 6, "percentage": 12]]]]
        do {
            _ = try zai.makeSnapshot(reply)
            Issue.record("a reply with no readable window produced a snapshot")
        } catch let error as ProviderError {
            let text = "\(error)"
            #expect(text.contains("MYSTERY_LIMIT"),
                    Comment(rawValue: "the message does not say what it saw: \(text)"))
        }
    }

    /// And the window that used to stand for "unknown" is read now, because
    /// a plan billing in credits reports the same three rolling windows under
    /// a different type. A Z.ai GLM Coding Lite account saw an empty bar.
    @Test("A plan that bills in credits reports the same windows")
    func creditPlansAreRead() throws {
        let zai = try provider("zai")
        let reply: [String: Any] = ["data": ["limits": [
            ["type": "CREDIT_LIMIT", "unit": 3, "percentage": 40],
            ["type": "CREDIT_LIMIT", "unit": 6, "percentage": 12]]]]
        let snapshot = try zai.makeSnapshot(reply)
        #expect(snapshot.gauges.map(\.id) == ["CREDIT_LIMIT-3", "CREDIT_LIMIT-6"],
                Comment(rawValue: "a credit plan produced \(snapshot.gauges.map(\.id))"))
        // The same windows, so the same labels a token plan would show.
        #expect(snapshot.gauges.map(\.title) == ["Session (5 hours)", "Weekly"])
        #expect(snapshot.gauges.map(\.badge) == ["5H", "7D"])
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
