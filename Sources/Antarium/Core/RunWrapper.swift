import Foundation
import Darwin

/// `antarium run -- claude` — an opt-in passthrough that watches one agent from
/// the inside.
///
/// This exists to answer a question honestly: is being *in* the command worth
/// more than reading what the command writes? It is deliberately a passthrough
/// and nothing more. It does not speak to the model, hold credentials, or see
/// anything the agent didn't already print to your terminal — it copies bytes
/// between your terminal and the agent's, and records when the session started,
/// when it ended, how it exited, and how much came back.
///
/// Nothing installs this. It is never on PATH unless you put it there, because
/// a monitor that can break `claude` is a bad trade.
/// Set by the SIGWINCH handler and read by the copy loop. A file-scope
/// `sig_atomic_t` because that is the only thing a handler may legally write.
nonisolated(unsafe) private var windowChanged: sig_atomic_t = 0

enum RunWrapper {

    struct Record: Codable {
        var command: String
        var argumentCount: Int
        var cwd: String
        var tty: String?
        var startedAt: Date
        var endedAt: Date?
        var exitCode: Int32?
        var bytesFromAgent: Int
        var bytesToAgent: Int
    }

    static var directory: URL { Config.directory.appendingPathComponent("runs") }

    static func metadata(command: String, arguments: [String], cwd: String,
                         tty: String?, startedAt: Date = Date()) -> Record {
        Record(command: command, argumentCount: arguments.count,
               cwd: cwd, tty: tty, startedAt: startedAt, endedAt: nil,
               exitCode: nil, bytesFromAgent: 0, bytesToAgent: 0)
    }

    /// Runs `command` on a pty, copying both directions verbatim. Returns the
    /// child's exit code so the wrapper is transparent to scripts too.
    static func run(_ command: String, _ arguments: [String]) -> Int32 {
        var master: Int32 = 0
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)

        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { perror("forkpty"); return 1 }

        if pid == 0 {                                   // child: become the agent
            let argv = ([command] + arguments).map { strdup($0) } + [nil]
            execvp(command, argv)
            _exit(127)                                  // only reached if exec failed
        }

        var record = metadata(
            command: command,
            arguments: arguments,
            cwd: FileManager.default.currentDirectoryPath,
            tty: ttyname(STDIN_FILENO).map { String(cString: $0) })

