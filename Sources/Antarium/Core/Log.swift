import Foundation

/// A development log you can read after the fact.
///
/// The alternative was NSLog, which goes to the unified log where it is mixed
/// with everything else on the machine and is gone by the time you think to
/// look. This writes a file you can tail, keeps one previous generation, and
/// costs nothing when switched off: every message is an autoclosure, so a
/// `debug` call below the current level never builds its string.
///
/// Level comes from `ANTARIUM_LOG` in the environment, else `logLevel` in
/// config.json, else `warn`. Set it to `off` to write nothing at all.
enum Log {
    enum Level: Int, Comparable, CaseIterable {
        case off = 0, error, warn, info, debug, trace
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var name: String {
            ["off", "error", "warn", "info", "debug", "trace"][rawValue]
        }
        init?(name: String) {
            guard let i = Level.allCases.firstIndex(where: {
                $0.name == name.lowercased()
            }) else { return nil }
            self = Level.allCases[i]
        }
    }

    static let directory = Config.directory.appendingPathComponent("logs")
    static let url = directory.appendingPathComponent("antarium.log")
    private static let previous = directory.appendingPathComponent("antarium.1.log")
    /// Past this, the file rotates. Big enough for a long session, small enough
    /// to open in an editor.
    private static let maxBytes = 4 * 1024 * 1024

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written = 0
    nonisolated(unsafe) private static var resolved: Level?

    static var level: Level {
        lock.lock(); let cached = resolved; lock.unlock()
        if let cached { return cached }
        let found = Level(name: ProcessInfo.processInfo.environment["ANTARIUM_LOG"] ?? "")
            ?? Level(name: Config.string("logLevel") ?? "")
            ?? .warn
        lock.lock(); resolved = found; lock.unlock()
        return found
    }

    /// Called when the setting changes, so a level edit takes effect without a
    /// restart like every other setting.
    static func invalidateLevel() { lock.lock(); resolved = nil; lock.unlock() }

    static func error(_ area: String, _ message: @autoclosure () -> String) {
        write(.error, area, message)
    }
    static func warn(_ area: String, _ message: @autoclosure () -> String) {
        write(.warn, area, message)
    }
    static func info(_ area: String, _ message: @autoclosure () -> String) {
        write(.info, area, message)
    }
    static func debug(_ area: String, _ message: @autoclosure () -> String) {
        write(.debug, area, message)
    }
    static func trace(_ area: String, _ message: @autoclosure () -> String) {
        write(.trace, area, message)
    }

    /// Times a block and logs how long it took. Returns whatever it returns.
    static func timing<T>(_ area: String, _ what: String, _ body: () throws -> T) rethrows -> T {
        guard level >= .debug else { return try body() }
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let text = "\(what) took \(String(format: "%.1f", ms))ms"
            write(.debug, area, { text })
        }
        return try body()
    }

    private static func write(_ at: Level, _ area: String,
                              _ message: () -> String) {
        guard level >= at, at != .off else { return }
        let line = "\(stamp()) \(at.name.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) "
            + "\(area.padding(toLength: 16, withPad: " ", startingAt: 0)) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if handle == nil { openLocked() }
        handle?.write(data)
        written += data.count
        if written > maxBytes { rotateLocked() }
    }

    private static func openLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        written = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
    }

    private static func rotateLocked() {
        try? handle?.close(); handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
        written = 0
        openLocked()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func stamp() -> String { formatter.string(from: Date()) }
}
