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
