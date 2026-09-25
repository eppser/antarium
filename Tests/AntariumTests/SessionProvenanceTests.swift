import Foundation
import Testing
@testable import Antarium

/// When each session source's records were last read against something that
/// is not this repository.
///
/// A session fixture is written from the map it tests. It proves the map is
/// applied and cannot notice that the records mean something other than the
/// map assumes — which is not a shortcoming of the fixtures, it is what a
/// fixture is. Two agents were over-reporting tokens behind green ones:
/// Claude repeats a reply across content blocks and every record carries the
/// whole of its usage, and Codex re-emits an event verbatim. Neither was
/// found by a fixture. Both were found by reading what another tool had to
/// handle in order to read the same files.
///
/// So the sources that carry token figures are listed here in two groups:
/// those whose records have been read that way, and those whose have not. The
/// second list is the point. An absent date is invisible; a name on a list is
/// a thing somebody can pick up.
@Suite("Every session source says whether its records have been read")
struct SessionProvenanceTests {

    /// Sources whose records nobody has yet compared with another reader of
    /// the same files. Not a failure — most of these are small tools with no
    /// second implementation to compare against — but written down, because
    /// the two defects above were in this state and nothing said so.
    static let unread: Set<String> = ["openclaw", "pi", "vscode"]

    private var mapsTokens: [HarnessDescriptor] {
        HarnessCLI.bundledDescriptors().filter {
            let map = $0.fields
            return map.inputTokens != nil || map.totalTokens != nil || map.cost != nil
        }
    }

    @Test("There are token-mapping sources to say anything about")
    func thereAreSubjects() {
        #expect(mapsTokens.count >= 7,
                Comment(rawValue: "only \(mapsTokens.count) sources map a token figure"))
    }

    @Test("Each token-mapping source is either dated or named as unread")
    func everySourceIsAccountedFor() {
        for descriptor in mapsTokens {
            let dated = descriptor.source.checkedAt != nil
            let listed = Self.unread.contains(descriptor.id)
            #expect(dated != listed,
                    Comment(rawValue: "\(descriptor.id) is "
                            + (dated && listed ? "both dated and listed as unread"
                                               : "neither dated nor listed as unread")))
        }
    }

    @Test("A date that is recorded is a date")
    func datesParse() throws {
        var checked = 0
        for descriptor in mapsTokens {
            guard let day = descriptor.source.checkedAt else { continue }
            let parsed = try #require(Self.day.date(from: day),
                                      Comment(rawValue: "\(descriptor.id) reads \(day)"))
            #expect(parsed <= Date().addingTimeInterval(86_400),
                    Comment(rawValue: "\(descriptor.id) was read on \(day), which is ahead"))
            checked += 1
        }
        #expect(checked >= 3, Comment(rawValue: "only \(checked) sources carry a date"))
    }

    /// The unread list names sources that exist and map figures, so it cannot
    /// be padded with anything to make the count look better.
    @Test("Every name on the unread list is a source that maps figures")
    func unreadNamesAreReal() {
        let ids = Set(mapsTokens.map(\.id))
        for name in Self.unread {
            #expect(ids.contains(name),
                    Comment(rawValue: "\(name) is listed as unread and maps no token figure"))
        }
    }

    /// And the ones that were read are the ones that were wrong, which is
    /// the argument for reading the rest. Kimi joined them the day it was
    /// read: it was summing a running total alongside the turns that total
    /// was already the sum of.
    @Test("The sources found to be over-reporting are among the dated ones")
    func theFoundOnesAreDated() throws {
        for id in ["codex", "codex-desktop"] {
            let descriptor = try #require(mapsTokens.first { $0.id == id },
                                          Comment(rawValue: "\(id) no longer maps figures"))
            #expect(descriptor.source.checkedAt != nil,
                    Comment(rawValue: "\(id) was corrected and carries no date for it"))
            #expect(descriptor.fields.skipRepeatedUsage == true,
                    Comment(rawValue: "\(id) no longer skips the records it repeats"))
        }
        let kimi = try #require(mapsTokens.first { $0.id == "kimi" })
        #expect(kimi.source.checkedAt != nil, "kimi was corrected and carries no date for it")
        #expect(kimi.fields.skipUsageWhere?["usageScope"] == "session",
                "kimi no longer refuses the cumulative records it used to add")
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
