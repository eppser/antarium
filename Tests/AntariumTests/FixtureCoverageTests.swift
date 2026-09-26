import Foundation
import Testing
@testable import Antarium

/// Fixtures and the descriptors they belong to, in both directions.
///
/// A descriptor without a fixture is already checked: there is a test saying
/// every descriptor provider has one. The other direction was not, and it is
/// the one that fails silently. The verifier walks the *descriptors* and
/// checks each one's fixture, so a fixture no descriptor names is never run
/// — it sits in the repository looking like coverage and is executed by
/// nothing. Rename a harness and its fixture becomes exactly that.
///
/// This matters most for the five providers whose mapping cannot be compared
/// against a published schema, where the fixture is the whole of the check.
@Suite("Every fixture belongs to something that runs it")
struct FixtureCoverageTests {

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
    }

    private func files(in directory: String) throws -> Set<String> {
        let url = resources.appendingPathComponent(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return Set(names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") })
    }

    private var descriptors: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    @Test("There are fixtures and descriptors to compare")
    func thereIsSomethingToCompare() throws {
        #expect(try files(in: "quota-fixtures").count >= 8)
        #expect(try files(in: "harness-fixtures").count >= 8)
        #expect(descriptors.count >= 20)
    }

    /// A quota fixture is found by the provider's id, so the set of files and
    /// the set of quota providers have to be the same set — not one inside
    /// the other.
    @Test("Quota fixtures and quota providers are the same set")
    func quotaFixturesMatchProviders() throws {
        let onDisk = try files(in: "quota-fixtures")
        let expected = Set(descriptors.filter { $0.quota != nil }.map { "\($0.id).json" })
        #expect(expected.subtracting(onDisk).isEmpty,
                Comment(rawValue: "a quota provider has no fixture, so nothing checks its "
                        + "mapping without an account: "
                        + expected.subtracting(onDisk).sorted().joined(separator: ", ")))
        #expect(onDisk.subtracting(expected).isEmpty,
                Comment(rawValue: "a quota fixture belongs to no provider, so the verifier "
                        + "never runs it: "
                        + onDisk.subtracting(expected).sorted().joined(separator: ", ")))
    }

    /// A session fixture is named by its descriptor rather than found by id,
    /// so the comparison is against what the descriptors actually name.
    @Test("Session fixtures and the descriptors naming them are the same set")
    func sessionFixturesMatchDescriptors() throws {
        let onDisk = try files(in: "harness-fixtures")
        var named: Set<String> = [], namedBy: [String: String] = [:]
        for descriptor in descriptors {
            guard let fixture = descriptor.compatibility?.fixture else { continue }
            let file = fixture.split(separator: "/").last.map(String.init) ?? fixture
            named.insert(file)
            namedBy[file] = descriptor.id
        }
        #expect(named.subtracting(onDisk).isEmpty,
                Comment(rawValue: "a descriptor names a fixture that is not there: "
                        + named.subtracting(onDisk).sorted()
                            .map { "\($0) (\(namedBy[$0] ?? "?"))" }.joined(separator: ", ")))
        #expect(onDisk.subtracting(named).isEmpty,
                Comment(rawValue: "a session fixture no descriptor names, so nothing replays "
                        + "it: " + onDisk.subtracting(named).sorted().joined(separator: ", ")))
    }

    /// And a quota fixture is reached only through a descriptor's id, which
    /// is why an orphan is never replayed — not an opinion about the
    /// verifier but the lookup itself.
    @Test("A quota fixture is found by a descriptor's id and no other way")
    func fixturesAreReachedByID() throws {
        let known = try #require(descriptors.first { $0.quota != nil },
                                 "no quota provider ships")
        #expect(QuotaFixture.fixtureURL(for: known.id, in: AppResources.bundle) != nil,
                Comment(rawValue: "\(known.id) ships a fixture the lookup cannot find"))
        // A file that exists under a name no descriptor carries is reachable
        // by nothing: the lookup takes an id, and the ids come from the
        // descriptors.
        #expect(QuotaFixture.fixtureURL(for: "no-such-provider", in: AppResources.bundle) == nil,
                "the lookup found a fixture for a provider that does not exist")
    }
}
