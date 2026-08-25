import Foundation
import SQLite3

/// Reads the set of sessions a harness says are currently open. The descriptor
/// owns file names, record paths, filters and identifiers; this reader only
/// implements the declared JSON-files strategy.
enum SessionSelection {
    /// Nil means no state could be read. An empty set means state was read and
    /// truthfully contained no matching open sessions.
    static func openIDs(_ selection: HarnessDescriptor.Selection?) -> Set<String>? {
        guard let selection else { return nil }
        switch selection.kind {
        case .jsonFiles:
            return jsonFileIDs(selection)
        case .sqlite:
            return sqliteIDs(selection)
        case .command:
            return commandIDs(selection)
        }
    }

    private static func jsonFileIDs(_ selection: HarnessDescriptor.Selection) -> Set<String>? {
        guard let path = selection.path, let glob = selection.glob,
              let recordsPath = selection.records else { return nil }
        let directory = URL(fileURLWithPath: path.expandingTilde)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { matches($0.lastPathComponent, glob) }
        guard !files.isEmpty else { return nil }

        var foundIDs = Set<String>()
        var readAny = false
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var value = FieldPath.lookup(root, recordsPath)
            else { continue }

            if selection.decodesEmbeddedJSON, let text = value as? String {
                guard let decoded = try? JSONSerialization.jsonObject(
                    with: Data(text.utf8)) else { continue }
                value = decoded
            }
            guard let records = value as? [[String: Any]] else { continue }
            readAny = true
            foundIDs.formUnion(ids(in: records, selection: selection))
        }
        return readAny ? foundIDs : nil
    }

    private static func sqliteIDs(_ selection: HarnessDescriptor.Selection) -> Set<String>? {
        guard let path = selection.path?.expandingTilde,
              let query = selection.query, !query.isEmpty else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        let wanted = selection.column
        var index: Int32 = 0
        if let wanted {
            for candidate in 0..<sqlite3_column_count(statement) {
                if String(cString: sqlite3_column_name(statement, candidate)) == wanted {
                    index = candidate
                    break
                }
            }
        }
        var result = Set<String>()
        var readAny = false
        while sqlite3_step(statement) == SQLITE_ROW {
            readAny = true
            if let text = sqlite3_column_text(statement, index) {
                let id = String(cString: text)
                if !id.isEmpty { result.insert(id) }
            }
        }
        return readAny ? result : []
    }

    private static func commandIDs(_ selection: HarnessDescriptor.Selection) -> Set<String>? {
        guard let command = selection.command,
              let executable = resolve(command) else { return nil }
        let result = Shell.execute(executable, selection.args ?? [], timeout: 10)
        guard result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let value: Any
        if let root = selection.root,
           let dictionary = object as? [String: Any] {
            guard let nested = FieldPath.lookup(dictionary, root) else { return nil }
            value = nested
        } else {
            value = object
        }
        guard let records = value as? [[String: Any]] else { return nil }
        return ids(in: records, selection: selection)
    }

    private static func ids(in records: [[String: Any]],
                            selection: HarnessDescriptor.Selection) -> Set<String> {
        guard let idPath = selection.id else { return [] }
        return Set(records.compactMap { record in
            let accepted = (selection.filter ?? [:]).allSatisfy { path, values in
                guard let raw = FieldPath.lookup(record, path) else { return false }
                let text: String
                switch raw {
                case let value as String: text = value
                case let value as Bool: text = value ? "true" : "false"
                case let value as NSNumber: text = value.stringValue
                default: return false
                }
                return values.contains(text)
            }
            guard accepted, let id = FieldPath.string(record, idPath), !id.isEmpty else {
                return nil
            }
            return id
        })
    }

    private static func resolve(_ command: String) -> String? {
        let expanded = command.expandingTilde
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        return path.split(separator: ":").lazy
            .map { "\($0)/\(expanded)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func matches(_ name: String, _ pattern: String) -> Bool {
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard pieces.count > 1 else { return name == pattern }
        var remainder = name[...]
        if let first = pieces.first, !first.isEmpty {
            guard remainder.hasPrefix(first) else { return false }
            remainder = remainder.dropFirst(first.count)
        }
        for (index, piece) in pieces.dropFirst().enumerated() where !piece.isEmpty {
            if index == pieces.count - 2, !pattern.hasSuffix("*") {
                return remainder.hasSuffix(piece)
            }
            guard let range = remainder.range(of: piece) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return true
    }
}
