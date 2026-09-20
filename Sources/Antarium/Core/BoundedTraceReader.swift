import Darwin
import Foundation

/// Historical JSONL reads have explicit per-pass and per-record limits. Only
/// complete records advance a normal cursor; oversized records are discarded
/// incrementally. Persisted state contains offsets and file identity, never text.
enum BoundedTraceReader {
    struct State: Codable {
        var offset: UInt64 = 0
        var identity: String?
        var size: UInt64 = 0
        var modified: String?
        var discarding = false
    }
    struct Batch {
        let state: State
        let bytesRead: Int
        let skipped: Int
        let backlogged: Bool
        let reset: Bool
    }
    enum ReadError: Error { case unavailable, notRegular, readFailed }

    static func read(_ url: URL, state previous: State,
                     maxRead: Int = 4 * 1_024 * 1_024,
                     maxRecord: Int = 1_024 * 1_024,
                     onReset: () -> Void = {},
                     consume: (Data) -> Void) throws -> Batch {
        let limit = min(16 * 1_024 * 1_024, max(2, maxRead))
        let recordLimit = min(limit - 1, max(1, maxRecord))
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ReadError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadError.unavailable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ReadError.notRegular }
        let identity = "\(info.st_dev):\(info.st_ino)"
        let modified = "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        let size = UInt64(max(0, info.st_size))
        let reset = previous.identity != nil && (previous.identity != identity || size < previous.size
            || (size == previous.size && previous.modified != modified))
        var state = reset ? State() : previous
        if reset { onReset() }
        state.identity = identity; state.modified = modified; state.size = size
        guard state.offset <= size, lseek(fd, off_t(state.offset), SEEK_SET) >= 0 else { throw ReadError.readFailed }
        var readOffset = state.offset
        var bytesRead = 0
        var skipped = 0
        var carry = Data()
        var chunk = [UInt8](repeating: 0, count: min(65_536, limit))
        while bytesRead < limit && readOffset < size {
            let wanted = min(chunk.count, limit - bytesRead, Int(min(UInt64(Int.max), size - readOffset)))
            let count = Darwin.read(fd, &chunk, wanted)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ReadError.readFailed }
            if count == 0 { break }
            bytesRead += count
            for byte in chunk.prefix(count) {
                readOffset += 1
                if byte == 0x0A {
                    if !state.discarding && !carry.isEmpty { autoreleasepool { consume(carry) } }
                    carry.removeAll(keepingCapacity: true)
                    state.discarding = false; state.offset = readOffset
                } else if state.discarding {
                    state.offset = readOffset
                } else if carry.count < recordLimit {
                    carry.append(byte)
                } else {
                    skipped += 1; carry.removeAll(keepingCapacity: true)
                    state.discarding = true; state.offset = readOffset
                }
            }
        }
        return Batch(state: state, bytesRead: bytesRead, skipped: skipped,
                     backlogged: readOffset < size, reset: reset)
    }
}
