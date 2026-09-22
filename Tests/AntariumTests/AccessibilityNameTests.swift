import Foundation
import Testing
@testable import Antarium

/// Every control says what it is and, where it has one, what state it is in.
///
/// This app's controls are icons. The menu bar item is a glyph, the header is
/// six symbols, and a settings toggle is a `Button` drawing a checkbox rather
/// than an `NSButton` that is one — so none of them announces anything unless
/// it is told to. A tooltip is for the pointer and reaches nobody else.
///
/// The settings panel is the case that matters most: it is made of toggles,
/// and without a trait and a value a screen reader hears "button" and has no
/// way to say which agents are switched on. Choosing what the bar shows is
/// the whole purpose of the panel.
@Suite("Controls name themselves and their state")
struct AccessibilityNameTests {

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
    }

    /// A declaration and everything inside it, by counting braces.
    ///
    /// The first version took a fixed number of lines, and a window of
    /// fourteen reported two controls as unlabelled that carry their labels
    /// at lines eighteen and twenty-one. The second stopped at the first
    /// blank line, which for a struct declaration is the line after it. A
    /// window has to be bounded by the thing it is reading, not by a number.
    private func declaration(_ marker: String, in text: String) throws -> String {
        let start = try #require(text.range(of: marker),
                                 Comment(rawValue: "\(marker) is no longer in this file"))
        var out = "", depth = 0, opened = false
        for line in text[start.lowerBound...].split(separator: "\n",
                                                    omittingEmptySubsequences: false) {
            out += line + "\n"
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if line.contains("{") { opened = true }
            if opened && depth <= 0 { break }
        }
        return out
    }

    @Test("A settings toggle announces what it is and whether it is on")
    func settingsToggleHasState() throws {
        let text = try source("Sources/Antarium/UI/SettingsView.swift")
        let body = try declaration("private struct Toggle: View", in: text)
        #expect(body.contains("accessibilityValue(on ? \"on\" : \"off\")"),
                "a toggle does not say whether it is on, so nothing can read back the choice")
        #expect(body.contains("accessibilityAddTraits"),
                "a toggle announces as a plain button rather than as a checkbox")
        // And the name comes from the title it already draws.
        #expect(body.contains("Text(title)"), "the toggle no longer draws its own title")
    }

    @Test("A capability button names the file it opens")
    func capabilityButtonIsNamed() throws {
        let text = try source("Sources/Antarium/UI/Dashboard.swift")
        let body = try declaration("private struct CapabilityDot: View", in: text)
        #expect(body.contains("accessibilityLabel"),
                "a button whose label is an icon opens a file under no name at all")
    }

    @Test("Each sort option is named and says whether it is chosen")
    func sortOptionsAreNamed() throws {
        let text = try source("Sources/Antarium/UI/Dashboard.swift")
        #expect(text.contains("accessibilityLabel(\"Sort by"),
                "the sort options lost their names")
        #expect(text.contains("accessibilityValue(selected ? \"Selected\" : \"Not selected\")"),
                "a sort option no longer says whether it is the chosen one")
    }

    /// The bar itself. Sixteen agents are drawn as letters and three pairs of
    /// those letters are shared, so the name is the only thing that tells two
    /// items apart for anyone not looking at the screen.
    @Test("A menu bar item is named after its provider")
    func menuBarItemIsNamed() throws {
        let text = try source("Sources/Antarium/AgentItem.swift")
        #expect(text.contains("setAccessibilityLabel(provider.displayName)"))
    }

    /// Every button in the interface has a name, from one of the three places
    /// a name can come from: a text label it draws, or an explicit one.
    @Test("No button is left without a name")
    func noUnnamedButtons() throws {
        var unnamed: [String] = []
        for path in ["Sources/Antarium/UI/Dashboard.swift",
                     "Sources/Antarium/UI/SettingsView.swift",
                     "Sources/Antarium/UI/PanelChrome.swift"] {
            let text = try source(path)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                // SwiftUI's own `Button`, not a type whose name ends in one:
                // `IconButton(…)` is a call to a view that labels itself, and
                // matching on the substring reported both of its call sites.
                let isButton = trimmed.hasPrefix("Button {") || trimmed.hasPrefix("Button(")
                    || trimmed.contains(" Button {") || trimmed.contains(" Button(")
                guard isButton else { continue }
                // A Button("…") names itself.
                if trimmed.contains("Button(\"") { continue }
                let body = lines[index..<min(index + 30, lines.count)].joined(separator: "\n")
                if body.contains("accessibilityLabel") || body.contains("Text(") { continue }
                unnamed.append("\(path.split(separator: "/").last ?? ""):\(index + 1)")
            }
        }
        #expect(unnamed.isEmpty,
                Comment(rawValue: "a control with no name: \(unnamed.joined(separator: ", "))"))
    }
}
