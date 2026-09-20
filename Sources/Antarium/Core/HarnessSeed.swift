import Foundation
import Darwin

/// Updates only files whose current bytes still match recorded app ownership.
/// A damaged manifest cannot authorize writes. No legacy directory is removed.
enum HarnessSeed {
    struct Result {
        var added:[String] = []
        var updated:[String] = []
        var keptYours:[String] = []
        var issues:[String] = []
    }
    private static let lock = NSLock()
    private enum Failure:Error { case unavailable, invalid, limit, changed }
    static func checksum(_ data:Data) -> String {
        var hash:UInt64 = 0xcbf29ce484222325
        for byte in data { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return String(hash,radix:16)
    }
    private static func readIfPresent(_ file:URL,maxBytes:Int) throws -> Data? {
        var info = stat()
        guard lstat(file.path,&info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unavailable
        }
        return try BoundedFile.read(file,maxBytes:maxBytes)
    }
    static func run(directory:URL,sources:[URL],schema:URL?,readme:String) -> Result {
        lock.lock(); defer { lock.unlock() }
        var result = Result()
        let manifest = directory.appendingPathComponent(".seed.json")
        let manifestStamp = FileStamp.of(manifest)
        var owned:[String:String] = [:]
        let shipped:[(String,Data)]
        do {
            guard sources.count <= 256 else { throw Failure.limit }
            let names = sources.map(\.lastPathComponent)
            guard Set(names).count == names.count, names.allSatisfy({
                $0.hasSuffix(".json") && !$0.hasPrefix(".") && $0.utf8.count <= 256
                    && !$0.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) })
            }) else { throw Failure.invalid }
            if let data = try readIfPresent(manifest,maxBytes:131_072) {
                guard let values = try JSONSerialization.jsonObject(with:data) as? [String:String],
                      values.count <= 1_024, values.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 64 }) else { throw Failure.invalid }
                owned = values
            }
            guard FileStamp.of(manifest) == manifestStamp else { throw Failure.changed }
            guard Set(owned.keys).union(names).count <= 1_024 else { throw Failure.limit }
            var bytes = 0
            shipped = try sources.map { source in
                let data = try BoundedFile.read(source,maxBytes:1_048_576)
                bytes += data.count; guard bytes <= 8 * 1_024 * 1_024 else { throw Failure.limit }
                return (source.lastPathComponent,data)
            }
            var info = stat()
            if lstat(directory.path,&info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
            } else {
                guard errno == ENOENT else { throw Failure.unavailable }
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }
        } catch {
            result.issues.append("Harness defaults were not updated because ownership metadata, the destination or a shipped file could not be read safely. Existing files were preserved.")
            return result
        }
        func replace(_ data:Data,_ file:URL,expecting stamp:String,limit:Int) throws {
            try PrivateFile.write(data,to:file,maxBytes:limit) {
                guard FileStamp.of(file) == stamp else { throw Failure.changed }
            }
        }
        for (name,data) in shipped {
            let file = directory.appendingPathComponent(name), stamp = FileStamp.of(directory.appendingPathComponent(name))
            do {
                let existing = try readIfPresent(file,maxBytes:1_048_576)
                guard FileStamp.of(file) == stamp else { throw Failure.changed }
                let current = existing.map(checksum), next = checksum(data)
                if current == next { owned[name] = next; continue }
                if let current, owned[name] != current { result.keptYours.append(name); continue }
                try replace(data,file,expecting:stamp,limit:1_048_576)
                owned[name] = next
                if existing == nil { result.added.append(name) } else { result.updated.append(name) }
            } catch {
                result.issues.append("A harness file was preserved because it was unreadable, linked, oversized or changed during the update.")
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject:owned,options:[.sortedKeys])
            try replace(data,manifest,expecting:manifestStamp,limit:131_072)
        } catch { result.issues.append("Harness ownership metadata could not be saved safely. Existing metadata was preserved.") }
        if let schema {
            let file = directory.deletingLastPathComponent().appendingPathComponent("harness.schema.json")
            let stamp = FileStamp.of(file)
            do { try replace(BoundedFile.read(schema,maxBytes:1_048_576),file,expecting:stamp,limit:1_048_576) }
            catch { result.issues.append("The editor schema could not be updated safely.") }
        }
        let readmeFile = directory.appendingPathComponent("README.txt")
        if FileStamp.of(readmeFile).isEmpty {
            do { try replace(Data(readme.utf8),readmeFile,expecting:"",limit:65_536) }
            catch { result.issues.append("The harness instructions file could not be created safely.") }
        }
        return result
    }
}
