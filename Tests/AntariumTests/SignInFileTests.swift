import Foundation
import Testing
@testable import Antarium

@Suite("Private sign-in launch files")
struct SignInFileTests {
    @Test("Concurrent sign-in preparations use distinct private executable files and omit commands from logs")
    func distinctPrivateScripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-fixture-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var files:[URL] = []
        let logs = try Log.capture {
            files.append(try SignIn.prepare("printf fixture-private-command",label:"fixture-private-label",directory:root))
            files.append(try SignIn.prepare("printf fixture-other-command",label:"Synthetic",directory:root))
        }
        #expect(Set(files).count == 2)
        for file in files {
            let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o700)
        }
        #expect(!logs.joined().contains("fixture-private"))
        #expect(try String(contentsOf:files[0],encoding:.utf8).contains("fixture-private-command"))
    }
    @Test("The generated launcher removes its temporary script before starting the configured command")
    func removesOwnScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-execution-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var prepared:URL?
        _ = try Log.capture { prepared = try SignIn.prepare("/usr/bin/printf synthetic-success",label:"Synthetic",directory:root) }
        let file = try #require(prepared)
        let result = Shell.execute("/bin/bash",[file.path],timeout:3,environment:["SHELL":"/bin/bash"])
        #expect(result.completeOutput)
        #expect(result.stdout.contains("synthetic-success"))
        #expect(!FileManager.default.fileExists(atPath:file.path))
    }
    @Test("Standalone script formatting never deletes a caller-supplied argv zero")
    func standaloneDoesNotDeleteCallerFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-standalone-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let unrelated = root.appendingPathComponent("unrelated-fixture")
        try Data("keep this synthetic file".utf8).write(to:unrelated)
        let script = SignIn.script("/usr/bin/printf synthetic-success",label:"Synthetic")
        let result = Shell.execute("/bin/bash",["-c",script,unrelated.path],timeout:3,environment:["SHELL":"/bin/bash"])
        #expect(result.completeOutput)
        #expect(FileManager.default.fileExists(atPath:unrelated.path))
    }

    @Test("Cleanup insertion preserves a command that itself contains a shebang string")
    func commandContentIsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-content-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let expected = "fixture-start\n#!/bin/bash\nfixture-end"
        var prepared:URL?
        _ = try Log.capture { prepared = try SignIn.prepare("/usr/bin/printf '%s' '" + expected + "'",label:"Synthetic",directory:root) }
        let file = try #require(prepared)
        let result = Shell.execute("/bin/bash",[file.path],timeout:3,environment:["SHELL":"/bin/bash"])
        #expect(result.completeOutput)
        #expect(result.stdout.hasSuffix(expected))
        #expect(!FileManager.default.fileExists(atPath:file.path))
    }

}
