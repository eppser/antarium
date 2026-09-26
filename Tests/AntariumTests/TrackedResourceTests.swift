import Foundation
import Testing
@testable import Antarium

/// What the repository actually contains, as against what this machine has.
///
/// One directory of resources is deliberately not distributed:
/// `Resources/marks/*.png` is third-party application artwork, derived
/// locally by a script and excluded by .gitignore. Everything else under
/// `Resources` ships.
///
/// The distinction is easy to lose and expensive when it is. A test that
/// asked which marks existed passed on a developer's machine and failed in
/// every clean checkout — and because the mutation runner works in a
/// throwaway checkout, it then reported every mutation as caught. The suite
/// graded itself against a baseline that was already failing.
@Suite("The repository has what the tests read")
struct TrackedResourceTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Resource directories that are entirely in the repository. A test may
    /// read these and get the same answer anywhere.
    private let distributed = ["harnesses", "harness-fixtures", "quota-fixtures", "logo"]

    /// And the one that is not, with the reason it is not.
    private let local = "marks"

    @Test("Every distributed resource directory has files in it",
          arguments: ["harnesses", "harness-fixtures", "quota-fixtures", "logo"])
    func distributedDirectoriesArePopulated(directory: String) throws {
        let url = root.appendingPathComponent("Resources/\(directory)")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { !$0.hasPrefix(".") }
        #expect(!names.isEmpty,
                Comment(rawValue: "Resources/\(directory) is empty, so anything reading it "
                        + "proves nothing"))
    }

    /// The ignore rules name exactly one resource. A second one added later
    /// is a decision to make deliberately: anything under it is present for
    /// whoever generated it and absent for everybody else, so a test reading
    /// it passes here and fails there.
    @Test("Only the vendor artwork is excluded from the repository")
    func onlyArtworkIsExcluded() throws {
        let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"),
                                encoding: .utf8)
        let rules = ignore.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.contains("Resources/") }
        #expect(rules == ["Resources/\(local)/*.png"],
                Comment(rawValue: "the resources excluded from the repository are now "
                        + "\(rules) — anything reading one of these sees a different answer "
                        + "on a machine that did not generate it"))
    }

    /// And the excluded one is excluded for a stated reason, in the place
    /// somebody looking at the empty directory would look.
    @Test("The excluded directory explains itself")
    func artworkIsExplained() throws {
        let readme = try String(
            contentsOf: root.appendingPathComponent("Resources/\(local)/README.md"),
            encoding: .utf8)
        #expect(readme.lowercased().contains("not distributed"))
        #expect(readme.lowercased().contains("ignored by git"))
        // The fallback the app uses instead is named, so the reader knows
        // what happens when the directory is empty — which is the normal case.
        #expect(readme.lowercased().contains("fallback"))
    }
}
