import AppKit

/// Brings the terminal running an agent to the front.
///
/// Cost is zero until you click: nothing here runs during a scan. Claude Code
/// records a tmux target (`session:@window.%pane`) in its session file when it
/// is running under tmux, which is the precise case — for those we select the
/// exact pane, then raise whichever app is attached to that tmux client. For
/// everything else we walk the process tree up to the owning application.
///
/// Where a window can be named — a terminal tab, a tmux pane — it is raised
/// directly, which makes macOS follow it to whichever Space it is on. For an
/// app we cannot script, activation is all there is, and whether the desktop
/// follows is then macOS's call (Desktop & Dock → Mission Control → "switch to
/// a Space with open windows for the application").
///
/// Raising an app needs no special permission, but it only lands you in
/// whichever tab was last used — which is rarely the agent's. The agent's tty
/// says exactly which tab is its, and both Terminal and iTerm expose the tty of
/// every tab to AppleScript, so we select that tab precisely. That does prompt
/// for Automation consent the first time; if it is declined we still raise the
/// app, which is what this used to do for everyone.
enum Focus {
    static func canRevealLocally(_ row: AgentRow) -> Bool {
        !row.isRemote && row.localObservationIssue == nil
    }

    /// Something a row's menu offers to do.
    enum Action: String, CaseIterable, Sendable {
        case attachTmux, goToWindow, openDirectory, openInTerminal, copyPath
    }

    /// What a row actually permits.
    ///
    /// This rule lived here and only here, and the row's own menu never asked.
    /// `canRevealLocally` keeps a remote row from driving this Mac through
    /// `reveal`, and three buttons drove it anyway: "Open Directory", "Open in
    /// Terminal" and "Copy Path" all took `row.cwd` straight to `NSWorkspace`
    /// and the pasteboard.
    ///
    /// A remote row's `cwd` is the *other* machine's. On two Macs with the same
    /// username and a checkout of the same name the path exists on both, so
    /// the user was shown this machine's files while believing they were
    /// looking at the session's — which is worse than an error, because
    /// nothing looks wrong.
    ///
    /// "Go to Window" was offered too, and `reveal` returns `.nothing` for a
    /// remote row, so the click was silently dead.
    static func actions(for row: AgentRow) -> Set<Action> {
        var allowed: Set<Action> = []
        // A local attach joins a session on *this* machine. A remote row's
        // session is not here, and a same-named one that is would be the
        // wrong session.
        if row.tmuxTarget != nil, !row.isRemote { allowed.insert(.attachTmux) }
        guard !row.cwd.isEmpty else { return allowed }
        if canRevealLocally(row) { allowed.insert(.goToWindow) }
        if !row.isRemote {
            allowed.insert(.openDirectory)
            allowed.insert(.openInTerminal)
        }
        // Copying is always offered, because a path is useful even when it is
        // not this machine's — but it has to say whose it is.
        allowed.insert(.copyPath)
        return allowed
    }

    /// Opens the row's directory here, if the row is this machine's.
    ///
    /// The permission check lives inside the action rather than beside the
    /// button, because a button is a thing somebody can add. Three were added
    /// without it and each drove this Mac from a row describing another one.
    /// Refusing here means a fourth cannot.
    ///
    /// The effect is a parameter so the refusal can be observed without a
    /// Finder window opening during a test run.
    @discardableResult
    static func openDirectory(_ row: AgentRow,
                              using open: (URL) -> Void = {
                                  NSWorkspace.shared.activateFileViewerSelecting([$0])
                              }) -> Bool {
        guard actions(for: row).contains(.openDirectory) else { return false }
        open(URL(fileURLWithPath: row.cwd))
        return true
    }

    /// Opens a terminal here at the row's directory, on the same terms.
    @discardableResult
    static func openInTerminal(_ row: AgentRow,
                               using open: (URL) -> Void = { url in
                                   let terminal = URL(fileURLWithPath:
                                       "/System/Applications/Utilities/Terminal.app")
                                   NSWorkspace.shared.open(
                                       [url], withApplicationAt: terminal,
                                       configuration: NSWorkspace.OpenConfiguration())
                               }) -> Bool {
        guard actions(for: row).contains(.openInTerminal) else { return false }
        open(URL(fileURLWithPath: row.cwd))
        return true
    }

