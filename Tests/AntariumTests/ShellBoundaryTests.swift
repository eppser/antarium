import Foundation
import Testing
@testable import Antarium

@Suite("Subprocess deadline and pipe boundaries", .serialized)
struct ShellBoundaryTests {
    @Test("A descendant holding stdout cannot outlive the command deadline")
    func inheritedPipe() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = Shell.execute("/bin/sh", ["-c", "sleep 1 & printf parent-done"], timeout: 0.1)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.7)
        #expect(result.stdout == "parent-done")
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("Blocked stdin delivery is included in the command deadline")
    func blockedInput() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = Shell.execute("/bin/sh", ["-c", "sleep 1; cat >/dev/null"], timeout: 0.1,
                                   input: String(repeating: "x", count: 256 * 1_024))
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.7)
        #expect(result.timedOut)
    }

    @Test("An early stdin close is handled without terminating the monitor")
    func earlyInputClose() {
        let result = Shell.execute("/bin/sh", ["-c", "exec 0<&-; printf done"], timeout: 1,
                                   input: "small input")
        #expect(result.stdout == "done")
        #expect(result.exitCode == 0)
    }

    @Test("Both output streams drain while stdin is delivered")
    func simultaneousIO() {
        let input = String(repeating: "a", count: 256 * 1_024)
        let result = Shell.execute("/bin/cat", [], timeout: 2, outputLimit: 1_024, input: input)
        #expect(result.succeeded)
        #expect(result.stdout == String(repeating: "a", count: 1_024))
    }

    private final class StopFlag: @unchecked Sendable {
        let lock = NSLock()
        private var value = false
        func stop() { lock.lock(); value = true; lock.unlock() }
        func stopped() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    @Test("Cancellation terminates an owned subprocess and cannot publish success")
    func cancellation() {
        let flag = StopFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flag.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        let result = Shell.execute("/bin/sleep", ["2"], timeout: 5, cancellation: { flag.stopped() })
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.7)
        #expect(result.cancelled)
        #expect(!result.succeeded)
        #expect(!result.timedOut)
    }
}
