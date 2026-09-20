import Foundation

/// Catalog inspection never writes configuration. Failed refreshes retain the
/// previous usable observations and expose their degraded status separately.
final class HarnessCatalog: @unchecked Sendable {
    struct Snapshot {
        var descriptors:[HarnessDescriptor] = []
        var issues:[String] = []
        /// Derived once per catalog change, because the process scan asks for
        /// them once per process.
        ///
        /// `isAgent` is handed to `Processes.snapshot` as a predicate and runs
        /// for every process on the machine. It used to call
        /// `HarnessDescriptor.matchFragments()` and `processNamesAll()`, each
        /// of which filtered the whole catalog, flat-mapped it into a fresh
        /// array and — for the names — built a fresh Set, on every single
        /// call. With several hundred processes that is several hundred
        /// rebuilds of the same two collections per scan, which is why the
        /// scan cost a flat ~8 ms per descriptor whatever that descriptor
        /// had to do: a quota-only harness with no session store at all paid
        /// the same as a real one.
        let enabled:[HarnessDescriptor]
        let matchFragments:[String]
        let processNames:Set<String>

        init(descriptors:[HarnessDescriptor] = [], issues:[String] = []) {
            self.descriptors = descriptors
            self.issues = issues
            let live = descriptors.filter(\.isEnabled)
            self.enabled = live
            self.matchFragments = live.flatMap(\.match)
            self.processNames = Set(live.flatMap(\.processNames))
        }
    }
    let directory:URL
    private let defaults:[URL]
    private let schema:URL?
    private let readme:String
    private let lock = NSLock()
    private var current = Snapshot()
    private var byFile:[String:HarnessDescriptor] = [:]
    private var seedIssues:[String] = []
    private var checked:TimeInterval = -.infinity
    private var loaded:TimeInterval = -.infinity
    private var fingerprint:String?
    init(directory:URL,defaults:[URL] = [],schema:URL? = nil,readme:String = "") {
        self.directory = directory; self.defaults = defaults; self.schema = schema; self.readme = readme
    }
    var issues:[String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(seedIssues + current.issues)).sorted()
    }
    func seed() -> HarnessSeed.Result {
        lock.lock(); defer { lock.unlock() }
        let result = HarnessSeed.run(directory:directory,sources:defaults,schema:schema,readme:readme)
        seedIssues = result.issues; fingerprint = nil; checked = -.infinity
        return result
    }
    private func inventory() throws -> (files:[URL],stamp:String) {
        let before = FileStamp.of(directory)
        let files = try BoundedDirectory.entries(directory,limit:4_096)
            .map(\.url).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 256, before == FileStamp.of(directory) else { throw BoundedDirectory.ReadError.limit }
        return (files, before + "|" + files.map { $0.lastPathComponent + "=" + FileStamp.of($0) }.joined(separator:"|"))
    }
    func snapshot(now:TimeInterval = ProcessInfo.processInfo.systemUptime,force:Bool = false) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        if !force, now >= checked, now - checked < 1 { return current }
        checked = now
        do {
            let inventory = try inventory()
            if !force, inventory.stamp == fingerprint,
               current.issues.isEmpty || (now >= loaded && now - loaded < 5) { return current }
            var next:[String:HarnessDescriptor] = [:], problems:[String] = [], bytes = 0
            for file in inventory.files {
                guard bytes < 8 * 1_024 * 1_024 else { throw BoundedFile.ReadError.tooLarge }
                let name = file.lastPathComponent
                do {
                    let data = try BoundedFile.read(file,maxBytes:1_024 * 1_024)
                    bytes += data.count
                    guard bytes <= 8 * 1_024 * 1_024 else { throw BoundedFile.ReadError.tooLarge }
                    next[name] = try HarnessDocument.decode(data).descriptor
                } catch {
                    guard bytes <= 8 * 1_024 * 1_024 else { throw BoundedFile.ReadError.tooLarge }
                    next[name] = byFile[name]
                    problems.append("A harness file is unreadable or invalid. Its last valid configuration is retained when available.")
                }
            }
            guard try self.inventory().stamp == inventory.stamp else { throw BoundedFile.ReadError.readFailed }
            let grouped = Dictionary(grouping:next.values,by:\.id)
            let previous = Dictionary(uniqueKeysWithValues:current.descriptors.map { ($0.id,$0) })
            var resolved:[HarnessDescriptor] = []
            for (id,descriptors) in grouped {
                if descriptors.count == 1 { resolved.append(descriptors[0]) }
                else {
                    if let prior = previous[id] { resolved.append(prior) }
                    problems.append("Multiple harness files declare the same ID. The last unambiguous configuration is retained when available.")
                }
            }
            byFile = next
            current = Snapshot(descriptors:resolved.sorted { $0.id < $1.id },issues:Array(Set(problems)).sorted())
            fingerprint = inventory.stamp; loaded = now
        } catch {
            current.issues = ["The harness folder could not be refreshed within its safety limits. The last valid catalog is retained."]
            fingerprint = nil
        }
        return current
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        checked = -.infinity; fingerprint = nil
    }
}
