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
        let providers = requested.flatMap { ProviderRegistry.provider(id: $0) }.map { [$0] }
            ?? ProviderRegistry.all

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

    /// `--dashboard out.png`
    @MainActor
    static func renderDashboardAndExit(to path: String) -> Never {
        Task { @MainActor in
            let store = AgentStore.shared
            store.adoptForPreview(AgentScan.scan())
            exit(writeThemeSheet(DashboardView(store: store, onSettings: {}, onTogglePin: {}),
                                 to: path) ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--alert out.png`
    @MainActor
    static func renderAlertAndExit(to path: String) -> Never {
        Task { @MainActor in
            let rows = AgentScan.scan()
            guard let row = rows.first(where: { $0.state.rank <= 2 && $0.costUSD != nil })
                    ?? rows.first else { exit(1) }
            exit(writeThemeSheet(AgentAlert.previewCard(row), to: path, gap: 18) ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    @MainActor
    static func dumpAgentsAndExit() -> Never {
        TranscriptStats.loadCache()
        HarnessEngine.loadCache()
        Task { @MainActor in
            // --bench: prove the incremental parser by scanning twice in one process.
            // Diagnostics: click a row from the terminal, and say what that
            // click actually did — the click path is otherwise untestable.
            if let i = CommandLine.arguments.firstIndex(of: "--focus"),
               i + 1 < CommandLine.arguments.count {
                let want = CommandLine.arguments[i + 1].lowercased()
                let rows = AgentScan.scan()
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
                let rows = AgentScan.scan()
                let view = OnboardingView(harnesses: Onboarding.harnesses(),
                                          accounts: Onboarding.accounts(ProviderRegistry.all),
                                          sessions: rows.count, onDone: {})
                exit(Diagnostics.writeThemeSheet(view, to: CommandLine.arguments[i + 1]) ? 0 : 1)
            }

            // `--log [n]` — where the log is, what level it is at, and the tail.
            if let i = CommandLine.arguments.firstIndex(of: "--log") {
                let count = (i + 1 < CommandLine.arguments.count
                             ? Int(CommandLine.arguments[i + 1]) : nil) ?? 40
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: Log.url.path)[.size] as? Int).flatMap { $0 } ?? 0
                print("level : \(Log.level.name)   (ANTARIUM_LOG, or \"logLevel\" in config.json)")
                print("file  : \(Log.url.path)  \(size / 1024)KB")
                let text = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
                let lines = text.split(separator: "\n")
                print("---- last \(min(count, lines.count)) of \(lines.count) lines ----")
                for line in lines.suffix(count) { print(line) }
                exit(0)
            }

            // `--status` — a single readout of what the tool thinks is true.
            if CommandLine.arguments.contains("--status") {
                print("Antarium \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                print("  config    \(Config.url.path)")
                print("  log       \(Log.url.path)  level=\(Log.level.name)")
                let descriptors = HarnessDescriptor.all()
                print("  harnesses \(descriptors.count) loaded from \(HarnessDescriptor.directory.path)")
                if !HarnessDescriptor.failures.isEmpty {
                    for f in HarnessDescriptor.failures { print("    ! \(f)") }
                }
                let rows = AgentScan.scan()
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
                for row in AgentScan.scan() where row.hostApp == "tmux" {
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
                        + "or pass them: --remote-tmux quibus")
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
                for pass in 1...3 {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    let n = AgentScan.scan().count
                    let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                    print(String(format: "pass %d: %6.1f ms  (%d sessions)", pass, ms, n))
                }
                TranscriptStats.saveCache()
                HarnessEngine.saveCache()
                exit(0)
            }
            var rows = AgentScan.scan()
            if CommandLine.arguments.contains("--cloud") {
                do {
                    rows = AgentScan.sorted(AgentScan.merge(
                        local: rows, cloud: try await CloudScan.codexTasks()))
                } catch {
                    fputs("cloud scan failed: \(error.localizedDescription)\n", stderr)
                }
            }
            // Plain Swift padding: String(format:) with %s takes a pointer into
            // an NSString temporary that is freed before the format runs.
            print(tableRow(["NAME", "STATE", "HOST", "MODEL", "CONTEXT", "TOOLS", "COST", "RAM", "CONTEXT FILES"]))
            for r in rows {
                let ctx = r.contextFraction.map { String(format: "%.0f%%", $0 * 100) }
                    ?? (r.contextTokens.map { "\($0 / 1000)k" } ?? "—")
                let ram = r.rssBytes.map { String(format: "%.0fMB", Double($0) / 1_048_576) } ?? "—"
                let chips = r.context.present.map { $0.kind.label }.joined(separator: ",")
                print(tableRow([r.name, r.state.label, r.hostApp ?? "—",
                                Pricing.shortName(r.model) ?? "—",
                                ctx,
                                r.toolCalls.map(String.init) ?? r.turns.map { "\($0)t" } ?? "—",
                                r.costUSD.map { Pricing.money($0) } ?? "—",
                                ram,
                                chips.isEmpty ? "—" : chips]))
            }
            // Every descriptor-driven harness, reported whether or not one is
            // running right now, so each reader is verifiable on its own.
            for d in HarnessDescriptor.all() {
                let found = HarnessEngine.sessions(d)
                if let newest = found.first {
                    print("\n\(d.id): \(found.count) sessions  newest "
                        + "cwd=\(newest.cwd ?? "—") model=\(newest.model ?? "—") "
                        + "ctx=\(newest.contextTokens / 1000)k/\(newest.contextWindow.map { "\($0 / 1000)k" } ?? "—") "
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
