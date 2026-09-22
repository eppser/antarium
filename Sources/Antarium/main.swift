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

if let issue = LaunchArguments.validate(Array(CommandLine.arguments.dropFirst())) {
    FileHandle.standardError.write(Data((issue + "\n").utf8))
    exit(2)
}
if LaunchArguments.requestsHelp(Array(CommandLine.arguments.dropFirst())) {
    print(LaunchArguments.help); exit(0)
}

// Before anything reads or writes the settings folder, whichever entry point
// this is.
//
// These two calls used to live in `AppController.start`, so only the menu bar
// app made the folder private. A fresh folder is created 0700 and so looked
// right, but one that already existed — made by a version that predates the
// securing, or by hand — stayed exactly as it was through every command. The
// setup hints tell people to put keys in `~/.antarium/keys`, and the folder
// they land in is the one the last thing to touch it left behind.
Config.secure(Config.directory)
Config.secure(Config.keysDirectory)

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
    if CommandLine.arguments.contains("--print-remote-discovery-command") {
        print(RemoteTmux.remoteCommand,terminator:"")
        exit(0)
    }
    if let i = CommandLine.arguments.firstIndex(of:"--verify-remote-discovery-reply"), i + 1 < CommandLine.arguments.count {
        exit(RemoteDiscoveryEvaluation.verify(file:CommandLine.arguments[i + 1]))
    }

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

    if CommandLine.arguments.contains("--detect-agents") {
        exit(HarnessCLI.detectAgents(apply: CommandLine.arguments.contains("--apply")))
    }

    if CommandLine.arguments.contains("--verify-harness-quota") {
        exit(HarnessCLI.verifyBundledQuota())
    }

    if CommandLine.arguments.contains("--verify-harness-installations") {
        exit(HarnessCLI.verifyBundledInstallations())
    }

    if let i = CommandLine.arguments.firstIndex(of: "--settings"),
       i + 1 < CommandLine.arguments.count {
        exit(Diagnostics.writeThemeSheet(SettingsView(model: SettingsModel(), unbounded: true),
                                         to: CommandLine.arguments[i + 1]) ? 0 : 1)
    }

    // Diagnostics: dump the agent scan and exit. --bench times it instead.
    if CommandLine.arguments.contains("--agents")
        || CommandLine.arguments.contains("--bench")
        || CommandLine.arguments.contains("--focus")
        || CommandLine.arguments.contains("--onboarding")
        || CommandLine.arguments.contains("--tmux")
        || CommandLine.arguments.contains("--remote-tmux")
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
