import Foundation
import Darwin

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
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? "" : "unavailable:\(errno)"
        }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):"
            + "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    /// Every `.json` in a directory, named, so that adding, deleting, renaming
    /// and editing a file all change the signature.
    static func ofDirectory(_ url: URL) -> String {
        do {
            let entries = try BoundedDirectory.entries(url,limit:4_096)
                .map(\.url).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            return "directory:" + of(url) + "|" + entries.map {
                "\($0.lastPathComponent)=\(of($0))"
            }.joined(separator:",")
        } catch { return "unavailable-directory:" + of(url) }

    }
}
