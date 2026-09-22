import Foundation

/// Validate before constructing the app, loading settings, or starting a scan.
/// Invalid diagnostics must never silently become a normal application launch.
enum LaunchArguments {
    private struct Mode {
        var minimum = 0
        var maximum = 0
        var options:Set<String> = []
        var valued:Set<String> = []
    }
    static func requestsHelp(_ arguments:[String]) -> Bool { arguments.first == "--help" || arguments.first == "-h" }
    static let help = """
    Antarium: run without arguments to start the menu-bar application.
    Diagnostics:
      --help | -h                     This list
      --agents [--cloud]              Observe agents
      --status | --bench | --tmux     Inspect status, scan timing, or tmux
      --remote-tmux [host ...]        Inspect configured or named hosts
      --once [provider]              Fetch provider usage
      --log [0...1000]                Read a bounded diagnostic tail
      --check <harness.json>          Check a harness against installed data
      --migrate-harness <in> <out>    Migrate a harness document
      --evaluate-harness <file>       Evaluate a harness
      --verify-harness-fixtures      Verify bundled synthetic fixtures
      --verify-harness-installations Verify installation probes
      --verify-harness-quota         Verify quota mappings against recorded shapes
      --detect-agents [--apply]      Report what a first run would switch on
      --print-remote-discovery-command
                                      Print the command a remote host is asked to run
      --verify-remote-discovery-reply <file>
                                      Replay a recorded remote reply through the parser
    Terminal wrapper:
      run -- <command> [arguments...]
    """
    static func validate(_ arguments:[String]) -> String? {
        guard arguments.count <= 1_024, arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) else {
            return "Command-line arguments exceed supported limits."
        }
        if arguments.isEmpty { return nil }
        // These are startup options supplied by macOS, not diagnostic modes.
        if arguments.allSatisfy({ argument in
            let parts = argument.split(separator:"_",omittingEmptySubsequences:false)
            return parts.count == 3 && parts[0] == "-psn" && parts.dropFirst().allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
            }
        }) { return nil }
        if arguments.count == 2,
           ["-NSDocumentRevisionsDebugMode","-ApplePersistenceIgnoreState"].contains(arguments[0]),
           ["YES","NO","true","false"].contains(arguments[1]) { return nil }
        guard let first = arguments.first else { return nil }
        if first == "run" { return arguments.count > 1 ? nil : "The run wrapper requires a command." }
        let single:Set<String> = ["--help","-h","--status","--bench","--tmux",
            "--print-remote-discovery-command","--verify-harness-fixtures","--verify-harness-installations","--verify-harness-quota"]
        let file:Set<String> = ["--verify-remote-discovery-reply","--preview",
            "--dashboard","--alert","--check","--evaluate-harness","--settings","--focus","--onboarding"]
        var modes = Dictionary(uniqueKeysWithValues:single.map { ($0,Mode()) })
        for name in file { modes[name] = Mode(minimum:1,maximum:1) }
        modes["--migrate-harness"] = Mode(minimum:2,maximum:2)
        modes["--remote-tmux"] = Mode(maximum:256)
        modes["--once"] = Mode(maximum:1)
        modes["--log"] = Mode(maximum:1)
        modes["--agents"] = Mode(options:["--cloud"])
        modes["--detect-agents"] = Mode(options:["--apply"])
        guard let mode = modes[first] else { return "Unknown command. Use --help for supported modes." }
        let rest = Array(arguments.dropFirst())
        var index = 0, positionals:[String] = [], seen:Set<String> = []
        while index < rest.count && !rest[index].hasPrefix("--") {
            guard positionals.count < mode.maximum, !rest[index].isEmpty else { return "Unexpected or empty command argument." }
            positionals.append(rest[index]); index += 1
        }
        guard positionals.count >= mode.minimum else { return "A required command argument is missing." }
        while index < rest.count {
            let option = rest[index]
            guard mode.options.contains(option), seen.insert(option).inserted else { return "An option is unknown, duplicated or belongs to another command." }
            index += 1
            if mode.valued.contains(option) {
                guard index < rest.count, !rest[index].isEmpty, !rest[index].hasPrefix("--") else { return "An option value is missing." }
                index += 1
            }
        }
        // The groups belong to modes that still exist; the activity ones went
        // with the commands that never did.
        for group:Set<String> in [["--explorer","--analysis","--insights"]] {
            if seen.intersection(group).count > 1 { return "Mutually exclusive options were supplied together." }
        }
        if first == "--log", let value = positionals.first {
            guard let count = Int(value), (0...1_000).contains(count) else { return "Log line count must be 0 through 1000." }
        }
        return nil
    }
}
