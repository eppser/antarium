import Foundation
import CoreFoundation
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
        guard let entries = try? BoundedDirectory.entries(directory) else { return nil }
        let files = entries.filter { BoundedGlob.component($0.url.lastPathComponent, matches: glob) }.map(\.url)
        guard !files.isEmpty, files.count <= 64 else { return nil }

        var foundIDs = Set<String>()
        var readAny = false
        var bytesRead = 0
        for file in files {
            guard bytesRead < 8 * 1_024 * 1_024,
                  let data = try? BoundedFile.read(file, maxBytes:min(4 * 1_024 * 1_024,8 * 1_024 * 1_024 - bytesRead)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var value = FieldPath.lookup(root, recordsPath)
            else { return nil }
            bytesRead += data.count

            if selection.decodesEmbeddedJSON, let text = value as? String {
                guard let decoded = try? JSONSerialization.jsonObject(
                    with: Data(text.utf8)) else { return nil }
                value = decoded
            }
            guard let records = value as? [[String: Any]] else { return nil }
            readAny = true
            guard let ids = ids(in: records, selection: selection) else { return nil }
            foundIDs.formUnion(ids)
        }
        return readAny ? foundIDs : nil
    }

    private static func sqliteIDs(_ selection: HarnessDescriptor.Selection) -> Set<String>? {
        guard let path = selection.path?.expandingTilde,
              let query = selection.query, !query.isEmpty else { return nil }
        guard let result = try? BoundedSQLite.query(path:path,sql:query) else { return nil }
        let index:Int
        if let wanted = selection.column {
            guard result.columns.filter({ $0 == wanted }).count == 1,
                  let found = result.columns.firstIndex(of:wanted) else { return nil }
            index = found
        } else { index = 0 }
        var ids:Set<String> = []
        for row in result.rows {
            guard index < row.count, let id = row[index].string, !id.isEmpty else { return nil }
            ids.insert(id)
        }
        return ids
    }

    private static func commandIDs(_ selection: HarnessDescriptor.Selection) -> Set<String>? {
        guard let command = selection.command,
              let executable = resolve(command) else { return nil }
        let result = Shell.execute(executable, selection.args ?? [], timeout: 10)
        guard result.completeOutput,
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
                            selection: HarnessDescriptor.Selection) -> Set<String>? {
        guard records.count <= 4_096, let idPath = selection.id else { return nil }
        var result:Set<String> = []
        for record in records {
            let accepted = (selection.filter ?? [:]).allSatisfy { path, values in
                guard let raw = FieldPath.lookup(record, path) else { return false }
                let text: String
                switch raw {
                case let value as String: text = value
                case let value as NSNumber:
                    text = CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : value.stringValue
                default: return false
                }
                return values.contains(text)
            }
            guard accepted else { continue }
            guard let id = FieldPath.string(record,idPath), !id.isEmpty, id.utf8.count <= 1_024 else { return nil }
            result.insert(id)
        }
        return result
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

}
