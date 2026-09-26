import Foundation

/// Folds an append-only journal back into the document it describes.
///
/// VS Code writes a chat session as one snapshot (`kind` 0) followed by patches
/// against a path given as `k`: set (`kind` 1), push onto an array (`kind` 2,
/// with an optional `i` that truncates it first), or delete (`kind` 3).
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
            else if let declared = line["kind"] as? Int, (0...3).contains(declared) {
                kind = declared
            } else { continue }

            if kind == 0 {
                document = line["v"] as? [String: Any] ?? document
                continue
            }
            guard let path = line["k"] as? [Any], !path.isEmpty else { continue }
            if kind == 3 {
                // Removing what the session removed. Ignoring a delete leaves
                // the element in the folded document, and for a chat session
                // that means the tokens of a request the user took back are
                // still counted.
                document = remove(document, path[...]) as? [String: Any] ?? document
                continue
            }
            // A push can carry `i`, which truncates the array at that index
            // before appending — VS Code splices rather than appends when a
            // request is retried or edited. Ignored, the replaced requests
            // stayed in the document alongside the ones that replaced them,
            // and their usage was counted twice.
            let truncate = (line["i"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            document = write(document, path[...], line["v"],
                             append: kind == 2, truncate: truncate)
                as? [String: Any] ?? document
        }
        return document
    }

    /// Whether a path component may build here.
    ///
    /// Absent is created — the snapshot is written when the session is empty, so
    /// nearly every path in a folded document is built by a patch. Present and
    /// the wrong shape is left alone: a patch naming an index where the document
    /// holds an object is describing a document this is not, and building the
    /// array anyway discarded the object and left a descriptor summing figures
    /// over a structure the file never contained.
    ///
    /// Named, rather than written inline three times, because `remove` has always
    /// had this guard and `write` had none — the same file disagreeing with
    /// itself about the same question in two places.
    static func mayBuildObject(_ node: Any?) -> Bool { node == nil || node is [String: Any] }
    static func mayBuildArray(_ node: Any?) -> Bool { node == nil || node is [Any] }

    /// `append` is the `kind` 2 case: the value is a list of new elements for
    /// the array at that path, not a replacement for it.
    private static func write(_ node: Any?, _ path: ArraySlice<Any>,
                              _ value: Any?, append: Bool,
                              truncate: Int? = nil) -> Any? {
        guard let head = path.first else {
            // A set replaces whatever is there; that is what a set is for.
            guard append else { return value }
            // A push does not. Pushing onto something that is not an array used
            // to discard it and leave the pushed elements in its place, which is
            // the same reshaping the two guards below refuse one level up.
            guard mayBuildArray(node) else { return node }
            let existing = node as? [Any] ?? []
            // `i` past the end truncates nothing, which is the same as a push
            // with no index at all.
            let kept = truncate.map { Array(existing.prefix($0)) } ?? existing
            return kept + ((value as? [Any]) ?? [])
        }
        let rest = path.dropFirst()
        // Absent is created; present and the wrong shape is left alone.
        //
        // These two guards were missing, and `remove` in this same file has
        // always had them — so a delete refused to reshape the document and a
        // set was free to. A patch naming `["requests", 0]` where the snapshot
        // put an *object* at `requests` discarded that object and built an array
        // in its place, and a descriptor's `requests[].promptTokens` then summed
        // figures over a structure the file never contained. Creating what is
        // absent is the ordinary case and is untouched: the snapshot is written
        // when the session is empty, so nearly every path is built by a patch.
        if let key = head as? String {
            guard mayBuildObject(node) else { return node }
            var dictionary = node as? [String: Any] ?? [:]
            dictionary[key] = write(dictionary[key], rest, value, append: append,
                                    truncate: truncate)
            return dictionary
        }
        if let index = head as? Int, index >= 0, index < 10_000 {
            guard mayBuildArray(node) else { return node }
            var array = node as? [Any] ?? []
            // A patch can name an element the snapshot never carried.
            while array.count <= index { array.append([String: Any]()) }
            array[index] = write(array[index], rest, value, append: append,
                                 truncate: truncate) ?? array[index]
            return array
        }
        return node
    }

    /// Removes whatever `path` names: a key from an object, an element from an
    /// array.
    ///
    /// A path naming something that is not there is not an error — the delete
    /// has already happened as far as the folded document is concerned.
    private static func remove(_ node: Any?, _ path: ArraySlice<Any>) -> Any? {
        // `fold` refuses an empty path and the recursion below never empties one
        // — a key or index with nothing after it is handled without recursing —
        // so this cannot be reached. Kept rather than removed because it is the
        // base case of the shape, and a reader following the recursion looks for
        // it; noted rather than given a catalogue entry, because an entry for it
        // could only ever survive.
        guard let head = path.first else { return nil }
        let rest = path.dropFirst()
        if let key = head as? String {
            guard var dictionary = node as? [String: Any] else { return node }
            if rest.isEmpty { dictionary.removeValue(forKey: key) }
            else if let child = dictionary[key] {
                dictionary[key] = remove(child, rest)
                if dictionary[key] == nil { dictionary.removeValue(forKey: key) }
            }
            return dictionary
        }
        if let index = head as? Int, index >= 0 {
            guard var array = node as? [Any], index < array.count else { return node }
            if rest.isEmpty { array.remove(at: index) }
            else { array[index] = remove(array[index], rest) ?? array[index] }
            return array
        }
        return node
    }
}
