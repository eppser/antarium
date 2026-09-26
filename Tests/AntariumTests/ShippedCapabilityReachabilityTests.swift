import Foundation
import Testing
@testable import Antarium

/// Every path every shipped harness declares, proved to be one the probe can
/// actually find something at.
///
/// The per-harness tests next door assert what the descriptors say. They
/// cannot tell a path that works from one that can never match: a directory
/// probe pointed at a file throws and the whole capability comes back
/// unavailable, a suffix filter that excludes everything reports an empty
/// folder, a jsonObject key that is not the one the vendor writes finds
/// nothing. All three look exactly like "this project has no instructions",
/// which is the answer for most projects, so nothing notices.
///
/// This is also the answer to testing thirteen agents without installing any
/// of them. A synthetic project laid out the way the vendor documents is
/// enough; what is being checked is the harness file, not the agent.
@Suite("Every declared capability path can be found", .serialized)
struct ShippedCapabilityReachabilityTests {

    private var shipped: [HarnessDescriptor] {
        get throws {
            let urls = try #require(AppResources.bundle.urls(
                forResourcesWithExtension: "json", subdirectory: "harnesses"))
            return try urls.sorted { $0.path < $1.path }.map {
                try HarnessDocument.decode(Data(contentsOf: $0)).descriptor
            }
        }
    }

    /// Content the probe will accept, by probe kind. A `content` rule takes
    /// any non-empty file; the structured ones want the shape they declare.
    private func body(for rule: HarnessDescriptor.CapabilityRule) -> Data {
        switch rule.resolvedProbe {
        case .jsonObject:
            let key = rule.objectKeys.first ?? "servers"
            return Data(#"{"\#(key)":{"synthetic":{"command":"true"}}}"#.utf8)
        case .toml:
            let key = rule.objectKeys.first ?? "servers"
            return Data("\(key) = { synthetic = 1 }\n".utf8)
        case .content, .directory:
            return Data("synthetic\n".utf8)
        }
    }

    /// A name inside a probed folder that the rule's suffixes accept.
    private func entryName(for rule: HarnessDescriptor.CapabilityRule) -> String {
        guard let suffix = rule.countedSuffixes.first else { return "synthetic.md" }
        return suffix.hasPrefix(".") ? "synthetic\(suffix)" : "synthetic.\(suffix)"
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reachability-\(UUID().uuidString)")
    }

    /// Builds a project holding exactly one declared path and reports what
    /// the probe made of it. `asDirectory` decides which shape that path
    /// takes, because a declaration does not say: `.cursor/rules` is a folder
    /// and `.cursorrules` is a file, and neither has a path extension to tell
    /// them apart.
    private func probe(_ descriptor: HarnessDescriptor, _ kind: Capability.Kind,
                       path: String, asDirectory: Bool,
                       empty: Bool = false) throws -> Capability {
        let rule = try #require(descriptor.capabilityRules[kind.rawValue])
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(path)
        if asDirectory {
            try FileManager.default.createDirectory(at: target,
                                                    withIntermediateDirectories: true)
            if !empty {
                try body(for: rule).write(to: target.appendingPathComponent(entryName(for: rule)))
            }
        } else {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (empty ? Data() : body(for: rule)).write(to: target)
        }
        ProjectContext.invalidate()
        let found = ProjectContext.scan(root.path, agentID: descriptor.id,
                                        descriptor: descriptor)
        return try #require(found.capabilities.first { $0.kind == kind })
    }

    /// Each declared project path, laid out both ways. One of the two has to
    /// work — which one is the vendor's business, not this test's — and
    /// neither may report the capability as unavailable, which is what a
    /// probe pointed at the wrong shape does.
    @Test("Every project path a shipped harness declares reports the capability")
    func projectPathsAreReachable() throws {
        var checked = 0, elsewhere = 0
        for descriptor in try shipped {
            for (raw, rule) in descriptor.capabilityRules.sorted(by: { $0.key < $1.key }) {
                guard let kind = Capability.Kind(rawValue: raw) else { continue }
                for path in rule.projectPaths {
                    let where_ = "\(descriptor.id) \(raw) \(path)"
                    // A project path may still be resolved somewhere a
                    // synthetic root cannot reach: claude-code keeps a
                    // project's memory under the user's home, keyed by a slug
                    // of the working directory. Those are counted and their
                    // template checked, rather than skipped quietly.
                    if path.hasPrefix("~") || path.hasPrefix("/") || path.contains("{") {
                        #expect(!path.contains("{") || path.contains("{cwdSlug}")
                                || path.contains("{cwd}"),
                                Comment(rawValue: "\(where_) uses an unknown template"))
                        elsewhere += 1
                        continue
                    }
                    let asFile = try probe(descriptor, kind, path: path, asDirectory: false)
                    let asDir = try probe(descriptor, kind, path: path, asDirectory: true)
                    // A probe meeting the wrong shape reports unavailable,
                    // which is the honest answer and not a fault in the
                    // declaration — so only reachability is asserted.
                    #expect(asFile.scope == .project || asDir.scope == .project,
                            Comment(rawValue: "\(where_) can never match anything: "
                                    + "as a file \(asFile.scope), as a folder \(asDir.scope)"))
                    // Only this path exists, so whichever shape matched must
                    // have found it and not something else.
                    let found = asFile.scope == .project ? asFile : asDir
                    if found.scope == .project {
                        #expect(found.url?.path.hasSuffix(path) == true,
                                Comment(rawValue: "\(where_) matched \(found.url?.path ?? "nothing")"))
                    }
                    checked += 1
                }
            }
        }
        #expect(checked >= 30, "only \(checked) paths were checked")
        #expect(elsewhere <= 2,
                "\(elsewhere) project paths resolve outside the project")
    }

    /// The file is there and there is nothing in it.
    ///
    /// This is the half of the suite that is not circular. The fixture above
    /// is built from the rule — the key a jsonObject probe looks for, the
    /// suffix a folder counts — so it cannot tell a right declaration from a
    /// wrong one, only a declaration that can never match from one that can.
    /// Emptiness is independent of all of that: `touch AGENTS.md` and an
    /// empty `.cursor/rules` are what a project looks like just after someone
    /// ran the agent's init command, and reporting instructions there tells
    /// them they have written some.
    @Test("An empty file or folder at a declared path is not project context")
    func emptyFilesAreNotContent() throws {
        var checked = 0
        for descriptor in try shipped {
            for (raw, rule) in descriptor.capabilityRules.sorted(by: { $0.key < $1.key }) {
                guard let kind = Capability.Kind(rawValue: raw) else { continue }
                for path in rule.projectPaths
                where !path.hasPrefix("~") && !path.hasPrefix("/") && !path.contains("{") {
                    let where_ = "\(descriptor.id) \(raw) \(path)"
                    for asDirectory in [false, true] {
                        let found = try probe(descriptor, kind, path: path,
                                              asDirectory: asDirectory, empty: true)
                        #expect(found.scope != .project,
                                Comment(rawValue: "\(where_) counts an empty "
                                        + (asDirectory ? "folder" : "file")))
                    }
                    checked += 1
                }
            }
        }
        #expect(checked >= 30, "only \(checked) paths were checked")
    }

    /// An empty project is the common case, and no rule may claim project
    /// context in one — a rule that reports a capability for a folder with
    /// none of its files in it would light up every row on the machine.
    ///
    /// Inherited scope is deliberately not asserted. Those paths resolve
    /// against the real home, so on a machine that has `~/.claude/skills` the
    /// honest answer is that the user does have global skills. Asserting
    /// absence there would pass or fail depending on whose machine ran it.
    @Test("A project with none of the declared files claims no project context")
    func emptyProjectReportsNothing() throws {
        let root = root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for descriptor in try shipped where !descriptor.capabilityRules.isEmpty {
            ProjectContext.invalidate()
            let found = ProjectContext.scan(root.path, agentID: descriptor.id,
                                            descriptor: descriptor)
            for capability in found.capabilities {
                #expect(capability.scope != .project,
                        Comment(rawValue: "\(descriptor.id) \(capability.kind.rawValue) "
                                + "claimed project context in an empty project"))
            }
        }
    }

    /// An inherited path is resolved against the user's home rather than the
    /// project, so one written without the tilde would be read out of
    /// whatever directory the agent happens to be working in — a project file
    /// reported as the user's global configuration.
    @Test("Every inherited path is a home path")
    func inheritedPathsAreAbsolute() throws {
        var checked = 0
        for descriptor in try shipped {
            for (raw, rule) in descriptor.capabilityRules {
                for path in rule.inheritedPaths {
                    #expect(path.hasPrefix("~/"),
                            Comment(rawValue: "\(descriptor.id) \(raw) inherits \(path)"))
                    checked += 1
                }
            }
        }
        #expect(checked >= 10, "only \(checked) inherited paths were checked")
    }
}
