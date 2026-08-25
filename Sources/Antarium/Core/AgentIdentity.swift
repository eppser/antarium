import Foundation

/// Stable identity for an observed logical session. Process ids are runtime
/// attachment details and are used only when a harness exposes no durable
/// session or project evidence.
enum AgentIdentity {
    static func local(harness: String, sessionID: String?, cwd: String,
                      pid: Int32?, fallback: String? = nil) -> String {
        let project = cwd.isEmpty
            ? ""
            : URL(fileURLWithPath: cwd).standardizedFileURL.path
        if let sessionID, !sessionID.isEmpty {
            return "\(harness)-session-\(digest("\(sessionID)|\(project)"))"
        }
        if !project.isEmpty {
            let extra = fallback.map { "|\($0)" } ?? ""
            return "\(harness)-project-\(digest(project + extra))"
        }
        if let fallback, !fallback.isEmpty {
            return "\(harness)-record-\(digest(fallback))"
        }
        return "\(harness)-process-\(pid.map(String.init) ?? "unknown")"
    }

    private static func digest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
