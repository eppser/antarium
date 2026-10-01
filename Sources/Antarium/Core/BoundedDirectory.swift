import Darwin
import Foundation

/// Reads a directory incrementally, with an explicit entry budget. A limit or
/// permission failure throws; callers must not mistake a partial list for empty.
enum BoundedDirectory {
    enum ReadError: Error { case unavailable, limit, invalidPattern }
    struct Entry {
        let url: URL
        let isDirectory: Bool
        let isRegular: Bool
        let modified: Date
    }
    static func entries(_ directory: URL, limit: Int = 4_096) throws -> [Entry] {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ReadError.unavailable }
        guard let stream = fdopendir(fd) else { close(fd); throw ReadError.unavailable }
        defer { closedir(stream) }
        let maximum = min(16_384,max(0,limit))
        var entries:[Entry] = [], examined = 0
        while true {
            errno = 0
            guard let pointer = readdir(stream) else {
                guard errno == 0 else { throw ReadError.unavailable }
                break
            }
            var record = pointer.pointee
            let name = withUnsafePointer(to: &record.d_name) {
                $0.withMemoryRebound(to:CChar.self,capacity:Int(record.d_namlen)+1) { String(validatingCString:$0) }
            }
            guard let name else { throw ReadError.unavailable }
            if name == "." || name == ".." { continue }
            examined += 1
            guard examined <= maximum else { throw ReadError.limit }
            var info = stat()
            if fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue } // Disappeared during enumeration.
                throw ReadError.unavailable
            }
            entries.append(Entry(url:directory.appendingPathComponent(name),
                isDirectory:info.st_mode & S_IFMT == S_IFDIR,
                isRegular:info.st_mode & S_IFMT == S_IFREG,
                modified:Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)+Double(info.st_mtimespec.tv_nsec)/1e9)))
        }
        return entries
    }
}

/// Bounded component globbing: `*` within a name, `**` across zero or more
/// directories. No symlink traversal, recursion on the call stack or regex input.
enum BoundedGlob {
    static func component(_ name: String, matches pattern: String) -> Bool {
        guard name.utf8.count <= 1_024, pattern.utf8.count <= 1_024 else { return false }
        if (pattern == "*" || pattern == "**") && name.hasPrefix(".") { return false }
        let pieces = pattern.split(separator:"*",omittingEmptySubsequences:false)
        guard pieces.count > 1 else { return name == pattern }
        var remainder = name[...]
        if let first = pieces.first, !first.isEmpty {
            guard remainder.hasPrefix(first) else { return false }
            remainder = remainder.dropFirst(first.count)
        }
        for (index,piece) in pieces.dropFirst().enumerated() where !piece.isEmpty {
            if index == pieces.count - 2, !pattern.hasSuffix("*") { return remainder.hasSuffix(piece) }
            guard let range = remainder.range(of:piece) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return true
    }
    private static func components(_ pattern:String) -> [String]? {
        guard !pattern.isEmpty, !pattern.hasPrefix("/"), pattern.utf8.count <= 1_024 else { return nil }
        let parts = pattern.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        return parts
    }
    static func matches(path:[String], pattern:String) -> Bool {
        guard path.count <= 128, let parts = components(pattern) else { return false }
        var previous = [Bool](repeating:false,count:path.count+1); previous[0] = true
        for part in parts {
            var next = [Bool](repeating:false,count:path.count+1)
            if part == "**" { next[0] = previous[0] }
            for index in path.indices {
                if part == "**" { next[index+1] = previous[index+1] || (!path[index].hasPrefix(".") && next[index]) }
                else { next[index+1] = previous[index] && component(path[index],matches:part) }
            }
            previous = next
        }
        return previous[path.count]
    }
    static func files(under root:URL, pattern:String, maximumEntries:Int = 16_384,
                      maximumDirectories:Int = 512, maximumDepth:Int = 32) throws -> [URL] {
        guard let parts = components(pattern) else { throw BoundedDirectory.ReadError.invalidPattern }
        let entryLimit = min(65_536,max(1,maximumEntries))
        let directoryLimit = min(2_048,max(1,maximumDirectories))
        let depthLimit = min(64,max(1,maximumDepth))
        var pending:[(URL,Int,Int)] = [(root,0,0)], seen:Set<String> = [], found:Set<URL> = []
        var cache:[URL:[BoundedDirectory.Entry]] = [:], count = 0
        while let (directory,index,depth) = pending.popLast() {
            guard pending.count <= 32_768 else { throw BoundedDirectory.ReadError.limit }
            guard depth <= depthLimit else { throw BoundedDirectory.ReadError.limit }
            let key = directory.path + "\0" + String(index)
            guard seen.insert(key).inserted else { continue }
            guard seen.count <= 32_768 else { throw BoundedDirectory.ReadError.limit }
            guard index < parts.count else { continue }
            let entries:[BoundedDirectory.Entry]
            if let hit = cache[directory] { entries = hit }
            else {
                guard cache.count < directoryLimit else { throw BoundedDirectory.ReadError.limit }
                entries = try BoundedDirectory.entries(directory,limit:min(4_096,entryLimit-count))
                count += entries.count; cache[directory] = entries
            }
            let part = parts[index], last = index == parts.count-1
            if part == "**" {
                if !last { pending.append((directory,index+1,depth)) }
                for entry in entries where !entry.url.lastPathComponent.hasPrefix(".") {
                    if entry.isDirectory { pending.append((entry.url,index,depth+1)) }
                    else if last && entry.isRegular { found.insert(entry.url) }
                }
            } else {
                for entry in entries where component(entry.url.lastPathComponent,matches:part) {
                    if last && entry.isRegular { found.insert(entry.url) }
                    else if !last && entry.isDirectory { pending.append((entry.url,index+1,depth+1)) }
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
