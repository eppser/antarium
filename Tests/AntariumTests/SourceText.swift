import Foundation
import Testing

/// Reading a declaration out of the sources, for the tests that assert about
/// code they cannot execute.
///
/// Every one of them used to take a fixed number of characters after an
/// anchor, which is a guess about how far away the thing it is looking for
/// sits. The guesses were wrong in both directions: one window of 1,600
/// characters needed 1,641 and failed the gate, and one of 400 could not
/// reach the `.fixedSize(` it was asserting the absence of, 776 characters
/// away — so it passed by not looking, and would have gone on passing if the
/// modifier came back anywhere but the line it was mutated onto.
///
/// A window has to be bounded by the thing it is reading.
enum SourceText {

    /// A file under `Sources`, by its path from the package root.
    static func read(_ path: String, from file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// From `marker` to the end of the block it opens, by counting braces.
    /// A marker that opens no block returns the rest of its own line.
    static func block(_ marker: String, in text: String) throws -> String {
        let start = try #require(text.range(of: marker),
                                 Comment(rawValue: "\(marker) is no longer in these sources"))
        var out = "", depth = 0, opened = false
        for line in text[start.lowerBound...].split(separator: "\n",
                                                    omittingEmptySubsequences: false) {
            out += line + "\n"
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if line.contains("{") { opened = true }
            if opened && depth <= 0 { return out }
            if out.count > 20_000 { return out }
        }
        return out
    }

    /// One expression and the modifiers chained onto it: from `marker` to the
    /// first line that is neither a continuation nor a comment. This is what
    /// "the declaration" means for a SwiftUI view, where the thing being
    /// asserted about is usually a modifier several lines below.
    static func chain(_ marker: String, in text: String) throws -> String {
        let start = try #require(text.range(of: marker),
                                 Comment(rawValue: "\(marker) is no longer in these sources"))
        var out = "", depth = 0, seen = false
        for line in text[start.lowerBound...].split(separator: "\n",
                                                    omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if seen, depth <= 0,
               !trimmed.hasPrefix("."), !trimmed.hasPrefix("//"), !trimmed.isEmpty,
               !trimmed.hasPrefix("}") {
                return out
            }
            out += line + "\n"
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            seen = true
            if out.count > 20_000 { return out }
        }
        return out
    }
}
