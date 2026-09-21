import Foundation

/// `Antarium --check <file>` — an advisor for people writing harness files.
///
/// It exists because both ways a descriptor fails are silent. A file that
/// doesn't parse is skipped with a log line nobody sees; a file that parses but
/// points at the wrong field reports an agent with no data, which looks exactly
/// like an agent that records none. Neither tells you that `modle` isn't
/// `model`.
///
/// So this checks the file against the schema *and* against your real data, and
/// says what it would actually show.
enum HarnessCheck {

    /// Every key the loader understands. The schema's authority lives here, so
    /// anything else in a file is a typo or a leftover.
    private static let known: [String: Set<String>] = [
        "": ["$schema", "formatVersion", "id", "name", "process", "match", "matchProcessName", "source", "map", "quota",
             "capabilities", "selection", "focus", "contributes",
             "idleAfter", "staleAfter", "fallbackName", "mark", "note", "detached",
             "multiSession", "openTabsOnly",
             "enabled", "presentation", "compatibility", "activity"],
        "activity": ["rules", "tools", "remoteTrace"],
        "activity.remoteTrace": ["roots", "glob"],
        "process": ["pathContains", "names", "argv0Contains", "sessionBinding",
                    "installationProbes"],
        "presentation": ["mark", "fallbackName", "sourceLabel"],
        "compatibility": ["level", "verifiedAt", "agentVersions", "fixture", "note"],
        "source": ["kind", "path", "glob", "limit", "query", "columns", "manifest", "filter",
                   "command", "args", "root", "refreshEvery", "paths", "pathFields",
                   "journal"],
        "map": ["cwd", "title", "model", "focusTarget", "contextWindow", "contextTokens", "timestamp",
                "inputTokens", "outputTokens", "cacheRead", "cacheWrite", "cost",
                "toolMarker", "toolWhere", "toolCalls", "turnWhere", "turns", "subAgents", "status", "pid", "sessionID",
                "inputIncludesCacheRead"],
        "quota": ["endpoint", "headers", "credential", "windows", "accountLabel",
                  "setupHint", "signInCommand", "verified"],
        "focus": ["command", "args"],
        "quota.credential": ["kind", "path", "field", "name", "command", "args", "requires"],
        "quota.windows": ["root", "roots", "list", "key", "keys", "single", "balance",
                          "currency", "usedPercent", "percentRemaining",
                          "used", "limit", "require", "labels", "badges", "windowSeconds", "resetsAt",
                          "title"],
        "selection": ["kind", "path", "glob", "records", "encodedJSON", "id", "filter",
                      "query", "column", "command", "args", "root"],
        "source.manifest": ["file", "map"],
        "source.manifest.map": ["cwd", "title", "model", "contextWindow", "contextTokens",
                                "timestamp", "inputTokens", "outputTokens", "cacheRead",
                                "cacheWrite", "cost", "toolMarker", "toolWhere", "toolCalls", "turnWhere", "turns",
                                "subAgents", "status", "pid", "sessionID",
                                "inputIncludesCacheRead"],
        "map.status": ["whileNotEmpty", "field", "working", "idle"],
        "map.turns": ["path", "match"],
        "map.toolCalls": ["path", "match"],
        "map.subAgents": ["path", "match"],
    ]
    private static let kinds: Set<String> = ["jsonl", "json", "sqlite", "command", "none"]

    /// The fields accepted under one path, for the contract test that keeps
    /// this table and `harness.schema.json` from drifting apart. A field the
    /// schema allows but this rejects is reported to the user as a typo in
    /// their own file; one this allows but the schema does not is silently
    /// ignored by every editor that validates against the schema.
    static func knownFields(at path: String) -> Set<String>? { known[path] }

