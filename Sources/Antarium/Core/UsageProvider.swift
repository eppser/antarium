import Foundation

/// Everything a menu bar item needs from a coding agent.
///
/// Native implementations are reserved for authentication flows that require
/// control logic. Ordinary JSON usage endpoints belong in a harness `quota`
/// block and are materialized by `DescriptorProvider`.
protocol UsageProvider: AnyObject, Sendable {
    /// Stable key, persisted in preferences.
    var id: String { get }
    var displayName: String { get }
    /// Cheap and synchronous — no network, no Keychain prompt.
    var isConfigured: Bool { get }
    /// What the user should do when `isConfigured` is false.
    var setupHint: String { get }
    /// True when this implementation has been checked against the real
    /// service. Unverified providers say so in their dropdown rather than
    /// quietly showing numbers nobody has confirmed.
    var isVerified: Bool { get }
    func fetch() async throws -> Snapshot
    /// Shell command that signs this agent in again, offered in the menu when
    /// the credential is the thing that failed. Nil where re-authenticating is
    /// not a command the user can run.
    var signInCommand: String? { get }
}

extension UsageProvider {
    var signInCommand: String? { nil }
}

enum ProviderRegistry {
    /// Written in Swift because their auth is control flow, not data: Claude
    /// goes through the Keychain and refreshes OAuth tokens.
    ///
    /// Kimi is not here: its usage endpoint lives on a local server that is only
    /// up while Kimi runs, so the bar spent most of its time reporting nothing.
    /// Its sessions are still read — that is the `kimi` harness, unaffected.
    private static let native: [UsageProvider] = [
        ClaudeCodeProvider(),
        CodexProvider(),
    ]

    /// Providers contributed as config. Built once and kept, so a provider's
    /// session and cached state survive a re-read of the registry.
    nonisolated(unsafe) private static var fromDescriptors:
        [String: (signature: String, provider: DescriptorProvider)] = [:]
    private static let lock = NSLock()

    /// Native first. A descriptor never displaces a native provider — that
    /// would let a config file silently replace a tested auth path — so a
    /// descriptor's `quota` counts only for an agent Swift doesn't already
    /// cover, which is exactly the case contributors are in.
    static var all: [UsageProvider] {
        native + providers(from: HarnessDescriptor.all())
    }

    /// Synchronizes providers with current descriptor values. Identity is
    /// retained only while the complete descriptor is unchanged.
    static func providers(from descriptors: [HarnessDescriptor]) -> [UsageProvider] {
        let taken = Set(native.map(\.id))
        var added: [UsageProvider] = []
        var live = Set<String>()
        for descriptor in descriptors
        where descriptor.quota != nil && !taken.contains(descriptor.id) {
            live.insert(descriptor.id)
            let signature = descriptorSignature(descriptor)
            lock.lock()
            let provider: DescriptorProvider?
            if let cached = fromDescriptors[descriptor.id],
               cached.signature == signature {
                provider = cached.provider
            } else {
                provider = DescriptorProvider(descriptor)
                if let provider {
                    fromDescriptors[descriptor.id] = (signature, provider)
                }
            }
            lock.unlock()
            if let provider { added.append(provider) }
        }
        lock.lock()
        fromDescriptors = fromDescriptors.filter { live.contains($0.key) }
        lock.unlock()
        return added.sorted { $0.id < $1.id }
    }

    private static func descriptorSignature(_ descriptor: HarnessDescriptor) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(descriptor) else { return "" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func provider(id: String) -> UsageProvider? { all.first { $0.id == id } }

    /// Agents shown in the menu bar, in registry order so the items keep a
    /// stable left-to-right ordering between launches.
    static var enabled: [UsageProvider] {
        let on = Settings.enabledAgents
        let result = all.filter { on.contains($0.id) }
        return result.isEmpty ? [all[0]] : result
    }
}
