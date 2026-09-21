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
            // Absent means a snapshot: the format omits `kind` for the first
            // line. Present and unreadable is a different thing, and so is a
            // kind this does not know — VS Code is free to add one. Both used
            // to be guessed at: a non-integer kind fell to 0 and replaced the
            // whole document with a patch's payload, and an unknown number
            // fell through to the `set` path and wrote it somewhere. Applying
            // an operation nothing understood is how a folded document ends
            // up carrying figures that were never in the file.
            //
            // Skipped instead. The fields the patch would have set are then
            // simply absent, which every reader downstream already has an
            // answer for.
            let kind: Int
            if line["kind"] == nil { kind = 0 }
            else if let declared = line["kind"] as? Int, (0...2).contains(declared) {
                kind = declared
            } else { continue }

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
