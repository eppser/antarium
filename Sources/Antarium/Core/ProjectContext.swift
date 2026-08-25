import Foundation

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

    enum Scope { case project, inherited, absent }

    let kind: Kind
    let url: URL?
    var scope: Scope = .absent
    var count: Int = 0

    var id: String { kind.rawValue }
    var isPresent: Bool { url != nil }
}

/// Resolves descriptor-owned capability paths for one project. The code knows
/// how to probe safely; it does not know Claude, Codex, Cursor, or their folder
/// conventions.
struct ProjectContext {
    var capabilities: [Capability] = Capability.Kind.allCases.map {
        Capability(kind: $0, url: nil)
    }

    var present: [Capability] { capabilities.filter(\.isPresent) }

    nonisolated(unsafe) private static let fm = FileManager.default
    nonisolated(unsafe) private static var cache:
        [String: (fingerprint: String, context: ProjectContext)] = [:]
    private static let lock = NSLock()

    static func scan(_ cwd: String, agentID: String,
                     descriptor supplied: HarnessDescriptor? = nil) -> ProjectContext {
        let descriptor = supplied ?? HarnessDescriptor.all().first { $0.id == agentID }
        let rules = descriptor?.capabilityRules ?? [:]
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

        func hasContent(_ url: URL) -> Bool {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return false }
            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                return !((try? fm.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: nil))?.isEmpty ?? true)
            }
            return (attrs[.size] as? Int ?? 0) > 0
        }

        func jsonObject(_ url: URL, keys: [String]) -> Bool {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { return false }
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
            }
            return false
        }

        func declaresTOML(_ url: URL, keys: [String]) -> Bool {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
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
            -> (url: URL, count: Int)? {
            switch rule.resolvedProbe {
            case .content:
                return hasContent(url) ? (url, 0) : nil
            case .jsonObject:
                return jsonObject(url, keys: rule.objectKeys) ? (url, 0) : nil
            case .toml:
                return declaresTOML(url, keys: rule.objectKeys) ? (url, 0) : nil
            case .directory:
                let entries = (try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? []
                guard !entries.isEmpty else { return nil }
                if let index = rule.index {
                    let indexURL = url.appendingPathComponent(index)
                    if hasContent(indexURL) {
                        let count = entries.filter { $0.lastPathComponent != index }.count
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
            for path in rule.projectPaths {
                let url = resolve(path, scope: .project)
                if let hit = probe(url, rule: rule) {
                    return Capability(kind: kind, url: hit.url,
                                      scope: .project, count: hit.count)
                }
            }
            for path in rule.inheritedPaths {
                let url = resolve(path, scope: .inherited)
                if let hit = probe(url, rule: rule) {
                    return Capability(kind: kind, url: hit.url,
                                      scope: .inherited, count: hit.count)
                }
            }
            return Capability(kind: kind, url: nil)
        }

        let context = ProjectContext(capabilities: Capability.Kind.allCases.map(capability))
        lock.lock()
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
