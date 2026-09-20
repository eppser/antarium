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

    /// Returns whether the system ended up in the requested state, so a caller
    /// can show what actually happened rather than what it asked for.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled else { return true }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("login", "open at login \(enabled ? "on" : "off")")
            return isEnabled == enabled
        } catch {
            // Registration can be refused — an unsigned build, or a login item
            // the user disabled in System Settings. Saying so beats a toggle
            // that silently springs back.
            Log.warn("login", "could not turn open at login "
                + "\(enabled ? "on" : "off") — \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func toggle() -> Bool { set(!isEnabled) }
}
