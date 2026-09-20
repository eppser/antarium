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
        // An isolated settings directory, so first-run behaviour — seeding,
        // agent detection, the onboarding flag — can be exercised for real
        // without touching the settings of whoever is running the test.
        // `homeDirectoryForCurrentUser` deliberately ignores $HOME on macOS,
        // so there is no other way to do it. Absolute paths only: a relative
        // one would follow the working directory somewhere unintended.
        if let override = ProcessInfo.processInfo.environment["ANTARIUM_HOME"],
           override.hasPrefix("/"), !override.contains("\0") {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mine = home.appendingPathComponent(".antarium")
        // The app was called SpiceEye until 0.1. Carry an existing install over
        // once rather than starting empty and re-seeding, which would lose
        // every harness the user had edited along with their settings.
        let former = home.appendingPathComponent(".spiceeye")
        let fm = FileManager.default
        if !fm.fileExists(atPath: mine.path), fm.fileExists(atPath: former.path) {
            do { try fm.moveItem(at: former, to: mine) }
            catch { NSLog("Antarium: previous settings migration failed; no source settings were removed.") }
        }
        return mine
    }()
    static let url = directory.appendingPathComponent("config.json")

    private static let file = ConfigurationFile(url: url, didChange: { Log.invalidateLevel() })
    static var issue: String? { file.issue }
    static func reload() { file.reload(); Log.invalidateLevel() }
    static func string(_ key: String) -> String? { file.string(key) }
    static func int(_ key: String) -> Int? { file.int(key) }
    static func double(_ key: String) -> Double? { file.double(key) }
    static func bool(_ key: String) -> Bool? { file.bool(key) }
    static func doubles(_ key: String) -> [Double]? { file.doubles(key) }
    static func strings(_ key: String) -> [String]? { file.strings(key) }
    static func string(_ section: String, _ key: String) -> String? {
        (file.value(section) as? [String: Any])?[key] as? String
    }
    static func set(_ key: String, _ value: Any) {
        if file.set(key, value) { Log.invalidateLevel() }
    }

    /// One-time move of anything already in UserDefaults into the file, so an
    /// existing install keeps its choices.
    static func migrateFromUserDefaults() {
        var next: [String: Any] = [:]
        let d = UserDefaults.standard
        for key in ["meterMode", "palette"] {
            if let v = d.string(forKey: key) { next[key] = v }
        }
        if let agents = d.array(forKey: "enabledAgents") as? [String] { next["enabledAgents"] = agents }
        let minutes = d.integer(forKey: "refreshMinutes")
        if minutes > 0 { next["refreshMinutes"] = minutes }
        guard !next.isEmpty else { return }
        file.migrateIfEmpty(next)
        Log.invalidateLevel()
    }
}