        let raw = makeRaw(STDIN_FILENO)
        defer { if var raw { tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) } }
        forward(resizeTo: master)

        // A pty in canonical mode accepts only so much before a newline; past
        // that, a write blocks. Blocking here would freeze the whole loop —
        // including the agent's output on its way back to you — so the master
        // is non-blocking and anything it won't take is held until it will.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        var alive = true
        // Once our stdin is done there is nothing more to forward. Polling it
        // anyway spins: a closed descriptor reports readable for ever and
        // returns zero bytes, which is a hang, not an idle loop.
        var stdinOpen = true
        while alive {
            // Stop taking input while the agent is behind, or we would buffer
            // without bound. Ask to be told when it can accept more.
            let masterEvents = Int16(POLLIN) | (pending.isEmpty ? 0 : Int16(POLLOUT))
            var fds = [pollfd(fd: stdinOpen && pending.isEmpty ? STDIN_FILENO : -1,
                              events: Int16(POLLIN), revents: 0),
                       pollfd(fd: master, events: masterEvents, revents: 0)]
            applyResize(to: master)
            if poll(&fds, 2, 1000) < 0 {
                if errno == EINTR { continue }          // a resize, not a failure
                break
            }

            if !pending.isEmpty && fds[1].revents & Int16(POLLOUT) != 0 {
                pending = drain(master, pending)
            }
            if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                if n > 0 {
                    pending = drain(master, Array(buffer[0..<n]))
                    record.bytesToAgent += n
                } else {
                    // Pass the end-of-input on. Twice: on a tty, EOT mid-line
                    // only flushes what has been typed so far — it takes a
                    // second one on an empty line to actually signal EOF. With
                    // one, input that didn't end in a newline left the agent
                    // waiting for ever.
                    stdinOpen = false
                    var eof: UInt8 = 0x04
                    _ = write(master, &eof, 1)
                    _ = write(master, &eof, 1)
                }
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = read(master, &buffer, buffer.count)
                if n > 0 {
                    writeAll(STDOUT_FILENO, buffer, n)
                    record.bytesFromAgent += n
                } else { alive = false }
            }
            if fds[1].revents & Int16(POLLHUP | POLLERR) != 0 { alive = false }
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        record.endedAt = Date()
        record.exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        save(record)
        return record.exitCode ?? 0
    }

    /// Writes what the descriptor will take right now and returns the rest.
    /// Nothing is dropped and nothing blocks: the remainder is retried when
    /// poll says the descriptor is writable again.
    private static func drain(_ fd: Int32, _ bytes: [UInt8]) -> [UInt8] {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer {
                write(fd, $0.baseAddress! + written, bytes.count - written)
            }
            if n > 0 { written += n; continue }
            if n < 0 && errno == EINTR { continue }
            break                                   // EAGAIN: hold the remainder
        }
        return written == bytes.count ? [] : Array(bytes[written...])
    }

    /// Output to the user's terminal is blocking, so a full write is a loop.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ count: Int) {
        var written = 0
        while written < count {
            let n = bytes.withUnsafeBufferPointer {
                write(fd, $0.baseAddress! + written, count - written)
            }
            if n > 0 { written += n; continue }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            break
        }
    }

    // MARK: - Terminal plumbing

    /// Raw mode, so the agent sees every keystroke exactly as it would without us.
    private static func makeRaw(_ fd: Int32) -> termios? {
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }   // not a tty: pipes are fine
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(fd, TCSAFLUSH, &raw)
        return original
    }

    /// A resized window has to reach the agent or its UI redraws at the wrong
    /// size. The handler itself only sets a flag: a signal handler may touch
    /// nothing but `sig_atomic_t`, and calling into Swift statics from one is
    /// undefined behaviour even when it appears to work.
    private static func forward(resizeTo master: Int32) {
        windowChanged = 1                      // initialised before the handler exists
        signal(SIGWINCH) { _ in windowChanged = 1 }
    }

    /// Applies a pending resize, if one arrived since the last pass.
    private static func applyResize(to master: Int32) {
        guard windowChanged != 0 else { return }
        windowChanged = 0
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// The most run records kept.
    ///
    /// One file per wrapped run, and nothing reads them back — they are there
    /// to be looked at. That made the folder the one place in the app with no
    /// bound on how many objects it holds, which is the rule
    /// `docs/TECHNICAL.md` states as bounding objects rather than only bytes:
    /// each record is a few hundred bytes, and a year of wrapping every
    /// invocation is a directory nobody wants to open.
    static let maxRecords = 500

    /// Which records to drop, given the names present. Pure, so the rule can
    /// be checked without a folder full of files.
    ///
    /// Ordered on the timestamp the name begins with rather than on
    /// modification time, which a copy, a backup restore or a `touch`
    /// rewrites. Parsed as a number rather than compared as text: the names
    /// are epoch seconds, and a ten-digit one sorts before a nine-digit one
    /// as text while being later in fact. Every name written since 2001 has
    /// ten digits, so this cannot currently differ — which is exactly why it
    /// would go unnoticed.
    static func doomed(_ names: [String], keeping limit: Int = maxRecords) -> [String] {
        // A fast path rather than a boundary: at exactly `limit`,
        // `dropLast(limit)` is empty anyway, so this only saves the sort.
        // There is no catalogue entry for it for that reason.
        guard names.count > limit else { return [] }
        let ordered = names.sorted { a, b in
            let x = Int(a.prefix(while: \.isNumber)) ?? 0
            let y = Int(b.prefix(while: \.isNumber)) ?? 0
            // Ties broken on the whole name so the answer does not depend on
            // the order the filesystem listed them in.
            return x == y ? a < b : x < y
        }
        return Array(ordered.dropLast(limit))
    }

    /// Bounded itself: a folder that has already grown past any sane size is
    /// not a reason to read all of it at once.
    static func prune(_ folder: URL, keeping limit: Int = maxRecords) {
        guard let entries = try? BoundedDirectory.entries(folder, limit: 4_096) else { return }
        let names = entries.map(\.url.lastPathComponent).filter { $0.hasSuffix(".json") }
        for name in doomed(names, keeping: limit) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func save(_ record: Record) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let name = "\(Int(record.startedAt.timeIntervalSince1970))-\(getpid()).json"
            try encoder.encode(record).write(to: directory.appendingPathComponent(name))
            prune(directory)
        } catch {
            FileHandle.standardError.write(Data("antarium: couldn't record run — \(error)\n".utf8))
        }
    }
}
