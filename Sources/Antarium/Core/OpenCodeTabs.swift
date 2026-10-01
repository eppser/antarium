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
        SessionSelection.openIDs(.init(kind: .jsonFiles, path: directory.path,
            glob: "opencode.window.*.dat", records: "tabs", encodedJSON: true,
            id: "sessionId", filter: ["type": ["session"]]))
    }
}
