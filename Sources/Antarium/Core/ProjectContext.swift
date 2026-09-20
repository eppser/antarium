import Foundation
import Darwin

/// The five kinds of context a harness may declare. A capability is present
/// only when its configured probe can reveal concrete content.
struct Capability: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case instruction, memory, skills, mcp, permission

        var label: String {
            switch self {
            case .instruction: return "Instructions"
            case .memory:      return "Memory"
            case .skills:      return "Skills"
            case .mcp:         return "MCP"
            case .permission:  return "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .instruction: return "doc.text"
            case .memory:      return "brain"
            case .skills:      return "wand.and.stars"
            case .mcp:         return "point.3.connected.trianglepath.dotted"
            case .permission:  return "lock.shield"
            }
        }
    }

    enum Scope { case project, inherited, absent, unavailable }

    let kind: Kind
    let url: URL?
    var scope: Scope = .absent
    var count: Int = 0
    var issue: String?

    var id: String { kind.rawValue }
    var isPresent: Bool { url != nil }
}

/// Resolves descriptor-owned capability paths for one project. The code knows
/// how to probe safely; it does not know Claude, Codex, Cursor, or their folder
/// conventions.
struct ProjectContext {
    private enum ProbeError: Error { case unavailable, unsupported, malformed, budget }
    var capabilities: [Capability] = Capability.Kind.allCases.map {
        Capability(kind: $0, url: nil)
    }

    var present: [Capability] { capabilities.filter(\.isPresent) }

    nonisolated(unsafe) private static let fm = FileManager.default
    nonisolated(unsafe) private static var cache:
        [String: (fingerprint: String, context: ProjectContext)] = [:]
    private static let lock = NSLock()
    static var cachedContextCount: Int {
        lock.lock(); defer { lock.unlock() }; return cache.count
    }

    static func scan(_ cwd: String, agentID: String,
                     descriptor supplied: HarnessDescriptor? = nil) -> ProjectContext {
        let descriptor = supplied ?? HarnessDescriptor.all().first { $0.id == agentID }
        let rules = descriptor?.capabilityRules ?? [:]
        guard rules.values.reduce(0, { $0 + $1.projectPaths.count + $1.inheritedPaths.count }) <= 128 else {
            return ProjectContext(capabilities:Capability.Kind.allCases.map {
                Capability(kind:$0,url:nil,scope:.unavailable,issue:"Capability configuration exceeds the probe limit.")
            })
        }
        let root = URL(fileURLWithPath: cwd)
        let home = fm.homeDirectoryForCurrentUser
        let slug = cwd.replacingOccurrences(of: "/", with: "-")

        func resolve(_ path: String, scope: Capability.Scope) -> URL {
            let substituted = path
                .replacingOccurrences(of: "{cwd}", with: cwd)
                .replacingOccurrences(of: "{cwdSlug}", with: slug)
            if substituted.hasPrefix("~") {
                return URL(fileURLWithPath: substituted.expandingTilde).standardizedFileURL
            }
            if substituted.hasPrefix("/") {
                return URL(fileURLWithPath: substituted).standardizedFileURL
            }
            let base = scope == .project ? root : home
            return base.appendingPathComponent(substituted).standardizedFileURL
        }

        var evidence = [ruleStamp(rules)]
        for kind in rules.keys.sorted() {
            guard let rule = rules[kind] else { continue }
            for path in rule.projectPaths {
                let url = resolve(path, scope: .project)
                evidence.append("\(url.path)=\(FileStamp.of(url))")
                if let index = rule.index {
                    let file = url.appendingPathComponent(index)
                    evidence.append("\(file.path)=\(FileStamp.of(file))")
                }
            }
            for path in rule.inheritedPaths {
                let url = resolve(path, scope: .inherited)
                evidence.append("\(url.path)=\(FileStamp.of(url))")
                if let index = rule.index {
                    let file = url.appendingPathComponent(index)
                    evidence.append("\(file.path)=\(FileStamp.of(file))")
                }
            }
        }
        let key = "\(agentID)|\(cwd)"
        let fingerprint = evidence.joined(separator: "\n")
        lock.lock()
        if let hit = cache[key], hit.fingerprint == fingerprint {
            lock.unlock()
            return hit.context
        }
        lock.unlock()

        var remainingBytes = 4 * 1_024 * 1_024, remainingEntries = 8_192
        func metadata(_ url:URL) throws -> stat? {
            var info = stat()
            guard lstat(url.path,&info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw ProbeError.unavailable
            }
            guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else {
                throw ProbeError.unsupported
            }
            return info
        }
        func entries(_ url:URL) throws -> [BoundedDirectory.Entry] {
            guard remainingEntries > 0 else { throw ProbeError.budget }
            let entries = try BoundedDirectory.entries(url,limit:min(4_096,remainingEntries))
            remainingEntries -= entries.count
            return entries
        }
        func data(_ url:URL) throws -> Data {
            guard remainingBytes > 0 else { throw ProbeError.budget }
            let bytes = try BoundedFile.read(url,maxBytes:min(1_048_576,remainingBytes))
            remainingBytes -= bytes.count
            return bytes
        }
        func hasContent(_ url: URL) throws -> Bool {
            guard let info = try metadata(url) else { return false }
            if info.st_mode & S_IFMT == S_IFDIR { return try !entries(url).isEmpty }
            return info.st_size > 0
        }

        func jsonObject(_ url: URL, keys: [String]) throws -> Bool {
            let bytes = try data(url)
            let object = try JSONSerialization.jsonObject(with:bytes)
            guard object is [String:Any] || (keys.contains("") && object is [Any]) else { throw ProbeError.malformed }
            for key in keys {
                let value: Any?
                if key.isEmpty {
                    value = object
                } else if let dictionary = object as? [String: Any] {
                    value = FieldPath.lookup(dictionary, key)
                } else {
                    value = nil
                }
                if let dictionary = value as? [String: Any], !dictionary.isEmpty {
                    return true
                }
                if let array = value as? [Any], !array.isEmpty {
                    return true
                }
                if let value, !(value is NSNull), !(value is [String:Any]), !(value is [Any]) {
                    throw ProbeError.malformed
                }
            }
            return false
        }

        func declaresTOML(_ url: URL, keys: [String]) throws -> Bool {
            guard let text = String(data:try data(url),encoding:.utf8) else { throw ProbeError.malformed }
            // This is a declaration probe, not a complete TOML decoder. Do not
            // mistake example tables inside multiline strings for configuration.
            guard !text.contains("\"\"\""), !text.contains("'''") else { throw ProbeError.unsupported }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                for key in keys {
                    if line == "[\(key)]" || line.hasPrefix("[\(key).") {
                        return true
                    }
                    if line.hasPrefix(key) {
                        let tail = line.dropFirst(key.count)
                            .trimmingCharacters(in: .whitespaces)
                        if tail.hasPrefix("=") { return true }
                    }
                }
            }
            return false
        }