    /// Puts the row's path on the pasteboard, naming its machine where that
    /// is not this one.
    @discardableResult
    static func copyPath(_ row: AgentRow,
                         using write: (String) -> Void = { text in
                             NSPasteboard.general.clearContents()
                             NSPasteboard.general.setString(text, forType: .string)
                         }) -> Bool {
        guard actions(for: row).contains(.copyPath), let path = pathToCopy(for: row)
        else { return false }
        write(path)
        return true
    }

    /// The text "Copy Path" should put on the pasteboard.
    ///
    /// A remote row's path carries its host, in the form every other tool
    /// takes: `host:/path`, which pastes into `scp` and reads correctly to a
    /// person. The bare path was indistinguishable from a local one.
    static func pathToCopy(for row: AgentRow) -> String? {
        guard !row.cwd.isEmpty else { return nil }
        guard row.isRemote, let host = row.remoteHost, !host.isEmpty else { return row.cwd }
        return "\(host):\(row.cwd)"
    }
    /// What a click actually did. Worth naming: "raised the app" and "landed on
    /// the agent's own tab" look identical from the outside but are not.
    enum Result: Equatable {
        case tmux(String)
        case tab(String)
        case app(String)
        /// A harness that owns its own windows raised one of them itself.
        case harness(String)
        case folder
        case nothing

        var succeeded: Bool { self != .nothing }
        var description: String {
            switch self {
            case .harness(let n): return "asked \(n) to show it"
            case .tmux(let t):  return "tmux pane \(t)"
            case .tab(let t):   return "terminal tab \(t)"
            case .app(let n):   return "raised \(n)"
            case .folder:       return "opened the folder"
            case .nothing:      return "nothing to raise"
            }
        }
    }

    /// One thing a click could try, in the order it should be tried.
    ///
    /// Naming the order makes it a rule with a test instead of the shape of an
    /// `if` chain inside three calls that need a window server, a tmux server
    /// and a workspace manager to exercise. Which matters most for the first
    /// entry: a harness that owns its own windows knows which pane of which
    /// tab this session is, and raising the application instead lands on
    /// whatever it had open last — the click appears to work and goes to the
    /// wrong place.
    enum Step: Equatable {
        case harness(id: String, target: String)
        case tmux(String)
        case app(pid: Int32)
        case folder(String)
    }

    /// What a click would try, in order. Pure: `descriptorHasFocus` answers
    /// whether that harness declares a focus command, so the plan can be
    /// checked without a catalog on disk.
    static func plan(_ row: AgentRow,
                     descriptorHasFocus: (String) -> Bool) -> [Step] {
        guard canRevealLocally(row) else { return [] }
        var steps: [Step] = []
        if descriptorHasFocus(row.agentID), let target = row.focusTarget, !target.isEmpty {
            steps.append(.harness(id: row.agentID, target: target))
        }
        if let target = row.tmuxTarget, !target.isEmpty { steps.append(.tmux(target)) }
        if let pid = row.pid { steps.append(.app(pid: pid)) }
        if !row.cwd.isEmpty { steps.append(.folder(row.cwd)) }
        return steps
    }

    @discardableResult
    @MainActor
    static func reveal(_ row: AgentRow) -> Result {
        let descriptors = HarnessDescriptor.all()
        let steps = plan(row) { id in
            descriptors.first { $0.id == id }?.focus != nil
        }
        guard !steps.isEmpty else { return .nothing }
        Log.info("focus", "reveal local session requested")
        for step in steps {
            switch step {
            case .harness(let id, let target):
                guard let descriptor = descriptors.first(where: { $0.id == id }),
                      let focus = descriptor.focus else { continue }
                if runHarnessFocus(focus, target: target) { return .harness(descriptor.name) }
            case .tmux(let target):
                if focusTmux(target) { return .tmux(target) }
            case .app(let pid):
                let result = activateOwningApp(of: pid)
                if result.succeeded { return result }
            case .folder(let cwd):
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                return .folder
            }
        }
        return .nothing
    }

