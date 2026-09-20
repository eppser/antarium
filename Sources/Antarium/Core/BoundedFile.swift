import Darwin
import Foundation

/// Shared regular-file boundary for configuration and diagnostic sampling.
/// All returned buffers have explicit limits; FIFOs and final symlinks are
/// rejected before reading. Paths and source contents never enter error text.
enum BoundedFile {
    enum ReadError: Error { case unavailable, notRegular, tooLarge, readFailed }
    struct Sample {
        let records: [Data]
        let bytesRead: Int
        let limited: Bool
    }
    private static func openRegular(_ url: URL) throws -> (Int32, UInt64) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ReadError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw ReadError.unavailable }
        guard info.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); throw ReadError.notRegular }
        return (fd, UInt64(max(0, info.st_size)))
    }
    private static func bytes(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let found = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: total), count - total, off_t(offset + UInt64(total)))
            }
            if found < 0 && errno == EINTR { continue }
            guard found >= 0 else { throw ReadError.readFailed }
            if found == 0 { break }
            total += found
        }
        return Data(buffer.prefix(total))
    }
    static func isRegular(_ url:URL) -> Bool {
        guard let (fd,_) = try? openRegular(url) else { return false }
        Darwin.close(fd); return true
    }
    static func prefix(_ url:URL,maxBytes:Int) throws -> Data {
        let (fd,size) = try openRegular(url)
        defer { Darwin.close(fd) }
        let limit = min(1_048_576,max(1,maxBytes))
        return try bytes(fd,offset:0,count:Int(min(UInt64(limit),size)))
    }
    static func read(_ url: URL, maxBytes: Int = 4 * 1_024 * 1_024) throws -> Data {
        let limit = min(32 * 1_024 * 1_024, max(1, maxBytes))
        let (fd, size) = try openRegular(url)
        defer { Darwin.close(fd) }
        guard size <= limit else { throw ReadError.tooLarge }
        // One extra byte also detects growth after the size check.
        let data = try bytes(fd, offset: 0, count: min(limit + 1, Int(size) + 1))
        guard data.count <= limit else { throw ReadError.tooLarge }
        guard data.count <= size else { throw ReadError.readFailed }
        return data
    }
    static func sampleJSONL(_ url: URL, maxRecords: Int = 400) throws -> Sample {
        let count = min(400, max(1, maxRecords))
        let block = 1_024 * 1_024
        let (fd, size) = try openRegular(url)
        defer { Darwin.close(fd) }
        if size <= UInt64(block * 2) {
            let data = try bytes(fd, offset: 0, count: Int(size))
            let complete = data.lastIndex(of: 0x0A).map { data.prefix(through: $0) } ?? Data()
            let lines = complete.split(separator: 0x0A).filter { $0.count <= block }
            let sample = lines.count <= count ? Array(lines) : Array(lines.prefix((count + 1) / 2)) + Array(lines.suffix(count / 2))
            return Sample(records: sample.map { Data($0) }, bytesRead: data.count, limited: lines.count > count)
        }
        let head = try bytes(fd, offset: 0, count: block)
        let tail = try bytes(fd, offset: size - UInt64(block), count: block)
        let headLines = head.lastIndex(of: 0x0A).map { head.prefix(through: $0).split(separator: 0x0A) } ?? []
        // The first tail line can begin in the middle of a record. Exclude it,
        // and exclude any unfinished final line as in the live reader.
        let tailLines: [Data.SubSequence]
        if let first = tail.firstIndex(of: 0x0A), let last = tail.lastIndex(of: 0x0A), first < last {
            tailLines = tail[tail.index(after: first)...last].split(separator: 0x0A)
        } else { tailLines = [] }
        let records = Array(headLines.prefix((count + 1) / 2)) + Array(tailLines.suffix(count / 2))
        return Sample(records: records.map { Data($0) }, bytesRead: head.count + tail.count, limited: true)
    }
}
