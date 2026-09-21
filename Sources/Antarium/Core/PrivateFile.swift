import Foundation
import Darwin

/// Atomic private snapshots: a failed write must preserve the existing file.
/// The directory descriptor stays fixed across validation and replacement.
enum PrivateFile {
    enum WriteError:Error { case invalidDestination, tooLarge, failed, changed }
    static func write(_ data:Data,to url:URL,maxBytes:Int = 16 * 1_024 * 1_024,executable:Bool = false,
                      beforeCommit:() throws -> Void = {}) throws {
        guard data.count <= min(32 * 1_024 * 1_024,max(0,maxBytes)) else { throw WriteError.tooLarge }
        guard url.isFileURL, let decodedPath = url.path(percentEncoded:true).removingPercentEncoding,
              !decodedPath.contains("\0"), !url.lastPathComponent.isEmpty else { throw WriteError.invalidDestination }
        // A folder chosen by the user may be an alias (including /tmp).
        // Resolve it in one open call, then use only that directory descriptor.
        let directory = open(url.deletingLastPathComponent().path,O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw WriteError.invalidDestination }
        defer { close(directory) }
        let name = url.lastPathComponent
        func stamp() throws -> String? {
            var info = stat()
            guard fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw WriteError.invalidDestination
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw WriteError.invalidDestination }
            return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
        let initial = try stamp()
        // The name is random, so `O_EXCL | O_NOFOLLOW` below defends against a
        // predictable-name attack that cannot be staged here — and cannot be
        // reached by a test either. The destination is protected separately
        // and testably: `stamp()` refuses anything that is not a regular file
        // and never follows a link to decide.
        let temporary = ".antarium-\(UUID()).tmp"
        let file = openat(directory,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,executable ? 0o700 : 0o600)
        guard file >= 0 else { throw WriteError.failed }
        defer { close(file); unlinkat(directory,temporary,0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WriteError.failed }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw WriteError.failed }
        try beforeCommit()
        guard try stamp() == initial else { throw WriteError.changed }
        guard renameat(directory,temporary,directory,name) == 0 else { throw WriteError.failed }
        // Some filesystems do not support directory fsync; the file contents
        // were already synced before the atomic rename.
        _ = fsync(directory)
    }
}
