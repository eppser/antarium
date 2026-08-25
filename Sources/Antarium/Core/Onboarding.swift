import Foundation

/// First run, with as little asked of you as possible.
///
/// The user story: *I just installed Antarium. It should already know what I
/// run.* So nothing here is a question. Everything is detected — which agents
/// have sessions on this Mac, which accounts are already signed in, how many
/// agents are running this second — and the only interaction is confirming what
/// it found. The one exception is an account that genuinely needs a sign-in,
/// and even that is offered rather than demanded.
enum Onboarding {

    struct Finding: Identifiable {
        let id: String
        let name: String
        /// Where it was found, or what is missing.
        let detail: String
        let found: Bool
        /// Non-nil when the user could do something about it.
        var hint: String?
    }

    static var hasRun: Bool { Config.bool("onboarded") ?? false }
    static func complete() { Config.set("onboarded", true) }
    static func reset() { Config.set("onboarded", false) }

    /// Which agents leave traces on this Mac. Every agent is a descriptor now,
    /// including the two read natively, so this is one list — appending those
    /// two separately listed them twice.
    static func harnesses() -> [Finding] {
        var out: [Finding] = []
        for descriptor in HarnessDescriptor.all() {
            // A quota-only agent — Copilot — declares no session store, so
            // there is nothing on disk to look for. It used to fail the
            // existence check and get listed as "not installed here" directly
            // under its own "signed in" row in the quota section.
            guard !descriptor.source.path.isEmpty else { continue }
            let path = descriptor.source.path.expandingTilde
            let found = FileManager.default.fileExists(atPath: path)
            out.append(Finding(id: descriptor.id, name: descriptor.name,
                               detail: found ? shorten(path) : "not on this Mac",
                               found: found))
        }
        return out.sorted { ($0.found ? 0 : 1, $0.name) < ($1.found ? 0 : 1, $1.name) }
    }

    /// Accounts whose quota we can chart. `isConfigured` is documented as cheap
    /// and prompt-free, so this never triggers a Keychain dialog.
    static func accounts(_ providers: [UsageProvider]) -> [Finding] {
        providers.map { provider in
            Finding(id: provider.id, name: provider.displayName,
                    detail: provider.isConfigured ? "signed in" : "not signed in",
                    found: provider.isConfigured,
                    hint: provider.isConfigured ? nil : provider.setupHint)
        }
    }

    private static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
