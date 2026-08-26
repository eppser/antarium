import AppKit
import SwiftUI

/// Menu-bar-only agent: no Dock icon, no windows, no main menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

/// NSApplication keeps only a weak reference to its delegate.
var retainedDelegate: AnyObject?

// Top-level code is nonisolated; everything below is main-thread-only AppKit.
// `antarium run -- claude` runs before any AppKit exists: it is a terminal
// program, not the menu bar app.
if let i = CommandLine.arguments.firstIndex(of: "run"), i == 1 {
    var rest = Array(CommandLine.arguments.dropFirst(2))
    if rest.first == "--" { rest.removeFirst() }
    guard let command = rest.first else {
        FileHandle.standardError.write(Data("usage: Antarium run -- <command> [args…]\n".utf8))
        exit(2)
    }
    exit(RunWrapper.run(command, Array(rest.dropFirst())))
}

MainActor.assumeIsolated {
    // Design harness: render sample states to a PNG and exit.
    if let i = CommandLine.arguments.firstIndex(of: "--preview"),
       i + 1 < CommandLine.arguments.count {
        exit(Preview.write(to: CommandLine.arguments[i + 1]) ? 0 : 1)
    }

    // Design harness: render the dashboard to a PNG and exit.
    if let i = CommandLine.arguments.firstIndex(of: "--dashboard"),
       i + 1 < CommandLine.arguments.count {
        Diagnostics.renderDashboardAndExit(to: CommandLine.arguments[i + 1])
    }

    // Design harness: render the stop-working banner and exit.
    if let i = CommandLine.arguments.firstIndex(of: "--alert"),
       i + 1 < CommandLine.arguments.count {
        Diagnostics.renderAlertAndExit(to: CommandLine.arguments[i + 1])
    }

    // Advisor for harness files: what's wrong, and what it would show.
    if let i = CommandLine.arguments.firstIndex(of: "--check"),
       i + 1 < CommandLine.arguments.count {
        exit(HarnessCheck.run(CommandLine.arguments[i + 1]))
    }

    if let i = CommandLine.arguments.firstIndex(of: "--migrate-harness"),
       i + 2 < CommandLine.arguments.count {
        exit(HarnessCLI.migrate(input: CommandLine.arguments[i + 1],
                                output: CommandLine.arguments[i + 2]))
    }

    if let i = CommandLine.arguments.firstIndex(of: "--evaluate-harness"),
       i + 1 < CommandLine.arguments.count {
        exit(HarnessCLI.evaluate(CommandLine.arguments[i + 1]))
    }

    if CommandLine.arguments.contains("--verify-harness-fixtures") {
        exit(HarnessCLI.verifyBundledFixtures())
    }

    if CommandLine.arguments.contains("--verify-harness-installations") {
        exit(HarnessCLI.verifyBundledInstallations())
    }

    if let i = CommandLine.arguments.firstIndex(of: "--settings"),
       i + 1 < CommandLine.arguments.count {
        exit(Diagnostics.writeThemeSheet(SettingsView(model: SettingsModel()),
                                         to: CommandLine.arguments[i + 1]) ? 0 : 1)
    }

    // Diagnostics: dump the agent scan and exit. --bench times it instead.
    if CommandLine.arguments.contains("--agents")
        || CommandLine.arguments.contains("--bench")
        || CommandLine.arguments.contains("--focus")
        || CommandLine.arguments.contains("--onboarding")
        || CommandLine.arguments.contains("--tmux")
        || CommandLine.arguments.contains("--status")
        || CommandLine.arguments.contains("--log") {
        Diagnostics.dumpAgentsAndExit()
    }

    // Diagnostics: fetch once, print what we read, exit.
    if CommandLine.arguments.contains("--once") {
        Diagnostics.runAndExit()
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.run()
}
