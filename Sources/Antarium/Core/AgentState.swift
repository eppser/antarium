import Foundation

/// Decides what state an agent is in, once, for every harness.
///
/// This used to live in six places — Claude's session registry, the descriptor
/// engine, the Cursor reader, the cloud scanner — each with its own idea of what
/// counts as busy. That is how Claude Desktop ended up pulsing green for ever
/// and how a session with no timestamp at all claimed to be working.
///
/// The precedence below is the whole design: **evidence beats inference**. A
/// harness that publishes its own status is always believed over anything we
/// could deduce from file timestamps, and when there is no evidence at all we
/// say "unknown" rather than invent working or waiting status.
enum AgentStateMachine {

    /// What a harness told us about itself, in its own words.
    enum Published: Equatable {
        case working
        case waiting
        case shell
    }

    /// Everything one pass knows about an agent. Fields are ordered by weight.
    struct Evidence: Equatable {
        /// A live process was found for this session.
        var processAlive = true
        /// The agent runs somewhere else; there is no local process to check.
        var remote: String?
        /// The harness states its own status. Believed over any inference.
        var published: Published?
        /// When the transcript last moved. Inference of last resort.
        var lastActivity: Date?
        /// How long a quiet transcript stays "working" before it is "waiting".
        var idleAfter: TimeInterval = 90
        /// The agent is running on a loop of its own. An agent between rounds
        /// looks exactly like one waiting on you, and the difference is the
        /// whole point: one needs you, the other does not.
        var looping = false
    }

    static func state(_ evidence: Evidence, now: Date = Date()) -> AgentRow.State {
        // 1. Somewhere else entirely: a local process check means nothing.
        if let remote = evidence.remote { return .cloud(remote) }

        // 2. No process, no session — whatever the files still say.
        guard evidence.processAlive else { return .ended }

        // 3. The harness's own word.
        switch evidence.published {
        case .working: return .working
        case .waiting: return evidence.looping ? .looping : .waiting
        case .shell:   return .shell
        case nil:      break
        }

        // 4. Inference: a transcript that moved recently is being written to.
        let quiet: AgentRow.State = evidence.looping ? .looping : .waiting
        guard let last = evidence.lastActivity else { return evidence.looping ? .looping : .unobserved }
        let age = now.timeIntervalSince(last)
        guard age.isFinite, age >= 0, evidence.idleAfter.isFinite, evidence.idleAfter >= 0 else {
            return evidence.looping ? .looping : .unobserved
        }
        return age > evidence.idleAfter ? quiet : .working
    }
}
