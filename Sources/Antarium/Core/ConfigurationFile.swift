import Foundation
import CoreFoundation
import Darwin

/// Bounded, serialized settings persistence. A bad external edit never replaces
/// the last good snapshot, and writes refuse to destroy an unreadable file.
/// The lock covers the complete read/modify/atomic-replace transaction.
final class ConfigurationFile: @unchecked Sendable {
    let url: URL
    static let maximumBytes = 1_048_576
    private let lock = NSLock()
    private var store: [String: Any] = [:]
    private var stamp: String?
    private var checked = -Double.infinity
    private var failure: String?
    private var readable = false
    private let didChange: @Sendable () -> Void
    init(url: URL, didChange: @escaping @Sendable () -> Void = {}) {
        self.url = url; self.didChange = didChange
    }

    var issue: String? { lock.lock(); defer { lock.unlock() }; syncLocked(); return failure }
    func reload() { lock.lock(); defer { lock.unlock() }; syncLocked(force: true) }
    func value(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }; syncLocked(); return store[key]
    }
    func string(_ key: String) -> String? { value(key) as? String }
    func int(_ key: String) -> Int? {
        guard let value = value(key) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        // Preserve JSON Int64 precision before attempting floating conversion.
        if let integer = Int(value.stringValue) { return integer }
        return Int(exactly: value.doubleValue)
    }
    func double(_ key: String) -> Double? { Self.number(value(key)) }
    func bool(_ key: String) -> Bool? {
        guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    func doubles(_ key: String) -> [Double]? {
        guard let values = value(key) as? [Any] else { return nil }
        let numbers = values.compactMap { Self.number($0) }
        return numbers.count == values.count ? numbers : nil
    }
    func strings(_ key: String) -> [String]? { value(key) as? [String] }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    @discardableResult
    func set(_ key: String, _ value: Any) -> Bool {
        lock.lock(); defer { lock.unlock() }
        syncLocked(force: true)
        guard readable else { return false }
        var next = store; next[key] = value
        return saveLocked(next)
    }

    /// Migration is also a single transaction, and cannot overwrite malformed
    /// configuration or a setting saved concurrently by another app component.
    func migrateIfEmpty(_ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        syncLocked(force: true)
        guard readable, store.isEmpty, !values.isEmpty else { return }
        _ = saveLocked(values)
    }

    private func syncLocked(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - checked >= 1 else { return }
        checked = now
        let current = fingerprint()
        guard force || stamp != current else { return }
        do {
            let root = try read()
            guard fingerprint() == current else { throw BoundaryError.changed }
            store = root; stamp = current; readable = true; failure = nil
            didChange()
        } catch {
            stamp = current; readable = false
            failure = "Settings could not be read safely. Your last valid settings are still in use. Fix the configuration file and choose Reload before saving."
        }
    }

    private enum BoundaryError: Error { case invalid, changed }
    private func fingerprint() -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? "missing" : "unavailable" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode)"
    }
    private func read() throws -> [String: Any] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return [:] }
            throw BoundaryError.invalid
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw BoundaryError.invalid }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, min(bytes.count, Self.maximumBytes + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw BoundaryError.invalid }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= Self.maximumBytes else { throw BoundaryError.invalid }
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BoundaryError.invalid }
        return root
    }
    private func saveLocked(_ next: [String: Any]) -> Bool {
        do {
            guard JSONSerialization.isValidJSONObject(next) else { throw BoundaryError.invalid }
            let data = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= Self.maximumBytes else { throw BoundaryError.invalid }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".settings-\(UUID()).tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw BoundaryError.invalid }
            defer { close(fd); unlink(temporary.path) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw BoundaryError.invalid }
                    offset += count
                }
            }
            guard fsync(fd) == 0, fingerprint() == stamp else { throw BoundaryError.changed }
            // rename(2) replaces the destination atomically, so there is
            // deliberately no unlink first: removing the old file would open a
            // window where a crash leaves no settings at all. The difference is
            // unobservable from a test, which is why no mutation records it.
            guard rename(temporary.path, url.path) == 0 else { throw BoundaryError.invalid }
            store = next; stamp = fingerprint(); readable = true; failure = nil
            didChange()
            return true
        } catch {
            failure = "Settings were not saved. The configuration may have changed or be unwritable. Your existing file has been preserved; choose Reload and try again."
            return false
        }
    }
}
