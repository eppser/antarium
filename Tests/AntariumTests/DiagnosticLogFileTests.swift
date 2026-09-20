import Darwin
import Foundation
import Testing
@testable import Antarium

@Suite("Bounded private diagnostic log files")
struct DiagnosticLogFileTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("log-file-fixture-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    @Test("Log writes cannot follow a linked destination")
    func linkedFile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("target.txt"), log = root.appendingPathComponent("antarium.log")
        try Data("keep synthetic content".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:log,withDestinationURL:target)
        #expect(!DiagnosticLogFile(directory:root).append("synthetic log message\n"))
        #expect(try String(contentsOf:target,encoding:.utf8) == "keep synthetic content")
    }
    @Test("Logs are private, bounded and newline-normalized")
    func privateBounded() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let sink = DiagnosticLogFile(directory:root)
        #expect(sink.append(String(repeating:"x",count:100_000) + "\ninjected line\n"))
        let file = root.appendingPathComponent("antarium.log")
        let data = try Data(contentsOf:file)
        #expect(data.count <= 8_192)
        #expect(data.filter { $0 == 10 }.count == 1)
        var info = stat(); #expect(lstat(file.path,&info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }
    @Test("Rotation never recursively removes a directory at the previous-log path")
    func preservePreviousDirectory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let previous = root.appendingPathComponent("antarium.1.log")
        try FileManager.default.createDirectory(at:previous,withIntermediateDirectories:true)
        let note = previous.appendingPathComponent("user-note.txt"); try Data("preserve".utf8).write(to:note)
        let sink = DiagnosticLogFile(directory:root,maximumBytes:1_024)
        for _ in 0..<20 { _ = sink.append(String(repeating:"x",count:600)) }
        #expect(FileManager.default.fileExists(atPath:note.path))
        let size = (try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("antarium.log").path)[.size] as? Int) ?? 0
        #expect(size <= 1_024)
    }
    @Test("Tail reads reject invalid counts and do not expose an unbounded line")
    func tailBounds() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("fixture.log")
        try Data((String(repeating:"x",count:200_000) + "\nlast synthetic line\n").utf8).write(to:file)
        #expect(throws:(any Error).self) { try DiagnosticLogFile.tail(file,lineCount:-1) }
        #expect(throws:(any Error).self) { try DiagnosticLogFile.tail(file,lineCount:1_001) }
        let tail = try DiagnosticLogFile.tail(file,lineCount:40)
        #expect(tail.truncated)
        #expect(tail.lines == ["last synthetic line"])
        #expect(try DiagnosticLogFile.tail(file,lineCount:0).lines.isEmpty)
    }
    @Test("Unavailable or linked log reads are not reported as an empty successful tail")
    func tailErrors() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("target.log"), link = root.appendingPathComponent("link.log")
        try Data("synthetic".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        #expect(throws:(any Error).self) { try DiagnosticLogFile.tail(link,lineCount:40) }
        #expect(throws:(any Error).self) { try DiagnosticLogFile.tail(root.appendingPathComponent("missing"),lineCount:40) }
    }
    @Test("Concurrent log messages stay complete and readable")
    func concurrentMessages() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let sink = DiagnosticLogFile(directory:root)
        DispatchQueue.concurrentPerform(iterations:200) { index in
            _ = sink.append("synthetic message \(index)")
        }
        let tail = try DiagnosticLogFile.tail(root.appendingPathComponent("antarium.log"),lineCount:1_000)
        #expect(tail.lines.count == 200,"Last failure: \(sink.lastFailure ?? "none")")
        #expect(Set(tail.lines).count == 200)
        #expect(!tail.truncated)
    }
    @Test("Both log generations stay bounded and private during ordinary rotation")
    func rotation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let sink = DiagnosticLogFile(directory:root,maximumBytes:1_024)
        for index in 0..<50 { #expect(sink.append("entry \(index) " + String(repeating:"é",count:250))) }
        for name in ["antarium.log","antarium.1.log"] {
            let file = root.appendingPathComponent(name)
            var info = stat(); #expect(lstat(file.path,&info) == 0)
            #expect(info.st_size <= 1_024)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(try DiagnosticLogFile.tail(file,lineCount:1_000).lines.count > 0)
        }
    }
    @Test("Special files and hard links are rejected without changing their targets")
    func specialFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let log = root.appendingPathComponent("antarium.log")
        #expect(mkfifo(log.path,0o600) == 0)
        #expect(!DiagnosticLogFile(directory:root).append("synthetic"))
        #expect(throws:(any Error).self) { try DiagnosticLogFile.tail(log,lineCount:40) }
        try FileManager.default.removeItem(at:log)
        let target = root.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to:target)
        #expect(link(target.path,log.path) == 0)
        #expect(!DiagnosticLogFile(directory:root).append("synthetic"))
        #expect(try String(contentsOf:target,encoding:.utf8) == "keep")
    }

}
