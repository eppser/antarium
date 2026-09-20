import Foundation
import Testing
@testable import Antarium

@Suite("SSH discovery input and result boundaries")
struct RemoteBoundaryTests {
    @Test("Host destinations reject controls and oversized values", arguments:[
        "fixture\u{0}ignored", "fixture\u{1}host", "fixture\u{7}host", "fixture\u{7f}host",
        String(repeating:"a",count:1_025)
    ])
    func hostBoundary(_ host: String) { #expect(!RemoteTmux.isSafeHost(host)) }

    @Test("SSH diagnostics explain a failure without copying remote text")
    func diagnosticPrivacy() {
        let inputs = [
            "ssh: fixture-user@fixture-host: Permission denied; API_KEY=fixture-secret",
            "ssh: Could not resolve hostname fixture-secret: nodename not found",
            "ssh: connect to host fixture-secret port 22: Connection refused",
            "Host key verification failed for /fixture/fixture-secret",
            "Connection timed out: fixture-secret",
            "No route to host fixture-secret"
        ]
        for input in inputs {
            let reason = RemoteTmux.sshReason(input)
            #expect(reason != nil)
            #expect(reason?.contains("fixture") == false)
        }
    }
    @Test("Cancellation cannot turn partial discovery output into a successful scan")
    func cancelledReply() {
        let answer = Shell.Result(stdout:RemoteTmux.psSeparator + "\n",stderr:"",exitCode:0,
            timedOut:false,launchError:nil,cancelled:true)
        #expect(!RemoteTmux.usable(answer))
    }
}
