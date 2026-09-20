import Foundation
import Testing
@testable import Antarium

@Suite("Complete SSH discovery replies")
struct RemoteReplyTests {
    private func reply(tmux:Int = 0,pane:Int = 0,ps:Int = 0,complete:Bool = true,truncated:Bool = false) -> Shell.Result {
        let text = RemoteTmux.psSeparator + "\n" + RemoteTmux.exeSeparator + "\n"
            + RemoteTmux.statusSeparator + ":\(tmux):\(pane):\(ps)\n" + (complete ? RemoteTmux.completionMarker + "\n" : "")
        return Shell.Result(stdout:text,stderr:"",exitCode:0,timedOut:false,launchError:nil,stdoutTruncated:truncated)
    }
    @Test("A complete empty inventory is distinct from interrupted or failed inventory")
    func completion() {
        #expect(RemoteTmux.usable(reply()))
        let lostTransport = Shell.Result(stdout:reply().stdout,stderr:"",exitCode:255,timedOut:false,launchError:nil)
        #expect(!RemoteTmux.usable(lostTransport))
        #expect(!RemoteTmux.usable(reply(complete:false)))
        #expect(!RemoteTmux.usable(reply(ps:1)))
        #expect(!RemoteTmux.usable(reply(pane:1)))
        #expect(!RemoteTmux.usable(reply(tmux:1)))
        #expect(!RemoteTmux.usable(reply(truncated:true)))
        #expect(RemoteTmux.discoveryReplyIssue(reply(ps:1)) != nil)
        #expect(RemoteTmux.discoveryReplyIssue(reply(tmux:1)) != nil)
    }
    @Test("Empty or invalid discovery replies never read installed harness configuration")
    func emptyReplyDoesNotLoadDescriptors() {
        var loads = 0
        for output in ["", "interrupted", reply().stdout] {
            #expect(RemoteTmux.parse(output,host:"fixture",descriptors:{ loads += 1; return [] }).isEmpty)
        }
        #expect(loads == 0)
    }
    @Test("Only authentication failures may request a stored password")
    func authentication() {
        func answer(_ error:String,code:Int32 = 255,cancelled:Bool = false) -> Shell.Result {
            .init(stdout:"",stderr:error,exitCode:code,timedOut:false,launchError:nil,cancelled:cancelled)
        }
        #expect(RemoteTmux.shouldRetryWithPassword(answer("Permission denied (publickey).")))
        #expect(!RemoteTmux.shouldRetryWithPassword(answer("Host key verification failed.")))
        #expect(!RemoteTmux.shouldRetryWithPassword(answer("Host key verification failed. Permission denied.")))
        #expect(!RemoteTmux.shouldRetryWithPassword(answer("Connection refused")))
        #expect(!RemoteTmux.shouldRetryWithPassword(answer("Permission denied",code:1)))
        #expect(!RemoteTmux.shouldRetryWithPassword(answer("Permission denied",cancelled:true)))
    }
    @Test("The exact discovery command records probe failures using only synthetic tools")
    func probeFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("antarium-ssh-probes-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func tool(_ name:String,_ body:String) throws {
            let file = root.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to:file)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
        }
        try tool("tmux","exit 0") // A successful empty pane inventory.
        try tool("ps","exit 2")
        try tool("readlink","exit 1")
        let failed = Shell.execute("/bin/sh",["-c",RemoteTmux.remoteCommand],timeout:2,environment:["PATH":root.path])
        #expect(!RemoteTmux.usable(failed))
        #expect(RemoteTmux.discoveryReplyIssue(failed) != nil)
        try tool("ps","printf '910 1 fixture fixture\\n'")
        let empty = Shell.execute("/bin/sh",["-c",RemoteTmux.remoteCommand],timeout:2,environment:["PATH":root.path])
        #expect(RemoteTmux.usable(empty))
        #expect(RemoteTmux.parse(empty.stdout,host:"fixture").isEmpty)
    }
}
