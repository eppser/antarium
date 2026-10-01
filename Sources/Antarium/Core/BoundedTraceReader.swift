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

    /// How much of one file this reader will take in one scan.
    ///
    /// Named rather than written inline because the documentation states it
    /// and the arithmetic that follows from it — a 193 MB transcript takes
    /// about fifty scans to absorb — is the whole reason the behaviour is
    /// acceptable. A number stated in prose and a number in the code are two
    /// numbers unless something compares them.
    static let bytesPerScan = 4 * 1_024 * 1_024

    static func read(_ url: URL, state previous: State,
                     maxRead: Int = BoundedTraceReader.bytesPerScan,
                     // Measured rather than guessed: the longest records in
                     // this machine's large transcripts are about 1.36 MB,
                     // and four of eight had one. At 1 MiB every one of those
                     // sessions lost its whole usage figure to a margin of
                     // 300 KB, because a skipped record makes the totals
                     // incomplete and an incomplete total is not reported.
                     // A record still cannot exceed one read budget.
                     maxRecord: Int = 2 * 1_024 * 1_024,
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
            // Records are found with memchr and copied as whole slices.
            // Walking the chunk one byte at a time and appending each to
            // `carry` individually is what this replaced, and it dominated the
            // scan: a warm pass over this machine's transcripts measured
            // 1648 ms against 78 ms for the reader it succeeded. Per-byte
            // `Data.append` is the same trap that made usage responses take
            // nine seconds a megabyte.
            var index = 0
            while index < count {
                let newline: Int? = chunk.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return nil }
                    guard let hit = memchr(base + index, 0x0A, count - index) else { return nil }
                    return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                }
                let end = newline ?? count
                let segment = end - index
                if !state.discarding {
                    if carry.count + segment <= recordLimit {
                        carry.append(contentsOf: chunk[index..<end])
                    } else {
                        // One record over the limit, discarded up to its own
                        // newline. Counted once, not once per byte.
                        skipped += 1
                        carry.removeAll(keepingCapacity: true)
                        state.discarding = true
                    }
                }
                readOffset += UInt64(segment)
                if newline != nil {
                    readOffset += 1
                    if !state.discarding, !carry.isEmpty { autoreleasepool { consume(carry) } }
                    carry.removeAll(keepingCapacity: true)
                    state.discarding = false
                    state.offset = readOffset
                    index = end + 1
                } else {
                    // A partial record at the chunk boundary leaves the cursor
                    // where the last complete record ended, so an interrupted
                    // read resumes without losing or repeating one.
                    if state.discarding { state.offset = readOffset }
                    index = count
                }
            }
        }
        return Batch(state: state, bytesRead: bytesRead, skipped: skipped,
                     backlogged: readOffset < size, reset: reset)
    }
}
