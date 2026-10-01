import Foundation

/// Where a command named without a path actually lives.
///
/// A menu bar app launched from Finder inherits no shell environment, so its
/// PATH is short — often just `/usr/bin:/bin:/usr/sbin:/sbin`. Every place a
/// coding agent is normally installed has to be tried explicitly, and that
/// includes `~/.local/bin`: Claude's own native installer puts its binary
/// there, as do `uv tool install` and `pipx`.
///
/// One list, because there were three. They had drifted. Onboarding and Focus
/// looked in `~/.local/bin`; the quota providers' copy did not, so a
/// credential command installed there could be run by a click and reported
/// "not signed in" by the bar — the agent was installed, and the thing whose
/// job is to notice said no. Focus's copy even carried a comment claiming it
/// was "the same list the quota providers use".
enum CommandPath {
    /// Tried after whatever PATH the app inherited, in this order.
    static let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// The inherited PATH is a parameter so the places this adds can be
    /// checked on their own. Asserting against the whole list only proves the
    /// developer's shell happens to include them — which is exactly how the
    /// first version of that test passed with `~/.local/bin` deleted.
    static func places(inheriting path: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.split(separator: ":").map(String.init)
            + fallbacks + [home + "/.local/bin"]
    }

    static var places: [String] {
        places(inheriting: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    /// The executable a descriptor's command names, or nil when it is not
    /// installed. A command containing a slash is a path and is taken as one;
    /// a bare name is looked up.
    static func resolve(_ command: String, in places: [String]? = nil) -> String? {
        guard !command.isEmpty, !command.contains("\0") else { return nil }
        if command.contains("/") {
            let path = command.expandingTilde
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return (places ?? Self.places)
            .map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
