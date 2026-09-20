import Foundation

/// Plain-JSON settings at `~/.antarium/config.json`.
///
/// A visible, hand-editable file rather than an opaque preferences plist: it
/// survives restarts and reinstalls, can be copied to another Mac, and is the
/// only way to set values the menu doesn't expose (a custom accent hex, for
/// instance). Writes are atomic, so a crash mid-save can't truncate it.
enum Config {
    /// Resolved once, on first use, which is before anything can read a
    /// setting or a descriptor.
    static let directory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mine = home.appendingPathComponent(".antarium")
        // The app was called SpiceEye until 0.1. Carry an existing install over
        // once rather than starting empty and re-seeding, which would lose
        // every harness the user had edited along with their settings.
        let former = home.appendingPathComponent(".spiceeye")
        let fm = FileManager.default
        if !fm.fileExists(atPath: mine.path), fm.fileExists(atPath: former.path) {
            do { try fm.moveItem(at: former, to: mine) }
            catch { NSLog("Antarium: couldn't move %@ to %@ — %@",
                          former.path, mine.path, error.localizedDescription) }
        }
        return mine
    }()
    static let url = directory.appendingPathComponent("config.json")

    private static let lock = NSLock()
    // All three values are protected by `lock`; the unsafe annotation records
    // that synchronization boundary for Swift's strict concurrency checker.
    nonisolated(unsafe) private static var store: [String: Any] = [:]
    nonisolated(unsafe) private static var stamp = ""
    nonisolated(unsafe) private static var checked = Date.distantPast

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root
    }

    /// Pick the file up again when it has changed underneath us, so an edit
    /// made in a text editor takes effect without a restart. Every read goes
    /// through here, so the check is throttled to once a second and is a single
    /// `stat`; the JSON is re-parsed only when the file actually moved.
    private static func sync(force: Bool = false) {
        lock.lock()
        if !force, checked.timeIntervalSinceNow > -1 { lock.unlock(); return }
        checked = Date()
        let now = FileStamp.of(url)
        if now == stamp, !force { lock.unlock(); return }
        stamp = now
        lock.unlock()
        let root = load()
        lock.lock(); store = root; lock.unlock()
        Log.debug("config", "re-read \(root.count) key(s)")
        Log.invalidateLevel()
    }

    /// Re-read from disk — lets you edit the file and hit Refresh.
    static func reload() { sync(force: true) }

    private static func value(_ key: String) -> Any? {
        sync()
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    static func string(_ key: String) -> String? { value(key) as? String }
    static func int(_ key: String) -> Int? {
        if let v = value(key) as? Int { return v }
        if let v = value(key) as? Double { return Int(v) }
        return nil
    }
    static func double(_ key: String) -> Double? {
        if let v = value(key) as? Double { return v }
        if let v = value(key) as? Int { return Double(v) }
        return nil
    }
    static func bool(_ key: String) -> Bool? { value(key) as? Bool }
    static func doubles(_ key: String) -> [Double]? {
        (value(key) as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
    }
    static func strings(_ key: String) -> [String]? { value(key) as? [String] }
    /// Nested lookup, e.g. `Config.string("kimi", "api_key")`.
    static func string(_ section: String, _ key: String) -> String? {
        (value(section) as? [String: Any])?[key] as? String
    }

    static func set(_ key: String, _ value: Any) {
        // Re-read first. Someone may have edited the file since we last looked,
        // and writing our whole in-memory copy back would silently erase it.
        sync(force: true)
        lock.lock()
        store[key] = value
        let snapshot = store
        lock.unlock()
        save(snapshot)
    }

    private static func save(_ snapshot: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            // Atomic: never leave a half-written config behind.
            try data.write(to: url, options: .atomic)
            // 0600. The file is documented as the place for values the menu
            // does not expose, and that includes provider API keys — see the
            // nested `Config.string("kimi", "api_key")` accessor. Default
            // permissions make it world-readable, which on a shared Mac hands
            // every other account a live credential. Set after the write:
            // an atomic write replaces the inode, taking its mode with it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Our own write is not an edit to pick up on the next read.
            lock.lock(); stamp = FileStamp.of(url); lock.unlock()
        } catch {
            NSLog("Antarium: couldn't write %@ — %@", url.path, error.localizedDescription)
        }
    }

    /// One-time move of anything already in UserDefaults into the file, so an
    /// existing install keeps its choices.
    static func migrateFromUserDefaults() {
        sync()
        lock.lock(); let empty = store.isEmpty; lock.unlock()
        guard empty else { return }
        var next: [String: Any] = [:]
        let d = UserDefaults.standard
        for key in ["meterMode", "palette"] {
            if let v = d.string(forKey: key) { next[key] = v }
        }
        if let agents = d.array(forKey: "enabledAgents") as? [String] { next["enabledAgents"] = agents }
        let minutes = d.integer(forKey: "refreshMinutes")
        if minutes > 0 { next["refreshMinutes"] = minutes }
        guard !next.isEmpty else { return }
        lock.lock(); store = next; lock.unlock()
        save(next)
    }
}
