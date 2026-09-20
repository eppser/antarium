import Darwin
import Foundation

/// Best-effort private logging: failure drops a message, never raises an
/// Objective-C file exception or recursively removes anything during rotation.
final class DiagnosticLogFile:@unchecked Sendable {
    struct Tail { let lines:[String]; let truncated:Bool }
    enum Failure:Error { case invalidCount, unavailable }
    let directory:URL
    let maximumBytes:Int
    private let lock = NSLock()
    private var failureStorage:String?
    var lastFailure:String? { lock.lock(); defer { lock.unlock() }; return failureStorage }
    private func fail(_ stage:String) -> Bool { failureStorage = "\(stage):\(errno)"; return false }
    init(directory:URL,maximumBytes:Int = 4 * 1_024 * 1_024) {
        self.directory = directory; self.maximumBytes = min(4 * 1_024 * 1_024,max(1_024,maximumBytes))
    }
    @discardableResult func append(_ line:String) -> Bool {
        var data = Data(), used = 0
        let cap = min(8_192,maximumBytes)-1
        for scalar in line.unicodeScalars {
            let text = CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            let bytes = Array(text.utf8)
            guard used + bytes.count <= cap else { break }
            data.append(contentsOf:bytes); used += bytes.count
        }
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        } catch { return fail("directory") }
        let parent = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard parent >= 0 else { return fail("parent") }
        defer { close(parent) }
        return append(data,parent:parent,canRotate:true)
    }
    private func append(_ data:Data,parent:Int32,canRotate:Bool) -> Bool {
        let fd = openat(parent,"antarium.log",O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0o600)
        guard fd >= 0 else { return fail("open") }
        defer { close(fd) }
        var info = stat(), current = stat()
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { return fail("lock") }
        // A concurrently spawned child can briefly inherit this open-file
        // description before exec closes CLOEXEC descriptors. Closing only
        // the parent's fd would leave its lock alive in that child.
        defer { _ = flock(fd,LOCK_UN) }
        guard fstat(fd,&info) == 0 else { return fail("stat") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid() else { return fail("ownership") }
        guard fstatat(parent,"antarium.log",&current,AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino else { return fail("changed") }
        guard fchmod(fd,0o600) == 0 else { return fail("permissions") }
        if info.st_size > maximumBytes - data.count {
            guard canRotate else { return false }
            var previous = stat()
            if fstatat(parent,"antarium.1.log",&previous,AT_SYMLINK_NOFOLLOW) == 0 {
                guard previous.st_mode & S_IFMT == S_IFREG, previous.st_nlink == 1,
                      previous.st_uid == geteuid() else { return false }
            } else if errno != ENOENT { return false }
            guard renameat(parent,"antarium.log",parent,"antarium.1.log") == 0 else { return false }
            return append(data,parent:parent,canRotate:false)
        }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(fd,$0.baseAddress!.advanced(by:written),data.count-written)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return fail("write") }
            written += count
        }
        return true
    }
    /// At most 64 KiB and 1,000 lines. An incomplete first/last line is omitted
    /// rather than exposing a cut-off fragment as a complete diagnostic entry.
    static func tail(_ file:URL,lineCount:Int) throws -> Tail {
        guard (0...1_000).contains(lineCount) else { throw Failure.invalidCount }
        let fd = open(file.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw Failure.unavailable }
        if lineCount == 0 { return Tail(lines:[],truncated:info.st_size > 0) }
        let count = Int(min(65_536,info.st_size)), offset = info.st_size - off_t(count)
        var data = Data(count:count), read = 0
        while read < count {
            let found = data.withUnsafeMutableBytes {
                pread(fd,$0.baseAddress!.advanced(by:read),count-read,offset+off_t(read))
            }
            if found < 0 && errno == EINTR { continue }
            guard found > 0 else { throw Failure.unavailable }
            read += found
        }
        var limited = offset > 0
        if offset > 0 {
            if let first = data.firstIndex(of:10) { data = Data(data.dropFirst(first+1)) }
            else { return Tail(lines:[],truncated:true) }
        }
        if data.last != 10, !data.isEmpty {
            limited = true
            data = data.lastIndex(of:10).map { Data(data.prefix(through:$0)) } ?? Data()
        }
        guard let text = String(data:data,encoding:.utf8) else { throw Failure.unavailable }
        let lines = text.split(separator:"\n",omittingEmptySubsequences:true)
        return Tail(lines:lines.suffix(lineCount).map(String.init),truncated:limited || lines.count > lineCount)
    }
}