    /// Runs a harness's own focus command, with `{focusTarget}` substituted.
    ///
    /// Executed directly, never through a shell: the target comes from a file
    /// the harness wrote, and the descriptor supplying the command is trusted
    /// local configuration, but neither is a reason to let a value become
    /// shell syntax. Bounded like every other subprocess, because a workspace
    /// manager that has wedged must not take the menu bar with it.
    /// The command line a click would run, or nil when the target is not
    /// usable. Separated from running it so the substitution can be checked
    /// without a workspace manager installed — and so a test cannot quietly
    /// re-implement the rule it is meant to be checking.
    static func focusArguments(_ focus: HarnessDescriptor.Focus,
                               target: String) -> [String]? {
        // An empty target would ask the manager to focus "", which is either a
        // different pane or an error, and either way not the row that was
        // clicked.
        guard !target.isEmpty, !target.contains("\0"), target.utf8.count <= 512 else {
            return nil
        }
        return (focus.args ?? []).map {
            $0.replacingOccurrences(of: "{focusTarget}", with: target)
        }
    }

    @MainActor
    private static func runHarnessFocus(_ focus: HarnessDescriptor.Focus,
                                        target: String) -> Bool {
        guard let arguments = focusArguments(focus, target: target),
              let path = resolve(focus.command) else { return false }
        let result = Shell.execute(path, arguments, timeout: 5, outputLimit: 8_192)
        if result.exitCode != 0 {
            Log.info("focus", "harness focus command did not succeed")
        }
        return result.exitCode == 0
    }

    private static func resolve(_ command: String) -> String? {
        CommandPath.resolve(command)
    }

