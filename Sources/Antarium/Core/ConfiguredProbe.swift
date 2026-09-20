import Foundation

/// Memoises "is this agent signed in on this Mac?".
///
/// `UsageProvider.isConfigured` is documented as cheap and synchronous, and it
/// is read from inside SwiftUI bodies — the settings list draws a setup hint
/// from it for every provider on every update. Two of the native answers are
/// not cheap. Claude's falls through to running `/usr/bin/security` whenever
/// the credentials file is absent, and a subprocess inside a view body pumps
/// the run loop, re-enters the update and takes AttributeGraph down with a
/// precondition failure — the exact hazard `DescriptorProvider` already
/// documents and avoids. Cursor's opens and queries an SQLite database, which
/// is merely wasteful but still I/O per frame.
///
/// Both answers change only when the user signs in or out, so a short memo
/// restores the contract without making the value stale enough to notice.
/// `invalidate()` exists so an in-app sign-in is reflected at once rather than
/// up to `ttl` later.
enum ConfiguredProbe {
    /// Long enough that a burst of view updates costs one probe, short enough
    /// that a sign-in performed in a terminal shows up while the user is still
    /// looking at the window.
    static let ttl: TimeInterval = 30

    private struct Entry { let value: Bool; let at: TimeInterval }
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    /// `compute` runs at most once per `ttl` per key. It is called with the
    /// lock held, which serialises concurrent first probes for the same key —
    /// deliberate, since the alternative is several `security` subprocesses
    /// racing for the same answer.
    static func value(_ key: String,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                      _ compute: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key], now >= entry.at, now - entry.at < ttl {
            return entry.value
        }
        let value = compute()
        entries[key] = Entry(value: value, at: now)
        return value
    }

    /// Forgets one key, or everything. Called after a sign-in.
    static func invalidate(_ key: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let key { entries.removeValue(forKey: key) } else { entries.removeAll() }
    }
}
