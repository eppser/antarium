import Foundation
import Testing
@testable import Antarium

/// The two halves of one agent must agree about where it lives.
///
/// `CodexProvider` honoured `CODEX_HOME` — there is a comment in it saying so —
/// and the codex harness read `~/.codex/sessions` regardless. A developer who
/// moves their Codex home saw their account quota and none of their sessions.
/// Each half was correct on its own terms; nothing anywhere compared them, so
/// there was nothing to be wrong.
///
/// This compares them. A native provider that honours a relocation variable and
/// a harness of the same id that reads a session directory must name the same
/// variable, or the harness must read no directory at all.
@Suite("A native provider and its harness agree about relocation")
struct NativeRelocationTests {

    private var harnesses: [String: HarnessDescriptor] {
        Dictionary(uniqueKeysWithValues: HarnessCLI.bundledDescriptors().map { ($0.id, $0) })
    }

    /// Ids that read the same directory as another agent's, and so must follow
    /// the same variable. Data, because it is a fact about the agents rather
    /// than something derivable: the desktop app and the CLI share `~/.codex`.
    static let sharedDirectories: [String: [String]] = ["codex": ["codex-desktop"]]

    @Test("Every native relocation variable is named by the harness that reads its directory")
    func halvesAgree() throws {
        var compared = 0
        for provider in ProviderRegistry.nativeProviders {
            guard let variable = provider.relocationVariable else { continue }
            for id in [provider.id] + (Self.sharedDirectories[provider.id] ?? []) {
                guard let harness = harnesses[id] else { continue }
                // A harness that reads no directory has nothing to relocate.
                guard !harness.source.path.isEmpty else { continue }
                compared += 1
                let declared = harness.source.relocate?.env
                #expect(declared == variable,
                        Comment(rawValue: "\(provider.displayName) honours \(variable) and the "
                                + "\(id) harness names \(declared ?? "nothing") — a relocated "
                                + "home would show its quota and none of its sessions"))
            }
        }
        #expect(compared >= 2,
                Comment(rawValue: "\(compared) pairs were compared, so this asserts little"))
    }

    /// And a native provider that honours nothing is not quietly assumed to.
    /// The point of the list is that it is short and deliberate.
    @Test("Only the providers that document a relocation declare one")
    func onlyDocumentedOnes() {
        let declared = ProviderRegistry.nativeProviders
            .filter { $0.relocationVariable != nil }
            .map(\.id)
            .sorted()
        #expect(declared == ["codex", "gemini", "grok"],
                Comment(rawValue: "native providers declaring a relocation: \(declared)"))
    }

    /// A variable named by a provider must look like one, since the whole value
    /// of the comparison is that the two strings are the same string.
    @Test("Every declared variable is an environment variable's name")
    func namesLookLikeNames() {
        for provider in ProviderRegistry.nativeProviders {
            guard let variable = provider.relocationVariable else { continue }
            #expect(!variable.isEmpty)
            #expect(variable == variable.uppercased(),
                    Comment(rawValue: "\(variable) is not the shape of an environment variable"))
            #expect(!variable.contains(" "))
        }
    }

    /// The other direction: a harness declaring a relocation whose agent has a
    /// native provider must not name a *different* variable. This is the same
    /// claim as `halvesAgree` approached from the descriptors, and it catches the
    /// case that one misses — a harness inventing a variable for an agent whose
    /// native half honours none.
    @Test("No harness invents a relocation its agent's native half does not honour")
    func noInventedVariables() {
        let native = Dictionary(uniqueKeysWithValues:
            ProviderRegistry.nativeProviders.map { ($0.id, $0.relocationVariable) })
        for descriptor in HarnessCLI.bundledDescriptors() {
            guard let declared = descriptor.source.relocate?.env else { continue }
            // Only ids that also have a native provider are constrained; a
            // harness-only agent is free to declare what its vendor documents.
            var owners = [descriptor.id]
            for (provider, shared) in Self.sharedDirectories where shared.contains(descriptor.id) {
                owners.append(provider)
            }
            let known = owners.compactMap { native[$0] ?? nil }
            guard !known.isEmpty else { continue }
            #expect(known.contains(declared),
                    Comment(rawValue: "the \(descriptor.id) harness names \(declared) and its "
                            + "native half honours \(known.joined(separator: ", "))"))
        }
    }

    /// And the shared-directory list is not stale: every id in it ships, and
    /// names a harness rather than a provider.
    @Test("The shared-directory list names harnesses that ship")
    func sharedListIsCurrent() {
        let ids = Set(HarnessCLI.bundledDescriptors().map(\.id))
        let providers = Set(ProviderRegistry.nativeProviders.map(\.id))
        for (provider, shared) in Self.sharedDirectories {
            #expect(providers.contains(provider),
                    Comment(rawValue: "\(provider) is not a native provider"))
            for id in shared {
                #expect(ids.contains(id), Comment(rawValue: "\(id) no longer ships"))
            }
        }
    }
}
