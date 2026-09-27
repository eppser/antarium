import Foundation
import Testing
@testable import Antarium

/// A verification claim has to say what it was verified against.
///
/// `QuotaProvenanceTests` holds every descriptor mapping to that: it either cites
/// a published schema in `quota.documentation` or records "published nowhere" with
/// a date, and a mapping that is neither fails. It reads `quotaDescriptors`, so the
/// seven providers written in Swift were outside it — and the flagship was the one
/// that showed why. `ClaudeCodeProvider` declared `isVerified = true`, which the
/// settings list and the dropdown both surface, and its file said nothing about
/// what that was verified against. Nothing could re-check it and nothing could date
/// it.
///
/// This is the fourth defect found in the same shape: a rule applied to the
/// descriptors and not to the Swift beside them. The others were the Codex numeric
/// helper that never got `FieldPath`'s boolean guard, the `--detect-agents` wording
/// for a presence-only harness, and the native setup hints.
///
/// Source-read, as `LaunchedCommandsTests` and `SettingsDirectoryPermissionTests`
/// already are here: the claim is about what the file records, so the file is what
/// is read.
@Suite("A native provider claiming verification records what against")
struct NativeProvenanceTests {

    private var providersDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/Providers")
    }

    /// The file each native provider is written in, by id.
    private func sources() throws -> [(id: String, text: String)] {
        var out: [(String, String)] = []
        for provider in ProviderRegistry.nativeProviders {
            // The type's own file, found by the id it declares rather than by a
            // table that would need keeping in step.
            let candidates = try FileManager.default
                .contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            var found: String?
            for url in candidates.sorted(by: { $0.path < $1.path }) {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("let id = \"\(provider.id)\"") { found = text; break }
            }
            out.append((provider.id, try #require(found,
                Comment(rawValue: "no file in Providers declares id \"\(provider.id)\""))))
        }
        return out
    }

    /// The claim. A provider that says its figures are verified must say against
    /// what, and when — a sentence a later reader can act on.
    @Test("Every verified native provider records its evidence and a date")
    func verifiedProvidersRecordEvidence() throws {
        var examined = 0
        for (id, text) in try sources() {
            guard let provider = ProviderRegistry.nativeProviders.first(where: { $0.id == id }),
                  provider.isVerified else { continue }
            examined += 1
            let phrases = ["verified against", "cross-read", "re-read", "checked 20"]
            let lines = text.split(separator: "\n").map { $0.lowercased() }
            #expect(lines.contains(where: { line in phrases.contains(where: line.contains) }),
                    Comment(rawValue: "\(id) claims isVerified and records no evidence — the "
                            + "descriptors are held to quota.documentation for this reason"))
            // The date has to sit with the evidence. Asked of the whole file, this
            // passed on `anthropic-beta: oauth-2025-04-20` — a protocol version
            // that merely looks like a date, in a provider whose verification was
            // in fact undated. A test satisfied by a coincidence is worse than no
            // test, because it reports the thing as done.
            let dated = lines.contains { line in
                phrases.contains(where: line.contains)
                    && line.range(of: #"20\d\d-\d\d-\d\d"#,
                                  options: .regularExpression) != nil
            }
            #expect(dated,
                    Comment(rawValue: "\(id) records evidence with no date beside it, so nothing "
                            + "can go stale visibly"))
        }
        #expect(examined == 3,
                Comment(rawValue: "\(examined) native providers claim verification"))
    }

    /// And the unverified ones are not quietly assumed. The list is short and
    /// deliberate, the same way the relocation list is.
    @Test("Only the three providers checked against a live account claim verification")
    func onlyThreeClaimIt() {
        let verified = ProviderRegistry.nativeProviders
            .filter(\.isVerified).map(\.id).sorted()
        #expect(verified == ["claude-code", "codex", "cursor"],
                Comment(rawValue: "claiming verification: \(verified)"))
    }

    /// An unverified provider says so to the user rather than staying silent, which
    /// is what the claim is worth anything against.
    @Test("An unverified provider is surfaced as unverified")
    func unverifiedIsSurfaced() {
        let unverified = ProviderRegistry.nativeProviders.filter { !$0.isVerified }
        #expect(!unverified.isEmpty, "nothing is unverified, so this asserts nothing")
        for provider in unverified {
            #expect(!provider.isVerified)
            // The dropdown appends "— unverified integration" from exactly this,
            // and `Diagnostics` prints it; both read the same flag.
            #expect(provider.setupHint.isEmpty == false,
                    Comment(rawValue: "\(provider.id) is unverified and offers no way in"))
        }
    }

    /// Claude Code specifically, because it is the one that was missing and the one
    /// most people have.
    @Test("Claude Code records the cross-read that its verification rests on")
    func claudeRecordsIt() throws {
        let text = try #require(try sources().first { $0.id == "claude-code" }?.text)
        #expect(text.contains("api.anthropic.com/api/oauth/usage"),
                "the endpoint it was verified against is not named")
        #expect(text.lowercased().contains("cross-read"),
                "the cross-read is not recorded")
        #expect(text.contains("spend") && text.contains("extra_usage"),
                "the two fields read and deliberately not acted on are not recorded")
    }
}
