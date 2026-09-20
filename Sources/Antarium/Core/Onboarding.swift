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
    /// `descriptors` is a parameter so a test can supply stores it knows are
    /// there and stores it knows are not. Reading the real catalog cannot
    /// prove this reads the disk: on a machine where every agent happens to be
    /// installed, claiming they all are looks identical to checking.
    static func harnesses(_ descriptors: [HarnessDescriptor] = HarnessDescriptor.all())
        -> [Finding] {
        var out: [Finding] = []
        for descriptor in descriptors {
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

    /// Workspace managers found on this Mac.
    ///
    /// These host other agents rather than being agents, so they are not rows
    /// and not menu bar items — but Antarium does use them, to send a click to
    /// the pane a session is actually in. Saying nothing about them meant the
    /// one visible effect of having them installed had no explanation.
    ///
    /// Presence is whether the command they are read through resolves. A bare
    /// name is looked up the way the app looks it up, because an application
    /// launched from Finder has a short PATH and "is it on PATH?" has a
    /// different answer there than in a terminal.
    static func workspaces(_ descriptors: [HarnessDescriptor] = HarnessDescriptor.all(),
                           resolve: (String) -> String? = Onboarding.resolveCommand) -> [Finding] {
        descriptors
            .filter { $0.contributesFocusOnly }
            .map { descriptor in
                let command = descriptor.source.command ?? ""
                let found = !command.isEmpty && resolve(command) != nil
                return Finding(id: descriptor.id, name: descriptor.name,
                               detail: found ? "routes clicks to the right pane"
                                             : "not on this Mac",
                               found: found)
            }
            .sorted { ($0.found ? 0 : 1, $0.name) < ($1.found ? 0 : 1, $1.name) }
    }

    /// Where a bare command name lives, for a GUI app's short PATH.
    static func resolveCommand(_ command: String) -> String? {
        if command.contains("/") {
            let path = command.expandingTilde
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let places = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", home + "/.local/bin"]
        return places.map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Splits accounts into the ones worth a row each and the ones worth a
    /// single line naming them.
    ///
    /// Ten providers ship. Giving every unconfigured one a row with its setup
    /// hint filled the first-run panel with things the user has not got, under
    /// a heading that says Antarium is ready — and the hints, being long
    /// enough to be useful, truncated mid-word in the space left for them.
    static func partition(_ accounts: [Finding])
        -> (signedIn: [Finding], connectable: [Finding]) {
        (accounts.filter(\.found), accounts.filter { !$0.found })
    }

    private static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
