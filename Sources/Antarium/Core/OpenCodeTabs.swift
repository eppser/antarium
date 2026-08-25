import Foundation

/// The sessions OpenCode actually has open, read from its desktop state.
///
/// Its database keeps every session ever created and records nothing about a
/// tab being closed, so reading it alone reports conversations the user shut
/// days ago — and a session's timestamp cannot tell the two apart, because a
/// closed tab's last message is as real as an open one's.
///
/// The window state does know. `opencode.window.<id>.dat` holds a `tabs` array
/// of what is open right now, alongside a `tabs.closed` list of what was
/// dismissed; `tabs.info` carries each tab's title and directory. One file per
/// window, so every window is read.
///
/// Fails open. If the directory is missing, or a release renames any of this,
/// the answer is nil and the caller falls back to reporting recent sessions
/// rather than showing an empty list.
enum OpenCodeTabs {
    static let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai.opencode.desktop")

    /// Session ids with a tab open, or nil when the state cannot be read.
    static func open(in directory: URL = stateDirectory) -> Set<String>? {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("opencode.window.") && $0.hasSuffix(".dat") } ?? []
        guard !names.isEmpty else { return nil }

        var open: Set<String> = []
        var readAny = false
        for name in names {
            guard let data = try? Data(contentsOf: directory
                    .appendingPathComponent(name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // The value is JSON in its own right, stored as a string.
            guard let raw = root["tabs"] else { continue }
            let tabs: [Any]
            if let list = raw as? [Any] {
                tabs = list
            } else if let text = raw as? String,
                      let nested = try? JSONSerialization.jsonObject(
                          with: Data(text.utf8)) as? [Any] {
                tabs = nested
            } else { continue }
            readAny = true
            for case let tab as [String: Any] in tabs
            where (tab["type"] as? String) == "session" {
                if let id = tab["sessionId"] as? String { open.insert(id) }
            }
        }
        // A window with no session tabs is a real state, so an empty set is
        // only meaningful if at least one file parsed.
        Log.debug("opencode", readAny ? "\(open.count) tab(s) open" : "no window state readable")
        return readAny ? open : nil
    }
}
