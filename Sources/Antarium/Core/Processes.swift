import Darwin
import Foundation

/// The process table, read through libproc instead of shelling out.
///
/// The scan used to run `ps` (27 ms) and `lsof` (54 ms) on every pass — 81 ms
/// of a 96 ms scan, every 10 seconds, to answer questions the kernel will
/// answer in microseconds. `proc_pidinfo` resolves a working directory in
/// ~0.01 ms.
enum Processes {
    enum ObservationError: Error { case unavailable, capacityExceeded, unstable }
    typealias PIDList = (UnsafeMutableRawPointer?, Int32) -> Int32
    /// A full buffer may have omitted processes that appeared after sizing.
    /// Retry boundedly; never treat a truncated enumeration as a complete table.
    static func processIDs(using list: PIDList = proc_listallpids) throws -> [Int32] {
        let maximum = 65_536
        let required = list(nil, 0)
        // Early exit: the `count > 0` check inside the loop refuses the same
        // answer a moment later, so no mutation of this line can be caught.
        guard required > 0 else { throw ObservationError.unavailable }
        guard required < maximum else { throw ObservationError.capacityExceeded }
        var capacity = min(maximum, Int(required) + 128)
        for _ in 0..<3 {
            try Task.checkCancellation()
            var pids = [Int32](repeating: 0, count: capacity)
            let count = list(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            guard count > 0 else { throw ObservationError.unavailable }
            if count < capacity { return Array(pids.prefix(Int(count))).filter { $0 > 0 } }
            guard capacity < maximum else { throw ObservationError.capacityExceeded }
            capacity = min(maximum, capacity * 2)
        }
        throw ObservationError.unstable
    }
    static func residentBytes(_ reported: UInt64?) -> Int64? {
        reported.flatMap(Int64.init(exactly:))
    }
    struct Snapshot {
        var table: [Int32: Info]
        var unavailablePIDs: Set<Int32>
    }
    struct Info {
        let pid: Int32
        let ppid: Int32
        /// Executable path. Matching on this rather than the process *name*:
        /// Claude Code runs from `.../claude/versions/2.1.241`, so its comm
        /// field reads "2.1.241" while `ps` shows "claude" (ps reads argv[0]).
        let path: String
        /// Process name. A script's executable is its interpreter — PI runs as
        /// `node` but is named `pi` — so matching needs both.
        let name: String
        /// argv[0], only for interpreter-hosted processes. A script's exec path
        /// and comm both say "node"; argv[0] is where "pi" survives.
        let argv0: String
        let rss: Int64?
        var startedAt: Date? = nil
    }

    /// Every process this user can see. Resident size is only fetched for the
    /// ones the caller cares about, since that's a second syscall each.
    static func snapshot(measureIf shouldMeasure: (String) -> Bool = { _ in false }) throws -> [Int32: Info] {
        try capture(measureIf:shouldMeasure).table
    }
    static func capture(measureIf shouldMeasure: (String) -> Bool = { _ in false }) throws -> Snapshot {
        let pids = try processIDs()
        var unavailable = Set<Int32>()
        var table: [Int32: Info] = [:]
        for pid in pids {
            try Task.checkCancellation()
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { unavailable.insert(pid); continue }

            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
                ? String(cString: buffer) : ""
            let name = withUnsafePointer(to: &bsd.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN + 1)) {
                    String(cString: $0)
                }
            }

            // Only scripts need argv[0], and the sysctl is per-process — so
            // pay for it just where the other two fields are uninformative.
            let base = (path as NSString).lastPathComponent
            let argv0 = Self.interpreters.contains(base) ? (Self.argv0(of: pid) ?? "") : ""

            var rss: Int64?
            if shouldMeasure(path) || shouldMeasure(name) || shouldMeasure(argv0) {
                var task = proc_taskinfo()
                let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
                    rss = residentBytes(task.pti_resident_size)
                }
            }
            table[pid] = Info(pid: pid, ppid: Int32(bsd.pbi_ppid), path: path,
                              name: name, argv0: argv0, rss: rss,
                              startedAt: bsd.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970:Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec)/1_000_000) : nil)
        }
        return Snapshot(table:table,unavailablePIDs:unavailable)
    }

    private static let interpreters: Set<String> = [
        "node", "python", "python3", "ruby", "deno", "bun", "perl", "php",
    ]

    /// argv[0], via KERN_PROCARGS2.
    static func argv0(of pid: Int32) -> String? {
        var argmax = 0
        var limitMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var size = MemoryLayout<Int>.size
        guard sysctl(&limitMib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        size = argmax
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        // Layout: argc, the exec path, NUL padding, then argv[0].
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        let start = i
        while i < size && buffer[i] != 0 { i += 1 }
        guard i > start else { return nil }
        return String(decoding: buffer[start..<i].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Regular files currently held open by a process, read directly from
    /// libproc. A bounded list is enough for session binding and avoids
    /// launching `lsof` for every agent on every scan.
    static func openFilePaths(of pid: Int32, limit: Int = 1_024) -> [String] {
        let itemSize = MemoryLayout<proc_fdinfo>.size
        let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0, itemSize > 0, limit > 0 else { return [] }

        let capacity = min((Int(requiredBytes) / itemSize) + 16, limit)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let availableBytes = Int32(capacity * itemSize)
        let returnedBytes = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &descriptors, availableBytes)
        guard returnedBytes > 0 else { return [] }

        let count = min(Int(returnedBytes) / itemSize, descriptors.count)
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        var paths: [String] = []
        paths.reserveCapacity(min(count, 32))
        for descriptor in descriptors.prefix(count)
            where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd,
                                 PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize
            else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return Array(Set(paths)).sorted()
    }

    /// Apps whose own name is too long for a column beside a project path.
    private static let shortName = [
        "Visual Studio Code": "VS Code",
        "Visual Studio Code - Insiders": "VS Code",
        "IntelliJ IDEA": "IntelliJ",
    ]

    /// The app an agent is running inside — "tmux", "Terminal", "Warp", "Zed".
    ///
    /// Walks the process tree and reads the answer off the executable paths we
    /// already have. Deliberately no AppKit: the scan runs off the main thread,
    /// and `NSRunningApplication` is not something to call from there.
    static func hostApp(of pid: Int32, parents: [Int32: Int32],
                        paths: [Int32: String]) -> String? {
        var current = pid
        var outermost: String?
        for _ in 0..<12 {
            let path = paths[current] ?? ""
            let base = (path as NSString).lastPathComponent
            // tmux first: the agent's parent is the tmux server, and knowing it
            // is in tmux is more useful than knowing which terminal is attached.
            if base == "tmux" || path.contains("/tmux") { return "tmux" }
            if let range = path.range(of: ".app/Contents/MacOS/") {
                let bundle = String(path[path.startIndex..<range.lowerBound])
                let name = (bundle as NSString).lastPathComponent
                // Helpers sit inside their parent app; keep walking to name it.
                // Keep the last one found, not the first: Claude Desktop runs
                // its CLI from a nested claude.app, and the app you would
                // actually switch to is the one further up.
                if !name.hasSuffix(" Helper"), !name.contains("Renderer") {
                    outermost = shortName[name] ?? name
                }
            }
            if base == "sshd-session" || base == "sshd" { return "SSH" }
            guard let parent = parents[current], parent > 1 else { break }
            current = parent
        }
        return outermost
    }

    /// Parent of every process on the machine, via `sysctl`.
    ///
    /// `proc_pidinfo` refuses root-owned processes, and a terminal session runs
    /// through root-owned `login` — so walking parents that way stopped one
    /// step short of the terminal and the click fell back to Finder. `sysctl`
    /// has no such restriction.
    static func parentMap() -> [Int32: Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Headroom: processes can appear between the sizing call and the read.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }

        var map: [Int32: Int32] = [:]
        for entry in procs.prefix(size / stride) where entry.kp_proc.p_pid > 0 {
            map[entry.kp_proc.p_pid] = entry.kp_eproc.e_ppid
        }
        return map
    }

    /// Working directory of a process, without `lsof`.
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}