        func probe(_ url: URL, rule: HarnessDescriptor.CapabilityRule)
            throws -> (url: URL, count: Int)? {
            guard try metadata(url) != nil else { return nil }
            switch rule.resolvedProbe {
            case .content:
                return try hasContent(url) ? (url, 0) : nil
            case .jsonObject:
                return try jsonObject(url, keys: rule.objectKeys) ? (url, 0) : nil
            case .toml:
                return try declaresTOML(url, keys: rule.objectKeys) ? (url, 0) : nil
            case .directory:
                let entries = try entries(url)
                guard !entries.isEmpty else { return nil }
                if let index = rule.index {
                    let indexURL = url.appendingPathComponent(index)
                    if try hasContent(indexURL) {
                        let count = entries.filter { $0.url.lastPathComponent != index }.count
                        return (indexURL, count)
                    }
                }
                return (url, entries.count)
            }
        }

        func capability(_ kind: Capability.Kind) -> Capability {
            guard let rule = rules[kind.rawValue] else {
                return Capability(kind: kind, url: nil)
            }
            do {
                for path in rule.projectPaths {
                    let url = resolve(path, scope: .project)
                    if let hit = try probe(url, rule: rule) {
                        return Capability(kind: kind, url: hit.url,
                                          scope: .project, count: hit.count)
                    }
                }
                for path in rule.inheritedPaths {
                    let url = resolve(path, scope: .inherited)
                    if let hit = try probe(url, rule: rule) {
                        return Capability(kind: kind, url: hit.url,
                                          scope: .inherited, count: hit.count)
                    }
                }
                return Capability(kind: kind, url: nil)
            } catch {
                return Capability(kind:kind,url:nil,scope:.unavailable,
                    issue:"This capability could not be inspected: the source is unreadable, unsupported or exceeds a safety limit.")
            }
        }

        let context = ProjectContext(capabilities: Capability.Kind.allCases.map(capability))
        lock.lock()
        if cache[key] == nil, cache.count >= 256, let victim = cache.keys.first { cache.removeValue(forKey:victim) }
        cache[key] = (fingerprint, context)
        lock.unlock()
        return context
    }

    private static func ruleStamp(_ rules: [String: HarnessDescriptor.CapabilityRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(rules)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
