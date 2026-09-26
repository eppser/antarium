import Foundation
import Darwin
import Testing
@testable import Antarium

@Suite("Private atomic file output")
struct PrivateFileTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-output-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    @Test("New and replaced snapshots are private, complete and leave no temporary files")
    func privateReplacement() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("report.json")
        try PrivateFile.write(Data("first".utf8),to:file)
        try PrivateFile.write(Data("second".utf8),to:file)
        #expect(try String(contentsOf:file,encoding:.utf8) == "second")
        let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path) == ["report.json"])
    }
    @Test("Size rejection and concurrent edits preserve the existing destination")
    func preserveEdits() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("report.json")
        try Data("original".utf8).write(to:file)
        #expect(throws:(any Error).self) { try PrivateFile.write(Data(repeating:1,count:20),to:file,maxBytes:10) }
        #expect(try String(contentsOf:file,encoding:.utf8) == "original")
        #expect(throws:(any Error).self) {
            try PrivateFile.write(Data("replacement".utf8),to:file) { try Data("external edit".utf8).write(to:file) }
        }
        #expect(try String(contentsOf:file,encoding:.utf8) == "external edit")
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path) == ["report.json"])
    }
    @Test("Symlinks and special-file destinations are rejected without following or replacing them")
    func specialFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("target.data"), link = root.appendingPathComponent("report.json")
        try Data("original".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        #expect(throws:(any Error).self) { try PrivateFile.write(Data("new".utf8),to:link) }
        #expect(try String(contentsOf:target,encoding:.utf8) == "original")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath:link.path) == target.path)
        let fifo = root.appendingPathComponent("report.pipe")
        #expect(mkfifo(fifo.path,0o600) == 0)
        #expect(throws:(any Error).self) { try PrivateFile.write(Data("new".utf8),to:fifo) }
    }
    @Test("A user-selected directory alias resolves once while the output file remains protected")
    func directoryAlias() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("destination"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:target)
        try PrivateFile.write(Data("report".utf8),to:alias.appendingPathComponent("report.json"))
        #expect(try String(contentsOf:target.appendingPathComponent("report.json"),encoding:.utf8) == "report")
    }

    @Test("The macOS temporary-directory alias is a valid explicit save destination")
    func systemTemporaryAlias() throws {
        let file = URL(fileURLWithPath:"/tmp/antarium-private-fixture-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at:file) }
        try PrivateFile.write(Data("synthetic".utf8),to:file)
        #expect(try String(contentsOf:file,encoding:.utf8) == "synthetic")
    }

    @Test("Embedded NUL characters cannot alias a different output filename")
    func nullFilename() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let original = root.appendingPathComponent("report")
        try Data("original".utf8).write(to:original)
        let ambiguous = URL(fileURLWithPath:root.path + "/report\0suffix.json")
        #expect(throws:(any Error).self) { try PrivateFile.write(Data("replacement".utf8),to:ambiguous) }
        #expect(try String(contentsOf:original,encoding:.utf8) == "original")
    }

}
