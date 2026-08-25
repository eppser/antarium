import Foundation

/// Folds an append-only journal back into the document it describes.
///
/// VS Code writes a chat session as one snapshot (`kind` 0) followed by patches
/// that either set (`kind` 1) or append to (`kind` 2) a path given as `k`.
/// Read a line at a time — which is what every other JSONL harness wants — the
/// fields a descriptor asks for are simply not there: the snapshot is written
/// when the session is empty, and the title, the model and every token count
/// arrive later as patches. So the lines are folded first, and the descriptor's
/// paths are mapped against the result exactly as if the file had been one
/// object all along.
enum Journal {
    static func fold(_ lines: [[String: Any]]) -> [String: Any] {
        var document: [String: Any] = [:]
        for line in lines {
            let kind = line["kind"] as? Int ?? 0
            if kind == 0 {
                document = line["v"] as? [String: Any] ?? document
                continue
            }
            guard let path = line["k"] as? [Any], !path.isEmpty else { continue }
            document = write(document, path[...], line["v"], append: kind == 2)
                as? [String: Any] ?? document
        }
        return document
    }

    /// `append` is the `kind` 2 case: the value is a list of new elements for
    /// the array at that path, not a replacement for it.
    private static func write(_ node: Any?, _ path: ArraySlice<Any>,
                              _ value: Any?, append: Bool) -> Any? {
        guard let head = path.first else {
            guard append else { return value }
            let existing = node as? [Any] ?? []
            return existing + ((value as? [Any]) ?? [])
        }
        let rest = path.dropFirst()
        if let key = head as? String {
            var dictionary = node as? [String: Any] ?? [:]
            dictionary[key] = write(dictionary[key], rest, value, append: append)
            return dictionary
        }
        if let index = head as? Int, index >= 0, index < 10_000 {
            var array = node as? [Any] ?? []
            // A patch can name an element the snapshot never carried.
            while array.count <= index { array.append([String: Any]()) }
            array[index] = write(array[index], rest, value, append: append) ?? array[index]
            return array
        }
        return node
    }
}
