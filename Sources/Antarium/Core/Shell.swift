import Darwin
import Foundation

/// One truthful subprocess boundary for every configured command.
///
/// Callers that only need a value use run; diagnostics can use execute to
/// distinguish launch failure, non-zero exit and timeout without inventing
/// success from whatever happened to reach stdout.
enum Shell {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32?
        let timedOut: Bool
        let launchError: String?

        var succeeded: Bool {
            launchError == nil && !timedOut && exitCode == 0
        }
    }

    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func append(_ data: Data, limit: Int) {
            lock.lock()
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

        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Executes a process while draining both pipes concurrently. The output
    /// cap is applied while draining so a verbose child can neither deadlock on
    /// a full pipe nor make the monitor retain unbounded output. The diagnostic
    /// suffix is more useful than the prefix for command failures.
    static func execute(_ path: String, _ args: [String],
                        timeout: TimeInterval? = nil,
                        outputLimit: Int = 4 * 1_024 * 1_024,
                        environment: [String: String]? = nil,
                        input: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
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

        if let stdinPipe, let input {
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let reads = DispatchGroup()
        let stdout = CapturedData()
        let stderr = CapturedData()
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let chunk = handle.readData(ofLength: 64 * 1_024)
                guard !chunk.isEmpty else { break }
                stdout.append(chunk, limit: outputLimit)
            }
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let chunk = handle.readData(ofLength: 64 * 1_024)
                guard !chunk.isEmpty else { break }
                stderr.append(chunk, limit: outputLimit)
            }
            reads.leave()
        }

        var didTimeOut = false
        if let timeout {
            didTimeOut = terminated.wait(timeout: .now() + max(0, timeout)) == .timedOut
        } else {
            terminated.wait()
        }

        if didTimeOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.15) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 0.25)
            }
            // A grandchild may still hold a duplicated pipe descriptor. Closing
            // our read ends keeps the timeout a hard upper bound for this scan.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = reads.wait(timeout: .now() + 0.1)
        } else {
            reads.wait()
        }

        func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

        let status = process.isRunning ? nil : process.terminationStatus
        return Result(stdout: string(stdout.get()),
                      stderr: string(stderr.get()),
                      exitCode: status,
                      timedOut: didTimeOut,
                      launchError: nil)
    }

    /// Convenience for value-producing commands. A failed or timed-out command
    /// has no value, even if it printed plausible text before failing.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval? = nil) -> String? {
        let result = execute(path, args, timeout: timeout)
        return result.succeeded ? result.stdout : nil
    }
}
