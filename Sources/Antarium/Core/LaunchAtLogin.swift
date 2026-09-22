import Foundation
import ServiceManagement

/// Whether macOS starts Antarium when you log in.
///
/// The state belongs to the system, not to `config.json`: registering a login
/// item is what makes it true, so reading it back from our own settings file
/// would let the two disagree after the user changes it in System Settings.
/// Every surface that offers the choice goes through here.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Why the last attempt did not take, or nothing.
    ///
    /// The switch already springs back when macOS refuses, which is honest
    /// about the state and says nothing about the cause. A control that
    /// undoes itself in silence reads as broken — the agent toggles had the
    /// same problem, and the answer there was to say so where the user is
    /// looking rather than only in the log.
    nonisolated(unsafe) private(set) static var refusal: String?

    /// What to tell the user, given what was asked for and what happened.
    ///
    /// Pure, because the two paths that produce it both end in
    /// `SMAppService` and neither can be reached from a test without
    /// registering a real login item on whoever is running it.
    static func refusal(requested: Bool, achieved: Bool, error: String?) -> String? {
        guard requested != achieved else { return nil }
        let action = requested ? "switch this on" : "switch this off"
        // An unsigned or relocated build is the common case and the one the
        // user can do something about, so it is named rather than hidden
        // behind whatever the system said.
        let reason = error.map { "macOS refused: \($0)" }
            ?? "macOS refused. An app that is unsigned, or not in Applications, "
             + "often cannot register a login item."
        return "Could not \(action). \(reason)"
    }

    /// Returns whether the system ended up in the requested state, so a caller
    /// can show what actually happened rather than what it asked for.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled else { refusal = nil; return true }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("login", "open at login \(enabled ? "on" : "off")")
            let achieved = isEnabled == enabled
            refusal = Self.refusal(requested: enabled, achieved: achieved, error: nil)
            return achieved
        } catch {
            // Registration can be refused — an unsigned build, or a login item
            // the user disabled in System Settings. Saying so beats a toggle
            // that silently springs back.
            Log.warn("login", "could not turn open at login "
                + "\(enabled ? "on" : "off") — \(error.localizedDescription)")
            refusal = Self.refusal(requested: enabled, achieved: !enabled,
                                   error: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    static func toggle() -> Bool { set(!isEnabled) }
}
