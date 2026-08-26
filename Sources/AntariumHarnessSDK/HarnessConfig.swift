import Foundation

/// Public, type-safe authoring model for Antarium harness JSON files.
///
/// The runtime remains deliberately narrower than a programming language:
/// configuration names observable sources, mappings, selection evidence,
/// capabilities and quota fields; operating-system collection and parsing
/// strategies stay in Antarium.
public struct HarnessConfig: Codable {
    public static let currentFormatVersion = 1

    public var schema = "../harness.schema.json"
    public var formatVersion = HarnessConfig.currentFormatVersion
    public var id: String
    public var name: String
    /// Legacy v0 process fields. New documents should use `process`.
    public var match: [String]?
    public var processNames: [String]?
    public var process: ProcessRule?
    public var source: Source
    public var map: Mapping?
    public var detached: Bool?
    public var multiSession: Bool?
    public var selection: Selection?
    public var quota: Quota?
    public var capabilities: [String: CapabilityRule]?
    public var idleAfter: Double?
    public var staleAfter: Double?
    public var fallbackName: String?
    public var mark: String?
    public var note: String?
    public var enabled: Bool?
    public var presentation: Presentation?
    public var compatibility: Compatibility?

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, match, process, source, map, detached, multiSession, selection
        case quota, capabilities, idleAfter, staleAfter, fallbackName, mark, note, enabled
        case presentation, compatibility
        case processNames = "matchProcessName"
        case schema = "$schema"
    }

    public init(id: String, name: String, match: [String], source: Source,
                map: Mapping? = nil) {
        self.id = id
        self.name = name
        self.match = nil
        self.process = ProcessRule(pathContains: match)
        self.source = source
        self.map = map
    }

    /// Preferred v1 initializer. All evidence used to claim a process is data.
    public init(id: String, name: String, process: ProcessRule, source: Source,
                map: Mapping? = nil) {
        self.id = id
        self.name = name
        self.match = nil
        self.processNames = nil
        self.process = process
        self.source = source
        self.map = map
    }

    public func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyID
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyName
        }
        switch source.kind {
        case .sqlite:
            guard source.query?.isEmpty == false,
                  source.columns?.isEmpty == false else {
                throw ValidationError.incompleteSQLiteSource
            }
        case .command:
            guard source.command?.isEmpty == false else {
                throw ValidationError.missingCommand
            }
        case .json, .jsonl, .none:
            break
        }
        if multiSession == true {
            let hasIdentity = map?.sessionID?.isEmpty == false
                || source.columns?.contains("sessionID") == true
                || source.pathFields?["sessionID"] != nil
            if !hasIdentity { throw ValidationError.multiSessionNeedsID }
        }
        if process?.sessionBinding == .openSourceFile,
           source.kind != .json && source.kind != .jsonl {
            throw ValidationError.openSourceFileBindingNeedsFileSource
        }
        for (index, probe) in (process?.installationProbes ?? []).enumerated() {
            guard !probe.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let evidence = URL(string: probe.evidence),
                  evidence.scheme == "https", evidence.host != nil,
                  Self.validDay(probe.verifiedAt) else {
                throw ValidationError.invalidInstallationProbe(index)
            }
        }
        if let selection {
            switch selection.kind {
            case .jsonFiles:
                guard selection.path?.isEmpty == false,
                      selection.glob?.isEmpty == false,
                      selection.records?.isEmpty == false,
                      selection.id?.isEmpty == false else {
                    throw ValidationError.incompleteSelection(.jsonFiles)
                }
            case .sqlite:
                guard selection.path?.isEmpty == false,
                      selection.query?.isEmpty == false,
                      selection.column?.isEmpty == false else {
                    throw ValidationError.incompleteSelection(.sqlite)
                }
            case .command:
                guard selection.command?.isEmpty == false,
                      selection.id?.isEmpty == false else {
                    throw ValidationError.incompleteSelection(.command)
                }
            }
        }
    }

    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public enum ValidationError: Error, LocalizedError {
        case emptyID
        case emptyName
        case incompleteSQLiteSource
        case missingCommand
        case multiSessionNeedsID
        case incompleteSelection(Selection.Kind)
        case openSourceFileBindingNeedsFileSource
        case invalidInstallationProbe(Int)

        public var errorDescription: String? {
            switch self {
            case .emptyID: return "Harness id must not be empty."
            case .emptyName: return "Harness name must not be empty."
            case .incompleteSQLiteSource:
                return "A SQLite source requires both query and columns."
            case .missingCommand: return "A command source requires command."
            case .multiSessionNeedsID:
                return "A multi-session harness requires map.sessionID for stable identity."
            case .incompleteSelection(let kind):
                return "The \(kind.rawValue) selection is missing required fields."
            case .openSourceFileBindingNeedsFileSource:
                return "An open-source-file process binding requires a JSON or JSONL source."
            case .invalidInstallationProbe(let index):
                return "Installation probe \(index + 1) requires a method, HTTPS evidence, and yyyy-MM-dd verifiedAt date."
            }
        }
    }

    private static func validDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    public struct ProcessRule: Codable {
        public enum SessionBinding: String, Codable {
            case openSourceFile
        }

        /// A portable process-table fixture proving one documented install
        /// layout against Antarium's production matcher.
        public struct InstallationProbe: Codable {
            public var method: String
            public var path: String
            public var name: String
            public var argv0: String
            public var expected: Bool
            public var evidence: String
            public var verifiedAt: String

            public init(method: String, path: String, name: String, argv0: String,
                        expected: Bool, evidence: String, verifiedAt: String) {
                self.method = method
                self.path = path
                self.name = name
                self.argv0 = argv0
                self.expected = expected
                self.evidence = evidence
                self.verifiedAt = verifiedAt
            }
        }

        public var pathContains: [String]?
        public var names: [String]?
        public var argv0Contains: [String]?
        public var sessionBinding: SessionBinding?
        public var installationProbes: [InstallationProbe]?

        public init(pathContains: [String] = [], names: [String] = [],
                    argv0Contains: [String] = [],
                    sessionBinding: SessionBinding? = nil,
                    installationProbes: [InstallationProbe] = []) {
            self.pathContains = pathContains.isEmpty ? nil : pathContains
            self.names = names.isEmpty ? nil : names
            self.argv0Contains = argv0Contains.isEmpty ? nil : argv0Contains
            self.sessionBinding = sessionBinding
            self.installationProbes = installationProbes.isEmpty ? nil : installationProbes
        }
    }

    public struct Presentation: Codable {
        public var mark: String?
        public var fallbackName: String?
        public var sourceLabel: String?

        public init(mark: String? = nil, fallbackName: String? = nil,
                    sourceLabel: String? = nil) {
            self.mark = mark
            self.fallbackName = fallbackName
            self.sourceLabel = sourceLabel
        }
    }

    /// A claim with its evidence. Antarium only displays `fixtureVerified`
    /// after the referenced fixture passes; this field alone is not trusted.
    public struct Compatibility: Codable {
        public enum Level: String, Codable {
            case experimental, declared, fixtureVerified, liveVerified
        }

        public var level: Level
        public var verifiedAt: String?
        public var agentVersions: [String]?
        public var fixture: String?
        public var note: String?

        public init(level: Level = .experimental, verifiedAt: String? = nil,
                    agentVersions: [String]? = nil, fixture: String? = nil,
                    note: String? = nil) {
            self.level = level
            self.verifiedAt = verifiedAt
            self.agentVersions = agentVersions
            self.fixture = fixture
            self.note = note
        }
    }

    public struct Source: Codable {
        public enum Kind: String, Codable {
            case jsonl, json, sqlite, command, none
        }

        public var kind: Kind
        public var path: String
        public var journal: Bool?
        public var glob: String?
        public var limit: Int?
        public var pathFields: [String: PathField]?
        public var paths: [String: String]?
        public var query: String?
        public var columns: [String]?
        public var filter: [String: [String]]?
        public var manifest: Manifest?
        public var command: String?
        public var args: [String]?
        public var root: String?
        public var refreshEvery: Double?

        public init(kind: Kind, path: String, glob: String? = nil) {
            self.kind = kind
            self.path = path
            self.glob = glob
        }

        public struct PathField: Codable {
            public enum Value: String, Codable { case name, stem, path }

            public var ancestor: Int
            public var value: Value

            public init(ancestor: Int, value: Value) {
                self.ancestor = ancestor
                self.value = value
            }
        }

        public struct Manifest: Codable {
            public var file: String
            public var map: Mapping

            public init(file: String, map: Mapping) {
                self.file = file
                self.map = map
            }
        }
    }

    public struct Mapping: Codable {
        public var cwd: String?
        public var contextWindow: String?
        public var contextTokens: [String]?
        public var model: String?
        public var timestamp: String?
        public var inputTokens: String?
        public var outputTokens: String?
        public var cacheRead: String?
        public var inputIncludesCacheRead: Bool?
        public var cacheWrite: String?
        public var cost: String?
        public var title: String?
        public var toolMarker: String?
        public var toolWhere: [String: String]?
        public var toolCalls: Count?
        public var turnWhere: [String: String]?
        public var status: Status?
        public var sessionID: String?
        public var pid: String?
        public var turns: Count?
        public var subAgents: Count?

        public init(cwd: String? = nil, model: String? = nil,
                    sessionID: String? = nil) {
            self.cwd = cwd
            self.model = model
            self.sessionID = sessionID
        }

        public struct Count: Codable {
            public var path: String
            public var match: [String: String]?

            public init(path: String, match: [String: String]? = nil) {
                self.path = path
                self.match = match
            }
        }

        public struct Status: Codable {
            public var whileNotEmpty: String?
            public var field: String?
            public var working: [String]?
            public var idle: [String]?

            public init(whileNotEmpty: String? = nil, field: String? = nil,
                        working: [String]? = nil, idle: [String]? = nil) {
                self.whileNotEmpty = whileNotEmpty
                self.field = field
                self.working = working
                self.idle = idle
            }
        }
    }

    public struct CapabilityRule: Codable {
        public enum Probe: String, Codable {
            case content, directory, jsonObject, toml
        }

        public var probe: Probe
        public var project: [String]?
        public var inherited: [String]?
        public var index: String?
        public var keys: [String]?

        public init(probe: Probe, project: [String]? = nil,
                    inherited: [String]? = nil, index: String? = nil,
                    keys: [String]? = nil) {
            self.probe = probe
            self.project = project
            self.inherited = inherited
            self.index = index
            self.keys = keys
        }
    }

    public struct Selection: Codable {
        public enum Kind: String, Codable, Sendable { case jsonFiles, sqlite, command }

        public var kind: Kind
        public var path: String?
        public var glob: String?
        public var records: String?
        public var encodedJSON: Bool?
        public var id: String?
        public var filter: [String: [String]]?
        public var query: String?
        public var column: String?
        public var command: String?
        public var args: [String]?
        public var root: String?

        public init(path: String, glob: String, records: String,
                    encodedJSON: Bool? = nil, id: String,
                    filter: [String: [String]]? = nil) {
            self.kind = .jsonFiles
            self.path = path
            self.glob = glob
            self.records = records
            self.encodedJSON = encodedJSON
            self.id = id
            self.filter = filter
        }

        public init(sqlitePath: String, query: String, column: String) {
            self.kind = .sqlite
            self.path = sqlitePath
            self.query = query
            self.column = column
        }

        public init(command: String, args: [String] = [], root: String? = nil,
                    id: String, filter: [String: [String]]? = nil) {
            self.kind = .command
            self.command = command
            self.args = args
            self.root = root
            self.id = id
            self.filter = filter
        }
    }

    public struct Quota: Codable {
        public var endpoint: String
        public var headers: [String: String]?
        public var credential: Credential?
        public var windows: Windows
        public var accountLabel: String?
        public var setupHint: String?
        public var signInCommand: String?
        public var verified: Bool?

        public init(endpoint: String, windows: Windows) {
            self.endpoint = endpoint
            self.windows = windows
        }

        public struct Credential: Codable {
            public var kind: String
            public var path: String?
            public var field: String?
            public var name: String?
            public var command: String?
            public var args: [String]?

            public init(kind: String) {
                self.kind = kind
            }
        }

        public struct Windows: Codable {
            public var root: String?
            public var keys: [String]?
            public var usedPercent: String?
            public var percentRemaining: String?
            public var used: String?
            public var limit: String?
            public var require: [String: Bool]?
            public var labels: [String: String]?
            public var windowSeconds: String?
            public var resetsAt: String?
            public var title: String?

            public init(root: String? = nil, keys: [String]? = nil) {
                self.root = root
                self.keys = keys
            }
        }
    }
}
