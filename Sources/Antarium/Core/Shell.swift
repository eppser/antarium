import Darwin
import Foundation

/// One truthful subprocess boundary for every configured command.
///
/// Callers that only need a value use run; diagnostics can use execute to
/// distinguish launch failure, non-zero exit and timeout without inventing
/// success from whatever happened to reach stdout.
enum Shell {
    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32?
        let timedOut: Bool
        let launchError: String?
        var cancelled = false
        var childCPUSeconds: Double?
        var stdoutTruncated = false
        var stderrTruncated = false

        /// Process exit success is separate from a complete value to parse.
        var completeOutput: Bool { succeeded && !stdoutTruncated }
        var succeeded: Bool {
            launchError == nil && !timedOut && !cancelled && exitCode == 0
        }
    }

    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        private var truncated = false

        func append(_ data: Data, limit: Int) {
            lock.lock()
            if limit > 0 && data.count > limit - value.count { truncated = true }
            if limit <= 0 {
                value.append(data)
            } else if data.count >= limit {
                value = Data(data.suffix(limit))
            } else {
                let excess = value.count + data.count - limit
                if excess > 0 { value.removeFirst(excess) }
                value.append(data)
            }
            lock.unlock()
        }

        func get() -> (data:Data,truncated:Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (value,truncated)
        }
    }

    /// Executes a process while draining both pipes concurrently. The output
    /// cap is applied while draining so a verbose child can neither deadlock on
    /// a full pipe nor make the monitor retain unbounded output. The diagnostic
    /// suffix is more useful than the prefix for command failures. Commands without
    /// an explicit timeout receive a 30-second deadline; output is always bounded.
    static func execute(_ path: String, _ args: [String],
                        timeout: TimeInterval? = nil,
                        outputLimit: Int = 4 * 1_024 * 1_024,
                        environment: [String: String]? = nil,
                        input: String? = nil,
                        qualityOfService: QualityOfService? = nil,
                        cancellation: @Sendable () -> Bool = { false }) -> Result {
        guard !cancellation() else {
            return Result(stdout: "", stderr: "", exitCode: nil, timedOut: false, launchError: nil, cancelled: true)
        }
        let initialChildCPU = childCPU()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let qualityOfService { process.qualityOfService = qualityOfService }
        // Merged, not replaced: a command that loses PATH and HOME behaves
        // differently from the one the user would run in their own shell.
        // Secrets belong here rather than in `args`, which the process table
        // shows to everyone on the machine.
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Anything secret belongs here rather than in `args`: the process
        // table is readable, and a password passed as an argument is visible
        // for as long as the command runs.
        let stdinPipe = input.map { _ in Pipe() }
        if let stdinPipe { process.standardInput = stdinPipe }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "", exitCode: nil,
                          timedOut: false, launchError: error.localizedDescription)
        }

        // Nonblocking descriptors keep *all* I/O inside the same deadline.
        // A blocking FileHandle.write before draining stdout can deadlock even
        // when the child has a timeout. Descendants can keep inherited pipes
        // open after the direct child has exited, so EOF is bounded too.
        let outputCap = min(32 * 1_024 * 1_024, outputLimit > 0 ? outputLimit : 4 * 1_024 * 1_024)
        let stdout = CapturedData()
        let stderr = CapturedData()
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        let inFD = stdinPipe?.fileHandleForWriting.fileDescriptor
        for fd in [outFD, errFD] + (inFD.map { [$0] } ?? []) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        if let inFD { _ = fcntl(inFD, F_SETNOSIGPIPE, 1) }
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
        }
        let inputData = input.map { Data($0.utf8) } ?? Data()
        var inputOffset = 0
        var inputOpen = inFD != nil
        var stdoutOpen = true
        var stderrOpen = true
        var didTimeOut = false
        var wasCancelled = false
        let duration = timeout.map { $0.isFinite ? max(0, $0) : 0 } ?? 30
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        func drain(_ fd: Int32, into capture: CapturedData) -> Bool {
            // Limit each pass so endless output cannot starve deadline checks.
            for _ in 0..<8 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    capture.append(Data(buffer.prefix(count)), limit: outputCap)
                } else if count == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else {
                    return errno == EAGAIN || errno == EWOULDBLOCK
                }
            }
            return true
        }

        while true {
            if cancellation() { wasCancelled = true; break }
            if stdoutOpen { stdoutOpen = drain(outFD, into: stdout) }
            if stderrOpen { stderrOpen = drain(errFD, into: stderr) }
            if inputOpen, let inFD {
                if inputOffset < inputData.count {
                    let count = inputData.withUnsafeBytes { bytes in
                        Darwin.write(inFD, bytes.baseAddress!.advanced(by: inputOffset),
                                     min(16 * 1_024, inputData.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count }
                    else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        inputOpen = false
                    }
                }
                if inputOffset == inputData.count { inputOpen = false }
                if !inputOpen { try? stdinPipe?.fileHandleForWriting.close() }
            }
            if !process.isRunning && !stdoutOpen && !stderrOpen { break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { didTimeOut = true; break }
            var descriptors = [pollfd]()
            if stdoutOpen { descriptors.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if stderrOpen { descriptors.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
            if inputOpen, let inFD { descriptors.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            _ = poll(&descriptors, nfds_t(descriptors.count), Int32(min(20, max(1, remaining * 1_000))))
        }

        if (didTimeOut || wasCancelled) && process.isRunning {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.15) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 0.25)
            }
        }

        func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

        let status = process.isRunning ? nil : process.terminationStatus
        let capturedOut = stdout.get(), capturedError = stderr.get()
        return Result(stdout: string(capturedOut.data),
                      stderr: string(capturedError.data),
                      exitCode: status,
                      timedOut: didTimeOut,
                      launchError: nil, cancelled: wasCancelled,
                      childCPUSeconds: initialChildCPU.flatMap { before in childCPU().map { max(0, $0 - before) } },
                      stdoutTruncated:capturedOut.truncated,stderrTruncated:capturedError.truncated)
    }

    /// Cumulative CPU of waited-for children. Concurrent child work is charged
    /// conservatively too; this is not exclusive per-command attribution.
    private static func childCPU() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_CHILDREN, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Convenience for value-producing commands. A failed or timed-out command
    /// has no value, even if it printed plausible text before failing.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil) -> String? {
        let result = execute(path, args, timeout: timeout)
        return result.completeOutput ? result.stdout : nil
    }
}