    /// `unruly-6:@6.%12` → select that pane, then raise its terminal.
    @MainActor
    private static func focusTmux(_ target: String) -> Bool {
        guard let tmux = tmuxPath() else { return false }
        let session = tmuxSession(target)
        guard !session.isEmpty else { return false }

        let pane = target.split(separator: ".").last.map(String.init) ?? target
        _ = Shell.run(tmux, ["select-window", "-t", target])
        _ = Shell.run(tmux, ["select-pane", "-t", pane])
        _ = Shell.run(tmux, ["switch-client", "-t", session])

        // The agent's parent is the tmux *server*, not a terminal — the window
        // to raise belongs to the attached client. Raising it is best effort:
        // a session attached over SSH has no local window, and reporting that
        // as failure sent the caller off to open a Finder folder instead. The
        // pane was still selected, which is the part that mattered.
        if let out = Shell.run(tmux, ["list-clients", "-t", session, "-F", "#{client_pid}"]),
           let pid = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines)
                            .split(separator: "\n").first.map(String.init) ?? "") {
            if activateOwningApp(of: pid).succeeded { return true }
        }
        // Nothing local to raise — the session is detached, or attached from
        // somewhere else entirely, like SSH. Opening a client is the only way
        // to actually get you there.
        return attachTmux(target)
    }

    /// `unruly-6:@6.%12` → `unruly-6`.
    static func tmuxSession(_ target: String) -> String {
        String(target.split(separator: ":").first ?? Substring(target))
    }

    /// The pid running in each tmux pane, mapped to that pane's target.
    ///
    /// Only Claude records its own tmux target in its session file, so every
    /// other agent under tmux had none — its row said "tmux" but a double click
    /// had nothing to attach to and fell through to opening the folder. tmux
    /// knows, and an agent is a child or grandchild of the pane's process, so
    /// the caller walks up the tree to find it.
    ///
    /// Note the format: `window_id` already carries its `@` and `pane_id` its
    /// `%`, so writing them out again yields `@@1.%%1`, which tmux rejects.
    static func tmuxPanesByPID() -> [Int32: String] {
        guard let tmux = tmuxPath(),
              let out = Shell.run(tmux, ["list-panes", "-a", "-F",
                                         "#{pane_pid} #{session_name}:#{window_id}.#{pane_id}"],
                                  timeout: 5)
        else { return [:] }
        var panes: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            panes[pid] = String(parts[1])
        }
        return panes
    }

    /// Attach, whatever the session's current state: point tmux at the agent's
    /// own pane first, then open a terminal on it. `reveal` prefers to raise a
    /// client that already exists, which is right for a single click but leaves
    /// no way to ask for a window when none is open — this is that way.
    @discardableResult
    @MainActor
    static func attachToPane(_ target: String) -> Bool {
        Log.info("focus", "Local tmux attach requested.")
        if let tmux = tmuxPath() {
            let pane = target
            // Split at the last dot: a session name may contain one, and
            // taking the first would cut the target short.
            let window = target.lastIndex(of: ".")
                .map { String(target[target.startIndex..<$0]) } ?? target
            // Best effort: a stale target should not stop the attach.
            _ = Shell.run(tmux, ["select-window", "-t", window])
            _ = Shell.run(tmux, ["select-pane", "-t", pane])
        }
        return attachTmux(target)
    }

    /// Opens a terminal attached to the session. A second client is fine —
    /// tmux is built for that, and it is what "attach" means to anyone who
    /// uses it.
    @discardableResult
    @MainActor
    static func attachTmux(_ target: String) -> Bool {
        guard tmuxPath() != nil else { return false }
        let session = tmuxSession(target)
        guard !session.isEmpty else { return false }
        // Two layers, in this order: the name is first quoted for the shell
        // that `do script` starts, and only then escaped for AppleScript's
        // string literal. Escaping for AppleScript alone left the name inside
        // double quotes in the shell, where `$(...)` and backticks still
        // expand — and tmux does allow a session name like "$(touch /tmp/x)",
        // verified. Clicking Attach would then run it.
        return Shell.run("/usr/bin/osascript", ["-e", attachScript(session: session)]) != nil
    }

    /// Pure, so the quoting can be tested without opening a Terminal window.
    static func attachScript(session: String) -> String {
        let shellQuoted = "'" + session.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let safe = shellQuoted.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
          activate
          do script "tmux attach -t \(safe)"
        end tell
        """
    }

    private static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Walk pid → ppid until we reach a pid that owns a real application.
    @MainActor
    private static func activateOwningApp(of pid: Int32) -> Result {
        var current = pid
        let parents = Processes.parentMap()
        for _ in 0..<12 {
            // `.regular` only. "Not prohibited" also matches accessory helpers
            // — Claude Desktop runs its CLI inside a nested claude.app — and
            // raising one of those succeeds while no window ever comes forward.
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                // The tty belongs to the agent, not to the app we walked up to.
                if let tty = tty(of: pid), selectTab(tty, in: app) { return .tab(tty) }
                // We are the frontmost app at this point — the click just came
                // from our own panel — and macOS will quietly ignore an
                // activation request from one unless it hands activation over.
                // `NSApp` is nil outside the running app — the --focus
                // diagnostic has no NSApplication, and force-unwrapping it there
                // took the process down with the output still buffered.
                if #available(macOS 14.0, *), let this = NSApp { this.yieldActivation(to: app) }
                // A hidden app (⌘H) activates without showing anything, and an
                // app whose windows are on another Space only follows if macOS
                // is asked for all of them.
                app.unhide()
                app.activate(options: [.activateAllWindows])
                // `activate` is advisory and modern macOS often declines it —
                // Warp and Claude Desktop both ignored it while Zed happened to
                // obey. Asking the workspace to open the running app is the
                // request the system actually honours, and it also restores a
                // minimised window or switches Spaces to reach it.
                if let bundle = app.bundleURL {
                    let options = NSWorkspace.OpenConfiguration()
                    options.activates = true
                    NSWorkspace.shared.openApplication(at: bundle, configuration: options)
                }
                return .app(app.localizedName ?? "app")
            }
            guard let parent = parents[current], parent > 1 else { break }
            current = parent
        }
        return .nothing
    }

    /// `/dev/ttys007` — the terminal line the agent is attached to.
    private static func tty(of pid: Int32) -> String? {
        guard let out = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "??" else { return nil }
        return name.hasPrefix("/dev/") ? name : "/dev/" + name
    }

    /// Selects the exact tab running this agent. False if the terminal can't be
    /// scripted, consent was declined, or no tab claims that tty.
    private static func selectTab(_ tty: String, in app: NSRunningApplication) -> Bool {
        let script: String
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set frontmost of w to true
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "no"
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
              activate
              repeat with w in windows
                repeat with tb in tabs of w
                  repeat with s in sessions of tb
                    if tty of s is "\(tty)" then
                      select w
                      select tb
                      select s
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "no"
            """
        default:
            return false
        }
        let out = Shell.run("/usr/bin/osascript", ["-e", script]) ?? ""
        return out.contains("ok")
    }


}
