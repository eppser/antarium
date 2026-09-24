import AppKit
import SQLite3
import SwiftUI

/// `Antarium --once [agent-id]` — fetch once, print what we read, exit.
/// With no id it checks every registered agent, which is the fastest way to
/// see what is configured on a machine.
enum Diagnostics {
    /// Formats diagnostic tables without C varargs or a large generic
    /// expression. Keeping each step explicit also avoids compiler-dependent
    /// type-checker timeouts on clean CI machines.
    static func tableRow(_ cells: [String],
                         widths: [Int] = [18, 9, 9, 12, 8, 7, 7, 8]) -> String {
        var columns: [String] = []
        let fixedCount = min(cells.count, widths.count)
        columns.reserveCapacity(cells.count)

        for index in 0..<fixedCount {
            let text = cells[index]
            let width = widths[index]
            if text.count < width {
                columns.append(text + String(repeating: " ", count: width - text.count))
            } else {
                columns.append(text)
            }
        }
        if cells.count > widths.count {
            columns.append(contentsOf: cells[widths.count...])
        }
        return columns.joined(separator: " ")
    }

    @MainActor
    static func runAndExit() -> Never {
        let args = CommandLine.arguments
        let requested = args.firstIndex(of: "--once").flatMap { i -> String? in
            i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : nil
        }
        let providers: [UsageProvider]
        if let requested {
            // An id that names nothing used to fall through to every provider,
            // so a typo printed ten reports and exited 0 — indistinguishable
            // from asking for all of them on purpose.
            guard let match = ProviderRegistry.provider(id: requested) else {
                let known = ProviderRegistry.all.map(\.id).sorted().joined(separator: ", ")
                FileHandle.standardError.write(Data(
                    "No provider with id \"\(requested)\". Known providers: \(known)\n".utf8))
                exit(2)
            }
            providers = [match]
        } else {
            providers = ProviderRegistry.all
        }

        Task { @MainActor in
            var anySucceeded = false
            for provider in providers {
                print("\(provider.displayName)  [\(provider.id)]"
                      + (provider.isVerified ? "" : "  — unverified integration"))
                print("  configured: \(provider.isConfigured)")

                if provider is ClaudeCodeProvider {
                    let load = ClaudeCredentials.load()
                    let sources = load.tokens.map {
                        "\($0.source.rawValue)(\($0.isExpired ? "expired" : "valid"))"
                    }
                    print("  credentials: \(sources.isEmpty ? "none" : sources.joined(separator: ", "))"
                          + (load.keychainDenied ? "  [keychain access DENIED]" : ""))
                }

                guard provider.isConfigured else {
                    print("  → \(provider.setupHint)\n")
                    continue
                }
                do {
                    let s = try await provider.fetch()
                    anySucceeded = true
                    if let account = s.accountLabel { print("  account: \(account)") }
                    for g in s.gauges + s.extras {
                        let title = g.title.padding(toLength: max(24, g.title.count),
                                                    withPad: " ", startingAt: 0)
                        let left = g.remainingPercentText.leftPadded(to: 5)
                        let used = String(format: "%5.1f%%", g.used * 100)
                        print("  \(title) \(left) left   used \(used)   \(Format.longReset(g.resetsAt))")
                    }
                } catch {
                    print("  ERROR: \(error.localizedDescription)")
                    if let e = error as? ProviderError {
                        print("  badge: \(e.badge)")
                        if e.suggestsSignIn, let command = provider.signInCommand {
                            print("  menu offers: Sign in to \(provider.displayName)… → \(command)")
                        }
                    }
                }
                print("")
            }
            exit(anySucceeded ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }


    // MARK: - Design harnesses

    /// Renders a SwiftUI view once per appearance and writes the two side by
    /// side, each on the backdrop its theme would sit on. Every `--*` harness
    /// composed this by hand before; it is the same picture every time.
    /// One agent as `--agents` prints it: the table row, then any reason its
    /// figures are missing.
    ///
    /// A row of dashes has a reason and the row already knows it. Printing the
    /// columns alone leaves the reader to guess whether the agent has done
    /// nothing, the harness records nothing, or the transcript is still being
    /// read — three different answers that look identical in a table. This
    /// machine had two sessions reporting no cost because records slightly
    /// over the read limit were skipped, and the table gave no hint of it.
    static func agentLines(for r: AgentRow) -> [String] {
        let ctx = r.contextFraction.map { String(format: "%.0f%%", $0 * 100) }
            ?? (r.contextTokens.map { "\($0 / 1000)k" } ?? "—")
        let ram = r.rssBytes.map { String(format: "%.0fMB", Double($0) / 1_048_576) } ?? "—"
        let chips = r.context.present.map { $0.kind.label }.joined(separator: ",")
        var lines = [tableRow([r.name, r.state.label, r.hostApp ?? "—",
                               Pricing.shortName(r.model) ?? "—",
                               ctx,
                               r.toolCalls.map(String.init) ?? r.turns.map { "\($0)t" } ?? "—",
                               r.costUSD.map { Pricing.money($0) } ?? "—",
                               ram,
                               chips.isEmpty ? "—" : chips])]
        if let note = r.note, !note.isEmpty { lines.append("    \(note)") }
        if let issue = r.localObservationIssue, !issue.isEmpty, issue != r.note {
            lines.append("    \(issue)")
        }
        return lines
    }

    @MainActor
    static func writeThemeSheet<V: View>(_ view: @autoclosure () -> V, to path: String,
                                         gap: CGFloat = 16) -> Bool {
        let backdrops = [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.14, alpha: 1)]
        var images: [NSImage] = []
        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            let host = NSHostingView(rootView: view())
            host.appearance = appearance
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(rep)
            images.append(image)
        }
        guard images.count == 2 else { return false }

        let width = images[0].size.width + images[1].size.width + gap * 3
        let height = max(images[0].size.height, images[1].size.height) + gap * 2
        let sheet = Renderer.bitmap(size: NSSize(width: width, height: height), scale: 2,
                                    appearance: NSAppearance(named: .aqua)!) {
            for (i, image) in images.enumerated() {
                let x = i == 0 ? 0 : gap + images[0].size.width + gap
                backdrops[i].setFill()
                NSRect(x: x, y: 0, width: image.size.width + gap * (i == 0 ? 2 : 1),
                       height: height).fill()
                image.draw(at: NSPoint(x: x + gap, y: (height - image.size.height) / 2),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        guard let rep = sheet.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        return true
    }

    private static func scanOrExit() -> [AgentRow] {
        do { return try AgentScan.scan() }
        catch {
            fputs("Local process discovery failed; no complete inventory is available.\n", stderr)
            exit(1)
        }
    }

    /// `--dashboard out.png`
    @MainActor
    static func renderDashboardAndExit(to path: String) -> Never {
        Task { @MainActor in
            let store = AgentStore.shared
            store.adoptForPreview(scanOrExit())
            // One column, so the sheet does not depend on the display that
            // happened to be attached — the rule `SettingsView.unbounded`
            // already states for the other panel.
            exit(writeThemeSheet(DashboardView(store: store, onSettings: {}, onTogglePin: {},
                                               singleColumn: true),
                                 to: path) ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--alert out.png`
    @MainActor
    static func renderAlertAndExit(to path: String) -> Never {
        Task { @MainActor in
            let rows = scanOrExit()
            guard let row = rows.first(where: { $0.state.rank <= 2 && $0.costUSD != nil })
                    ?? rows.first else { exit(1) }
            exit(writeThemeSheet(AgentAlert.previewCard(row), to: path, gap: 18) ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    @MainActor
    static func dumpAgentsAndExit() -> Never {
        // The harness folder is the only copy, and it is what the app reads.
        // Every diagnostic here reads it too, so every one of them has to put
        // it there first — otherwise the first thing a new install sees from
        // the command line is an empty agent table, an empty catalog and a
        // scan reporting zero sessions, none of which says "nothing has been
        // set up yet". The app seeds on start for exactly this reason; these
        // entry points were the ones that did not.
        HarnessDescriptor.seed()
        TranscriptStats.loadCache()
        HarnessEngine.loadCache()
        Task { @MainActor in
            // --bench: prove the incremental parser by scanning twice in one process.
            // Diagnostics: click a row from the terminal, and say what that
            // click actually did — the click path is otherwise untestable.
            if let i = CommandLine.arguments.firstIndex(of: "--focus"),
               i + 1 < CommandLine.arguments.count {
                let want = CommandLine.arguments[i + 1].lowercased()
                let rows = scanOrExit()
                guard let row = rows.first(where: { $0.name.lowercased() == want })
                    ?? rows.first(where: { $0.name.lowercased().contains(want)
                        || $0.agentID.lowercased().contains(want) }) else {
                    print("no row matching \(want): \(rows.map(\.name).joined(separator: ", "))")
                    exit(1)
                }
                print("row \(row.name) agent=\(row.agentID) pid=\(row.pid.map(String.init) ?? "nil") "
                    + "tmux=\(row.tmuxTarget ?? "—") cwd=\(row.cwd)")
                let app = row.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                print("owning app: \(app?.localizedName ?? "—") policy=\(app.map { "\($0.activationPolicy.rawValue)" } ?? "—")")
                print("reveal -> \(Focus.reveal(row).description)")
                exit(0)
            }

            // Design harness: render the first-run screen.
            if let i = CommandLine.arguments.firstIndex(of: "--onboarding"),
               i + 1 < CommandLine.arguments.count {
                let rows = scanOrExit()
                let view = OnboardingView(harnesses: Onboarding.harnesses(),
                                          accounts: Onboarding.accounts(ProviderRegistry.all),
                                          sessions: rows.count, onDone: {})
                exit(Diagnostics.writeThemeSheet(view, to: CommandLine.arguments[i + 1]) ? 0 : 1)
            }

            // `--log [n]` — where the log is, what level it is at, and the tail.
            if let i = CommandLine.arguments.firstIndex(of: "--log") {
                let argument = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "40"
                guard let count = Int(argument), (0...1_000).contains(count) else {
                    print("Log line count must be an integer from 0 through 1000."); exit(2)
                }
                print("level : \(Log.level.name)   (ANTARIUM_LOG, or \"logLevel\" in config.json)")
                print("file  : \(Log.url.path)")
                do {
                    let tail = try DiagnosticLogFile.tail(Log.url,lineCount:count)
                    print("---- \(tail.lines.count) complete lines · bounded 64 KiB tail\(tail.truncated ? "; earlier or incomplete lines omitted" : "") ----")
                    for line in tail.lines { print(line) }
                    exit(0)
                } catch {
                    print("The log could not be read safely. It may be missing, linked, unavailable or changed during the read.")
                    exit(1)
                }
            }

            // `--status` — a single readout of what the tool thinks is true.
            if CommandLine.arguments.contains("--status") {
                print("Antarium \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                print("  config    \(Config.url.path)")
                // The message already says what happened and what to do; the
                // gap was that this command never showed it.
                if let issue = Config.issue { print("    ! \(issue)") }
                print("  log       \(Log.url.path)  level=\(Log.level.name)")
                let descriptors = HarnessDescriptor.all()
                print("  harnesses \(descriptors.count) loaded from \(HarnessDescriptor.directory.path)")
                if !HarnessDescriptor.failures.isEmpty {
                    for f in HarnessDescriptor.failures { print("    ! \(f)") }
                }
                let rows = scanOrExit()
                var byHost: [String: Int] = [:]
                for row in rows { byHost[row.hostApp ?? "—", default: 0] += 1 }
                let working = rows.filter { if case .working = $0.state { return true }; return false }
                print("  agents    \(rows.count) rows, \(working.count) working")
                for (host, n) in byHost.sorted(by: { $0.key < $1.key }) {
                    print("    \(host.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n)")
                }
                print("  providers")
                for provider in ProviderRegistry.all {
                    let on = Settings.enabledAgents.contains(provider.id)
                    print("    \(provider.id.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                        + "configured=\(provider.isConfigured) shown=\(on) "
                        + "signIn=\(provider.signInCommand ?? "—")")
                }
                exit(0)
            }

            if CommandLine.arguments.contains("--tmux") {
                for row in scanOrExit() where row.hostApp == "tmux" {
                    print("  \(row.name.padding(toLength: max(16, row.name.count), withPad: " ", startingAt: 0)) "
                        + "\(row.agentID.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                        + "tmux=\(row.tmuxTarget ?? "— NONE")")
                }
                exit(0)
            }

            // `--remote-tmux [host ...]` — what each configured machine
            // actually answered. The onboarding help points here, because a
            // host that contributes nothing looks identical to a host with no
            // agents running until you can see which one it was.
            if CommandLine.arguments.contains("--remote-tmux") {
                let named = CommandLine.arguments.drop { $0 != "--remote-tmux" }
                    .dropFirst().filter { !$0.hasPrefix("-") }
                let hosts = named.isEmpty ? Settings.remoteTmuxHosts : Array(named)
                if hosts.isEmpty {
                    print("No hosts. Add one in Settings › Remote tmux, "
                        + "or pass them: --remote-tmux build-box")
                    exit(1)
                }
                // The same concurrent sweep the app runs, so what this
                // prints is what the dashboard will get — including the time
                // it takes with several machines.
                let began = ProcessInfo.processInfo.systemUptime
                let results = RemoteTmux.scanAll(hosts: hosts)
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                var total = 0
                for result in results {
                    let auth = RemoteTmux.hasPassword(for: result.host) ? "password" : "key"
                    print("\(result.host) [\(auth)] — "
                        + "\(result.issue ?? "\(result.rows.count) agent(s)")")
                    for row in result.rows {
                        print("  \(row.agentID.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                            + "\(row.coreName.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                            + "\(row.cwd)")
                    }
                    total += result.rows.count
                }
                print(String(format: "%d host(s), %d agent(s), %.1fs",
                             results.count, total, elapsed))
                exit(total > 0 ? 0 : 1)
            }

            if CommandLine.arguments.contains("--bench") {
                // What was measured, not just how long it took. Every entry
                // point seeds the harness folder first, so pointing
                // ANTARIUM_HOME at a directory holding one descriptor measures
                // all of them — a number read as a per-harness cost when it
                // was nothing of the kind.
                let harnesses = HarnessDescriptor.all()
                print("\(harnesses.count) harness(es) from \(HarnessDescriptor.directory.path)")
                // Absorb transcript history before the clock starts. The
                // budget is a statement about steady state, and a machine
                // still catching up is not in it — but skipping the gate
                // whenever that is true left it unreachable on most Macs.
                // Draining first makes the measured passes the ones the
                // budget is about.
                var warmups = 0
                while HarnessPerformanceBudget.needsWarmup(
                          backlogged: TranscriptStats.backloggedCount(),
                          passesRun: warmups) {
                    _ = scanOrExit()
                    warmups += 1
                }
                if warmups > 0 {
                    print("\(warmups) warm-up pass(es) absorbed transcript history")
                }
                var passes: [Double] = []
                for pass in 1...3 {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    let n = scanOrExit().count
                    let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                    passes.append(ms)
                    print(String(format: "pass %d: %6.1f ms  (%d sessions)", pass, ms, n))
                }
                let fastest = HarnessPerformanceBudget.steadyState(passes)
                // Transcript history still being absorbed makes these numbers
                // catch-up throughput rather than steady state, which is worth
                // saying here rather than only in the documentation.
                let behind = TranscriptStats.backloggedCount()
                if behind > 0 {
                    print("\(behind) transcript(s) still catching up — "
                        + "these passes measure throughput, not steady state")
                }
                TranscriptStats.saveCache()
                HarnessEngine.saveCache()
                // The fastest pass, because the first is cold and the budget
                // is about steady state. Reported either way, so a run that
                // was not gated says so rather than looking like one that
                // passed.
                let verdict = HarnessPerformanceBudget.verdict(
                    fastestMilliseconds: fastest, backlogged: behind)
                print(String(format: "fastest %.1f ms against a budget of %.0f ms — %@",
                             fastest, HarnessPerformanceBudget.scanMilliseconds,
                             {
                                 switch verdict {
                                 case .within: return "within it"
                                 case .over: return "OVER"
                                 case .inconclusive:
                                     // Over budget, but these passes were
                                     // doing more than a steady-state scan
                                     // does. Not a failure anybody could act
                                     // on, and not a pass either.
                                     return "over it, but not gated: still catching up"
                                 }
                             }() as String))
                exit(verdict == .over ? 1 : 0)
            }
            var rows = scanOrExit()
            if CommandLine.arguments.contains("--cloud") {
                do {
                    rows = AgentScan.sorted(AgentScan.merge(
                        local: rows, cloud: try await CloudScan.codexTasks()))
                } catch {
                    fputs(CloudScan.issue(for:error) + "\n", stderr)
                }
            }
            // Plain Swift padding: String(format:) with %s takes a pointer into
            // an NSString temporary that is freed before the format runs.
            print(tableRow(["NAME", "STATE", "HOST", "MODEL", "CONTEXT", "TOOLS", "COST", "RAM", "CONTEXT FILES"]))
            for r in rows { agentLines(for: r).forEach { print($0) } }
            // Every descriptor-driven harness, reported whether or not one is
            // running right now, so each reader is verifiable on its own.
            for d in HarnessDescriptor.all() {
                let found = HarnessEngine.sessions(d)
                if let newest = found.first {
                    print("\n\(d.id): \(found.count) sessions  newest "
                        + "cwd=\(newest.cwd ?? "—") model=\(newest.model ?? "—") "
                        + "ctx=\(newest.contextTokens.map { "\($0 / 1000)k" } ?? "—")"
                        + "/\(newest.contextWindow.map { "\($0 / 1000)k" } ?? "—") "
                        + "tools=\(newest.toolCalls) turns=\(newest.turns) subs=\(newest.subAgents) "
                        + "cost=\(Pricing.money(newest.costUSD)) "
                        + "last=\(newest.lastActivity.map { Format.age($0) } ?? "—")")
                } else {
                    print("\n\(d.id): no sessions")
                }
                if let health = HarnessEngine.health(for: d.id) {
                    print("  ERROR: \(health.message)")
                }
            }

            // Rows that are sparse for a knowable reason, so a blank line in
            // the table above is never mistaken for a failure to read.
            let noted = rows.compactMap { r in r.note.map { (r.name, $0) } }
            if !noted.isEmpty {
                print("")
                for (name, note) in noted { print("  \(name): \(note)") }
            }
            print("\n\(rows.count) sessions")
            TranscriptStats.saveCache()
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
