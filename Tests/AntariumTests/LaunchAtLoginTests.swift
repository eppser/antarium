import Foundation
import Testing
@testable import Antarium

/// What the Open at Login switch says when it springs back.
///
/// The state belongs to macOS, so the switch re-reads the system after every
/// attempt — which is honest about what is true and silent about why. A
/// control that undoes itself and explains nothing reads as broken, and the
/// cases where macOS refuses are ordinary: an unsigned build, an app outside
/// Applications, a login item the user disabled in System Settings.
///
/// `set` itself cannot be tested — both paths end in `SMAppService`, and
/// reaching them would register a real login item on whoever ran the suite.
/// The message is a pure function for that reason, and it is the part a user
/// actually sees.
@Suite("The login switch explains a refusal")
struct LaunchAtLoginTests {

    @Test("A request that took says nothing")
    func successIsSilent() {
        #expect(LaunchAtLogin.refusal(requested: true, achieved: true, error: nil) == nil)
        #expect(LaunchAtLogin.refusal(requested: false, achieved: false, error: nil) == nil)
    }

    /// The system's own words when there are any: it knows more about why
    /// than this app does.
    @Test("A refusal with a reason quotes the reason")
    func refusalWithReason() throws {
        let message = try #require(LaunchAtLogin.refusal(
            requested: true, achieved: false, error: "Operation not permitted"))
        #expect(message.contains("Operation not permitted"))
        #expect(message.contains("switch this on"))
    }

    /// And when there is none — `register()` returning without error while
    /// the status stays disabled — the likely cause is named, because it is
    /// the one the user can act on.
    @Test("A refusal with no reason names the likely cause")
    func refusalWithoutReason() throws {
        let message = try #require(LaunchAtLogin.refusal(
            requested: true, achieved: false, error: nil))
        #expect(message.contains("unsigned") || message.contains("Applications"),
                Comment(rawValue: "the message offers nothing to act on: \(message)"))
    }

    /// Switching off has its own wording, or a failure to unregister would
    /// tell the user it could not switch something on.
    @Test("Failing to switch off does not say it could not switch on")
    func directionIsRight() throws {
        let off = try #require(LaunchAtLogin.refusal(
            requested: false, achieved: true, error: nil))
        #expect(off.contains("switch this off"), Comment(rawValue: off))
        #expect(!off.contains("switch this on"))
    }

    /// The subtitle falls back to the ordinary description, so the panel does
    /// not carry a stale complaint once nothing is wrong.
    @Test("With nothing refused there is nothing to show")
    func noRefusalNoMessage() {
        #expect(LaunchAtLogin.refusal(requested: true, achieved: true, error: "ignored") == nil,
                "a message was produced for a request that succeeded")
    }
}

/// The panel shows it. A weaker check than the ones above and deliberately
/// so: the subtitle is chosen inside a SwiftUI body, which nothing here can
/// reach — replacing it with the plain description survives the whole suite.
/// What this notices is a return to the shape where the switch springs back
/// and says nothing.
@Suite("The login switch's subtitle carries the refusal")
struct LaunchAtLoginPanelContractTests {

    @Test("The settings panel reads the refusal rather than a fixed subtitle")
    func panelShowsRefusal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
        let start = try #require(text.range(of: #"Toggle(title: "Open at Login""#),
                                 "the login toggle was renamed")
        let body = String(text[start.lowerBound...].prefix(400))
        #expect(body.contains("LaunchAtLogin.refusal"),
                "the switch springs back with no explanation again")
    }
}