    /// Pure structural validation, shared by the CLI and the regression suite.
    /// JSONDecoder intentionally ignores unknown keys; this is where a typo is
    /// turned into an actionable error instead of silently changing meaning.
    static func schemaProblems(in object: [String: Any]) -> [String] {
        var problems: [String] = []

        func container(_ path: String) -> [String: Any]? {
            if path.isEmpty { return object }
            return FieldPath.lookup(object, path) as? [String: Any]
        }

        func check(_ path: String, _ value: [String: Any], allowed: Set<String>) {
            for key in value.keys.sorted() where !allowed.contains(key) {
                let label = path.isEmpty ? key : "\(path).\(key)"
                if let guess = nearest(key, in: allowed) {
                    problems.append("\(label) is not a field — did you mean \"\(guess)\"?")
                } else {
                    problems.append("\(label) is not a field; it will be ignored")
                }
            }
        }

        for (path, allowed) in known {
            if let value = container(path) { check(path, value, allowed: allowed) }
        }

        if let activity = object["activity"] as? [String: Any] {
            for (index, rule) in ((activity["rules"] as? [[String: Any]]) ?? []).enumerated() {
                check("activity.rules[\(index)]", rule, allowed: ["kind", "match", "recordMatch", "items", "tool", "arguments", "callID", "text", "timestamp", "error", "durationMS"])
            }
            for (name, tool) in (activity["tools"] as? [String: [String: Any]]) ?? [:] {
                check("activity.tools.\(name)", tool, allowed: ["operation", "pathField", "commandField", "argumentFormat", "patchField"])
            }
        }

        let installationProbeFields: Set<String> = [
            "method", "path", "name", "argv0", "expected", "evidence", "verifiedAt",
        ]
        if let process = object["process"] as? [String: Any],
           let probes = process["installationProbes"] as? [[String: Any]] {
            for (index, probe) in probes.enumerated() {
                check("process.installationProbes[\(index)]", probe,
                      allowed: installationProbeFields)
            }
        }

        let capabilityFields: Set<String> = ["probe", "project", "inherited", "index", "keys"]
        let capabilityKinds = Set(Capability.Kind.allCases.map(\.rawValue))
        if let capabilities = object["capabilities"] as? [String: Any] {
            for (kind, raw) in capabilities {
                if !capabilityKinds.contains(kind) {
                    problems.append("capabilities.\(kind) is not a supported capability")
                }
                if let rule = raw as? [String: Any] {
                    check("capabilities.\(kind)", rule, allowed: capabilityFields)
                }
            }
        }

        let pathFieldNames: Set<String> = ["cwd", "title", "model", "sessionID"]
        let pathFieldKeys: Set<String> = ["ancestor", "value"]
        if let source = object["source"] as? [String: Any],
           let fields = source["pathFields"] as? [String: Any] {
            for (field, raw) in fields {
                if !pathFieldNames.contains(field) {
                    problems.append("source.pathFields.\(field) is not a supported session field")
                }
                if let rule = raw as? [String: Any] {
                    check("source.pathFields.\(field)", rule, allowed: pathFieldKeys)
                }
            }
        }

        if let kind = (object["source"] as? [String: Any])?["kind"] as? String,
           !kinds.contains(kind) {
            problems.append("source.kind \"\(kind)\" is not one of "
                + kinds.sorted().joined(separator: ", "))
        }
        return problems
    }

    static func run(_ path: String) -> Int32 {
        var problems = 0, warnings = 0
        func fail(_ m: String) { print("  ✗ \(m)"); problems += 1 }
        func warn(_ m: String) { print("  ! \(m)"); warnings += 1 }
        func ok(_ m: String)   { print("  ✓ \(m)") }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        print("\nChecking \(url.lastPathComponent)\n")

        guard let data = try? Data(contentsOf: url) else {
            print("  ✗ can't read \(url.path)\n"); return 1
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("  ✗ the file is valid JSON but not an object\n"); return 1
            }
            object = parsed
        } catch {
            // JSONSerialization reports the byte offset; turn it into a line.
            let text = String(decoding: data, as: UTF8.self)
            let ns = (error as NSError).userInfo["NSDebugDescription"] as? String ?? error.localizedDescription
            if let index = ns.range(of: "character ")?.upperBound,
               let offset = Int(ns[index...].prefix(while: \.isNumber)) {
                let line = text.prefix(offset).filter { $0 == "\n" }.count + 1
                print("  ✗ invalid JSON at line \(line): \(ns)\n")
            } else {
                print("  ✗ invalid JSON: \(ns)\n")
            }
            return 1
        }

