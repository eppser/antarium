import AppKit

/// Optional audio cues, off by default.
///
/// Uses the sounds macOS already ships — nothing is bundled, so these match
/// whatever the user's system alert volume is set to and never surprise anyone
/// with an unfamiliar noise.
enum Sounds {
    enum Event: String, CaseIterable {
        case agentStopped, budgetCritical, quotaReset

        var title: String {
            switch self {
            case .agentStopped:   return "An agent finishes a task"
            case .budgetCritical: return "Quota nearly spent"
            case .quotaReset:     return "Quota window resets"
            }
        }
        /// Deliberately quiet defaults: a tick, a low note, a soft purr.
        /// Nothing here should make you jump.
        var defaultSound: String {
            switch self {
            case .agentStopped:   return "Tink"
            case .budgetCritical: return "Submarine"
            case .quotaReset:     return "Purr"
            }
        }
        /// Whatever the config names, falling back to the default. Any of the
        /// sounds in /System/Library/Sounds is valid.
        var systemSound: String {
            let chosen = Config.string("soundName.\(rawValue)") ?? ""
            return chosen.isEmpty ? defaultSound : chosen
        }
        var settingsKey: String { "sound.\(rawValue)" }
    }

    /// Every sound macOS ships, plus anything the user dropped in their own
    /// Sounds folder. Named, not paths — that is what `NSSound(named:)` wants.
    static let available: [String] = {
        var names: Set<String> = []
        for directory in ["/System/Library/Sounds",
                          NSHomeDirectory() + "/Library/Sounds"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                let name = (file as NSString).deletingPathExtension
                if NSSound(named: name) != nil { names.insert(name) }
            }
        }
        return names.sorted()
    }()

    static func setSound(_ event: Event, _ name: String) {
        Config.set("soundName.\(event.rawValue)", name)
    }

    static func isEnabled(_ event: Event) -> Bool { Config.bool(event.settingsKey) ?? false }
    static func setEnabled(_ event: Event, _ on: Bool) { Config.set(event.settingsKey, on) }

    static func play(_ event: Event) {
        guard isEnabled(event) else { return }
        // An unknown name would silently play nothing; fall back so a typo in
        // the config never means a missing alert.
        (NSSound(named: event.systemSound) ?? NSSound(named: event.defaultSound))?.play()
    }

    /// For the settings panel: play it once regardless of the toggle, so you
    /// can hear what you're turning on.
    static func preview(_ event: Event) { NSSound(named: event.systemSound)?.play() }
}
