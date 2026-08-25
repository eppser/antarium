import Foundation

/// A cheap "has this changed?" signature for a configuration file, or for a
/// directory of them.
///
/// Modification time *and* size, because either alone misses an edit: a script
/// can rewrite a file within the same second, and an edit can leave the length
/// unchanged. A directory's own timestamp is not a substitute — writing a file
/// in place never touches it, so a descriptor edited by `sed -i`, by a script,
/// or by any editor that saves to the same inode would go unread until the next
/// restart. Stat calls are microseconds; the callers throttle to once a second.
enum FileStamp {
    static func of(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "" }
        let time = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (a[.size] as? Int) ?? 0
        return "\(time):\(size)"
    }

    /// Every `.json` in a directory, named, so that adding, deleting, renaming
    /// and editing a file all change the signature.
    static func ofDirectory(_ url: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .filter { $0.hasSuffix(".json") }.sorted() ?? []
        return names.map { "\($0)=\(of(url.appendingPathComponent($0)))" }.joined(separator: ",")
    }
}
