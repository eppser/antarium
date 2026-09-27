import Foundation
import Testing
@testable import Antarium

/// A configuration that does not take effect runs the suite twice.
///
/// `verify.sh` runs the suite five ways, and each is worth only as much as the
/// difference it makes. Nothing asserted that any of them landed. A run that silently
/// stopped differing from the default would pass, and the gate would report five
/// configurations while checking one — the same shape as a strict build that reported
/// "clean" for files it had not recompiled.
///
/// This project has already been caught by exactly that: a suite run under a German
/// locale proved nothing, because `Locale.current` on macOS does not follow `LANG`.
/// That is why there is no locale configuration. The finding lived in a commit
/// message; it is a test now, because a platform fact that shaped a decision should
/// fail out loud if it ever stops being true.
@Suite("The gate's configurations reach the code they are meant to")
struct ConfigurationTakesEffectTests {

    /// Checked with a probe on 2026-09-27: `TZ=Asia/Kolkata` moves
    /// `TimeZone.current` to +05:30, so the timezone configuration is real.
    ///
    /// Silent when `TZ` is unset, deliberately. The claim only exists under a run
    /// that sets it, and that is the run whose worth this protects — asserting
    /// something about the default run's timezone would be asserting whatever this
    /// machine happens to be set to.
    @Test("A run that names a timezone is run in it")
    func timezoneReachesFoundation() {
        guard let named = ProcessInfo.processInfo.environment["TZ"], !named.isEmpty else {
            #expect(Bool(true), "no TZ in the environment, so there is nothing to have taken")
            return
        }
        #expect(TimeZone.current.identifier == named,
                Comment(rawValue: "TZ names \(named) and the process is running in "
                        + "\(TimeZone.current.identifier) — the gate's timezone run is "
                        + "the default run again"))
    }

    /// The other half, and the one that is unconditional: `LANG` does *not* reach
    /// `Locale.current` on macOS, which is why no locale configuration exists.
    ///
    /// If this ever starts passing the other way, a locale run becomes worth adding
    /// — so the failure is the useful signal, not the pass.
    @Test("A language named in the environment does not move the locale")
    func languageDoesNotReachLocale() {
        let language = "de_DE.UTF-8"
        guard ProcessInfo.processInfo.environment["LANG"] != language else {
            // Running under exactly the probe's value: nothing to conclude.
            #expect(Bool(true))
            return
        }
        #expect(!Locale.current.identifier.hasPrefix("de_DE"),
                Comment(rawValue: "Locale.current now follows LANG on this platform — a "
                        + "locale configuration in verify.sh would be worth adding, and "
                        + "the note saying it proves nothing is out of date"))
    }

    /// `ANTARIUM_HOME` is how the bare-machine run is made bare, and it is read by
    /// `Config.directory`. A run that set it and was ignored would test this
    /// developer's settings instead of an empty machine.
    @Test("A run that names a settings directory uses it")
    func settingsDirectoryReachesConfig() {
        guard let named = ProcessInfo.processInfo.environment["ANTARIUM_HOME"],
              !named.isEmpty else {
            #expect(Bool(true), "no ANTARIUM_HOME, so this is the ordinary run")
            return
        }
        #expect(Config.directory.path.hasPrefix(named),
                Comment(rawValue: "ANTARIUM_HOME names \(named) and settings resolve to "
                        + "\(Config.directory.path) — the bare-machine run is reading a "
                        + "real home"))
    }

    /// And the gate still names the configurations these assertions are about, so a
    /// run being dropped from `verify.sh` is visible here rather than only in the
    /// absence of a line of output.
    @Test("The gate runs the configurations these tests describe")
    func gateRunsThem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("verify.sh"),
                               encoding: .utf8)
        // The *invocation*, not any occurrence of the string.
        //
        // The first version asked whether `verify.sh` contained "TZ=Asia/Kolkata"
        // anywhere. It does, twice: once on the line that runs the suite and once in
        // the label printed beside the result. Changing the run to `TZ=UTC` left the
        // label untouched and this test passing — the same weakness as the CI test
        // one commit earlier, which asked whether a step *mentioned* `warning:` when
        // its own comment did. A claim about what a script does has to name the line
        // that does it.
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        let suiteRuns = lines.filter { $0.contains("./test.sh") }
        #expect(suiteRuns.count >= 4,
                Comment(rawValue: "the gate runs the suite \(suiteRuns.count) times"))
        #expect(suiteRuns.contains { $0.contains("TZ=Asia/Kolkata") },
                "no run of the suite names a timezone, so the gate no longer tests outside UTC")
        #expect(suiteRuns.contains { $0.contains("ANTARIUM_HOME=") },
                Comment(rawValue: "no run of the suite names a settings directory, so the "
                        + "gate no longer tests a machine that has never run Antarium"))
        #expect(!suiteRuns.contains { $0.contains("LANG=") },
                "a run of the suite names a language, which proves nothing on macOS")
    }
}