        // 1. Keys the loader would otherwise silently ignore.
        for problem in schemaProblems(in: object) { fail(problem) }

        // 2. Does it decode at all?
        let document: HarnessDocument.Decoded
        do {
            document = try HarnessDocument.decode(data)
        } catch {
            fail(error.localizedDescription)
            print(""); return 1
        }
        let descriptor = document.descriptor
        ok("loads as harness \"\(descriptor.id)\" (\(descriptor.name))")
        if let old = document.migratedFrom {
            warn("format v\(old) is supported through an in-memory migration; rewrite it as v\(HarnessDocument.currentVersion) with the SDK")
        }

        // 3. Which live processes it claims.
        let processes: [Int32:Processes.Info]
        do { processes = try AgentScan.liveProcesses() }
        catch {
            fail("Local process discovery failed; running matches are unknown.")
            return 1
        }
        // Sorted so two runs of --check on the same machine print the same
        // report; a diagnostic that reorders itself is hard to diff.
        let claimed = processes.values
            .filter { descriptor.claims($0) }
            .sorted { $0.pid < $1.pid }
        if descriptor.match.isEmpty && descriptor.processNames.isEmpty {
            if descriptor.source.kind != .none {
                warn("no process patterns — this file will never claim a process")
            }
        } else if claimed.isEmpty {
            warn("no running process matches \(descriptor.match + descriptor.processNames) "
               + "— fine if the agent isn't running now")
        } else {
            ok("matches \(claimed.count) running process(es): "
               + claimed.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))
        }

        // A declared mark with no artwork silently falls back to a letter.
        // That is the right behaviour, but a descriptor that declares one is
        // stating something untrue, and the author cannot see it happen.
        if let mark = descriptor.resolvedMark, !mark.isEmpty,
           AppResources.bundle.url(forResource: mark, withExtension: "png",
                                   subdirectory: "marks") == nil {
            warn("presentation.mark \"\(mark)\" has no artwork in Resources/marks; "
                 + "the row will show a letter instead")
        }

        // 3b. The quota block, which for a quota-only harness is the whole
        //     point of the file and used to be reported on not at all: an
        //     endpoint of "not a url" passed with no problems and failed at
        //     the first fetch instead, which is the wrong moment to find out.
        if let quota = descriptor.quota {
            if let endpoint = URL(string: quota.endpoint), endpoint.scheme == "https",
               let host = endpoint.host, !host.isEmpty {
                ok("quota endpoint \(host)")
            } else {
                fail("quota.endpoint is not an https URL: \(quota.endpoint)")
            }
            if let credential = quota.credential {
                let missing: String?
                switch credential.kind {
                case "env":      missing = credential.name == nil ? "name" : nil
                case "textFile": missing = credential.path == nil ? "path" : nil
                case "jsonFile":
                    missing = credential.path == nil ? "path" : (credential.field == nil ? "field" : nil)
                case "command":  missing = credential.command == nil ? "command" : nil
                default:
                    fail("quota.credential.kind \"\(credential.kind)\" is not one of "
                         + "command, env, jsonFile, textFile")
                    missing = nil
                }
                if let missing {
                    fail("quota.credential of kind \(credential.kind) needs \(missing)")
                }
            }
            let map = quota.windows
            let figure = [map.usedPercent, map.percentRemaining, map.balance].contains { $0 != nil }
                || (map.used != nil && map.limit != nil)
            if figure {
                let shape = map.list != nil ? "a list" : (map.single != nil ? "one flat window" : "an object")
                ok("quota windows read from \(shape)")
            } else {
                fail("quota.windows declares no figure: give usedPercent, percentRemaining, "
                     + "used and limit, or balance")
            }
            if map.list != nil && map.key == nil {
                warn("quota.windows.list without key — windows will be numbered 0, 1, 2")
            }
            if map.single != nil && map.list != nil {
                warn("quota.windows sets both single and list; list wins")
            }
            for (window, badge) in map.badges ?? [:] where badge.count > 4 || badge.isEmpty {
                fail("quota.windows.badges.\(window) is \(badge.count) characters; "
                     + "the menu bar fits four")
            }
            if let hint = quota.setupHint, hint.count > 48 {
                warn("quota.setupHint is \(hint.count) characters and will truncate in the "
                     + "first-run panel")
            }
        }

        // 4. The part that catches real mistakes: test every declared path
        //    against records the source actually produces.
        let (records, origin) = HarnessEngine.sampleRecords(descriptor)
        print("  · source: \(origin)")
        if descriptor.source.kind != .none && records.isEmpty {
            warn("no records to check field paths against")
        }
        // A named column the reader doesn't understand is silently discarded.
        if d_kindIsSQLite(descriptor) {
            for column in descriptor.source.columns ?? []
            where !sqliteColumns.contains(column) {
                if let guess = nearest(column, in: sqliteColumns) {
                    fail("columns names \"\(column)\", which is not a field — did you mean "
                       + "\"\(guess)\"?")
                } else {
                    fail("columns names \"\(column)\", which the reader ignores")
                }
            }
        }
        if !records.isEmpty {
            ok("read \(records.count) record(s) to test against")
            for (label, path) in declaredPaths(descriptor) {
                let hits = records.filter { HarnessEngine.value($0, path) != nil }.count
                if hits == 0 {
                    fail("map.\(label): \"\(path)\" matched nothing in \(records.count) records"
                       + (suggestPath(path, records: records).map { " — nearest is \"\($0)\"" } ?? ""))
                } else {
                    let sample = records.compactMap { HarnessEngine.value($0, path) }.first
                    // A number field that resolves to an object reads as zero
                    // and says nothing. This is how PI's cost was silently 0.
                    if numeric.contains(where: { label.hasPrefix($0) }), !isNumber(sample) {
                        if let dict = sample as? [String: Any] {
                            let child = ["total", "amount", "value", "usd"]
                                .first { isNumber(dict[$0]) } ?? dict.first { isNumber($0.value) }?.key
                            fail("map.\(label): \"\(path)\" is an object, not a number — it will "
                               + "count as 0"
                               + (child.map { ". Try \"\(path).\($0)\"" } ?? ""))
                        } else {
                            fail("map.\(label): \"\(path)\" is \(preview(sample)), not a number "
                               + "— it will count as 0")
                        }
                    } else {
                        ok("map.\(label): \(hits)/\(records.count) records, e.g. \(preview(sample))")
                    }
                }
            }
            if let marker = descriptor.fields.toolMarker {
                warn("map.toolMarker is a raw substring (\(marker)) — check it against the file "
                   + "itself; JSON spacing matters")
            }
        }

        // 5. What it would actually show.
        let sessions = HarnessEngine.sessions(descriptor)
        if let newest = sessions.first {
            print("\n  Would show: project=\(newest.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—") "
                + "model=\(newest.model ?? "—") context=\(newest.contextTokens)"
                + " tools=\(newest.toolCalls) turns=\(newest.turns) "
                + "cost=\(newest.costUSD > 0 ? Pricing.money(newest.costUSD) : "—")")
        } else if descriptor.source.kind != .none {
            print("\n  Would show: no sessions")
        }

        print("\n\(problems) problem(s), \(warnings) warning(s)\n")
        return problems == 0 ? 0 : 1
    }

    private static func d_kindIsSQLite(_ d: HarnessDescriptor) -> Bool {
        d.source.kind == .sqlite
    }

    private static let numeric: Set<String> = [
        "inputTokens", "outputTokens", "cacheRead", "cacheWrite", "cost",
        "contextWindow", "contextTokens", "pid",
    ]

    private static func isNumber(_ value: Any?) -> Bool {
        value is Int || value is Double || value is NSNumber
    }

    // MARK: - Helpers

    private static let sqliteColumns: Set<String> = [
        "sessionID", "cwd", "title", "model", "inputTokens", "outputTokens", "cacheRead",
        "cacheWrite", "toolCalls", "cost", "startedAt", "lastActivity",
        "contextWindow", "contextTokens", "turns", "subAgents",
    ]

    private static func declaredPaths(_ d: HarnessDescriptor) -> [(String, String)] {
        // A sqlite harness maps by column name, not by a path into a record.
        if d.source.kind == .sqlite {
            return (d.source.columns ?? []).map { ("columns.\($0)", $0) }
        }
        let m = d.fields
        var out: [(String, String)] = []
        for (label, path) in [("cwd", m.cwd), ("title", m.title), ("model", m.model),
                              ("timestamp", m.timestamp), ("inputTokens", m.inputTokens),
                              ("outputTokens", m.outputTokens), ("cacheRead", m.cacheRead),
                              ("cacheWrite", m.cacheWrite), ("cost", m.cost),
                              ("contextWindow", m.contextWindow), ("pid", m.pid)] {
            if let path { out.append((label, path)) }
        }
        for (i, path) in (m.contextTokens ?? []).enumerated() {
            out.append(("contextTokens[\(i)]", path))
        }
        for (path, _) in m.turnWhere ?? [:] { out.append(("turnWhere.\(path)", path)) }
        for (path, _) in m.toolWhere ?? [:] { out.append(("toolWhere.\(path)", path)) }
        if let count = m.toolCalls { out.append(("toolCalls.path", count.path)) }
        if let count = m.turns { out.append(("turns.path", count.path)) }
        if let count = m.subAgents { out.append(("subAgents.path", count.path)) }
        if let field = m.status?.field, !field.isEmpty { out.append(("status.field", field)) }
        if let path = m.status?.whileNotEmpty { out.append(("status.whileNotEmpty", path)) }
        return out
    }

    /// Every path present in the sample data, so a wrong one can be pointed at
    /// the right one instead of just being called wrong.
    private static func suggestPath(_ wanted: String, records: [[String: Any]]) -> String? {
        var candidates: Set<String> = []
        for record in records.prefix(40) { collect(record, prefix: "", into: &candidates) }
        let leaf = wanted.split(separator: ".").last.map(String.init) ?? wanted
        return candidates
            .filter { $0.split(separator: ".").last.map(String.init) == leaf }
            .sorted().first ?? nearest(wanted, in: candidates)
    }

    private static func collect(_ record: [String: Any], prefix: String, into set: inout Set<String>) {
        guard set.count < 400 else { return }
        for (key, value) in record {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            set.insert(path)
            if let nested = value as? [String: Any] { collect(nested, prefix: path, into: &set) }
        }
    }

    /// Cheap edit distance, for "did you mean".
    private static func nearest<C: Collection>(_ word: String, in options: C) -> String?
    where C.Element == String {
        options.map { ($0, distance(word.lowercased(), $0.lowercased())) }
            .filter { $0.1 <= max(2, word.count / 3) }
            .min { $0.1 < $1.1 }?.0
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let insert = row[j] + 1, delete = row[j - 1] + 1
                let replace = previous + (a[i - 1] == b[j - 1] ? 0 : 1)
                previous = row[j]
                row[j] = min(insert, delete, replace)
            }
        }
        return row[b.count]
    }

    private static func preview(_ value: Any?) -> String {
        switch value {
        case let v as String: return "\"\(v.prefix(40))\""
        case let v as Int: return "\(v)"
        case let v as Double: return "\(v)"
        case let v as Bool: return "\(v)"
        case is [Any]: return "[…]"
        case is [String: Any]: return "{…}"
        default: return "—"
        }
    }
}
