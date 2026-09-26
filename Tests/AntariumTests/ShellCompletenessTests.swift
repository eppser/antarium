import Foundation
import Testing
@testable import Antarium

@Suite("Subprocess output completeness")
struct ShellCompletenessTests {
    @Test("Clipping is reported even when the process exits successfully")
    func clipped() {
        let result = Shell.execute("/bin/cat",[],timeout:2,outputLimit:64,input:String(repeating:"x",count:1_024))
        #expect(result.succeeded)
        #expect(result.stdoutTruncated)
        #expect(!result.stderrTruncated)
        #expect(result.stdout.utf8.count == 64)
        let exact = Shell.execute("/bin/cat",[],timeout:2,outputLimit:64,input:String(repeating:"x",count:64))
        #expect(!exact.stdoutTruncated)
    }
    @Test("Value-producing convenience commands cannot publish incomplete output")
    func incompleteValue() {
        let gotValue = Shell.run("/usr/bin/head",["-c","5000000","/dev/zero"],timeout:3) != nil
        #expect(!gotValue)
    }
}
