import Foundation
import Testing
@testable import Antarium

/// Every setting is written and read under the same name.
///
/// A settings key is a string in two places: where it is stored and where it
/// is read back. Nothing connects them, so renaming one leaves a preference
/// that saves and never takes effect — the toggle moves, the file changes,
/// and the app carries on as before. There is no crash and no message.
///
/// This is the same hazard AGENTS.md records for logic keyed on a string the
/// user reads, one layer down: logic keyed on a string the *file* holds.
@Suite("Settings keys are written and read under one name")
struct SettingsKeyTests {

    private func sources() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var text = ""
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files { text += try String(contentsOf: file, encoding: .utf8) + "\n" }
        return text
    }

    /// The literal, or its fixed prefix where the key is built from one — a
    /// sound's key is "soundName." plus the event's own name, and the prefix
    /// is the part that has to match.
    private func keys(_ text: String, pattern: String) -> Set<String> {
        var found: Set<String> = []
        var search = text[...]
        while let match = search.range(of: pattern, options: .regularExpression) {
            let rest = search[match.upperBound...]
            if let quote = rest.firstIndex(of: "\"") {
                let key = String(rest[..<quote])
                // A key assembled from an interpolation keeps its prefix.
                if let slash = key.range(of: "\\(") {
                    found.insert(String(key[..<slash.lowerBound]))
                } else if !key.isEmpty {
                    found.insert(key)
                }
            }
            search = search[match.upperBound...]
        }
        return found
    }

    /// Read but never written by the app: a person edits these into
    /// config.json by hand. Named here so the list is a decision rather than
    /// whatever happened to be left over.
    private let handEdited: Set<String> = ["logLevel", "panelDarkness"]

    @Test("Every key the app writes is read back under the same name")
    func writtenKeysAreRead() throws {
        let text = try sources()
        let written = keys(text, pattern: "Config\\.set\\(\"")
        let read = keys(text, pattern: "Config\\.(?:string|int|double|bool|doubles|strings)\\(\"")
        #expect(written.count >= 15,
                Comment(rawValue: "only \(written.count) written keys were found"))
        let orphans = written.subtracting(read).sorted()
        #expect(orphans.isEmpty,
                Comment(rawValue: "written and never read, so the setting never takes "
                        + "effect: \(orphans.joined(separator: ", "))"))
    }

    @Test("Every key the app reads is one it writes, or one a person edits")
    func readKeysAreWritten() throws {
        let text = try sources()
        let written = keys(text, pattern: "Config\\.set\\(\"")
        let read = keys(text, pattern: "Config\\.(?:string|int|double|bool|doubles|strings)\\(\"")
        let unexplained = read.subtracting(written).subtracting(handEdited).sorted()
        #expect(unexplained.isEmpty,
                Comment(rawValue: "read and never written, and not listed as hand-edited: "
                        + "\(unexplained.joined(separator: ", "))"))
    }

    /// And the hand-edited list is not a way to excuse a typo: each of them
    /// has to actually be read somewhere.
    @Test("Each key excused as hand-edited is really read", arguments: ["logLevel", "panelDarkness"])
    func handEditedKeysAreRead(key: String) throws {
        let text = try sources()
        let read = keys(text, pattern: "Config\\.(?:string|int|double|bool|doubles|strings)\\(\"")
        #expect(read.contains(key),
                Comment(rawValue: "\(key) is listed as hand-edited and nothing reads it"))
    }
}
