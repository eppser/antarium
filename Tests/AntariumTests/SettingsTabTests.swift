import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Antarium

/// Settings as tabs rather than one long scroll.
///
/// Seven sections stacked in a 420pt column came to roughly 1,600pt against a
/// 13" display's 715, so about two fifths was reachable at a time and the
/// section you wanted was usually off screen. The risk in splitting it is
/// that a section ends up in no tab at all, which is invisible: the panel
/// still looks complete, and the setting is simply gone.
@Suite("Settings sections all reach a tab")
struct SettingsTabTests {

    private func source() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
    }

    /// The section titles the panel draws, read from the source rather than
    /// listed here — a list of my own would agree with itself while the panel
    /// lost a section.
    private func declaredSections(_ text: String) -> [String] {
        var found: [String] = []
        for line in text.split(separator: "\n") {
            guard let start = line.range(of: "section(\"") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            found.append(String(rest[..<end]))
        }
        return found
    }

    @Test("There are sections to place")
    func sectionsExist() throws {
        let sections = declaredSections(try source())
        #expect(sections.count >= 7,
                Comment(rawValue: "only \(sections.count) sections were found: \(sections)"))
    }

    /// Every section call has to sit inside a tab's branch. One left outside
    /// would render on every tab; one inside no branch would render on none.
    @Test("Every section is drawn under exactly one tab")
    func everySectionHasATab() throws {
        let text = try source()
        let body = try #require(text.range(of: "ScrollView {"))
        let scroll = String(text[body.upperBound...].prefix(2_000))

        var currentTab: String?
        var placed: [String: String] = [:]
        var depth = 0
        for raw in scroll.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let range = line.range(of: "if tab == .") {
                currentTab = String(line[range.upperBound...].prefix(while: { $0.isLetter }))
                depth = 0
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if line.contains("section(\""), let tab = currentTab {
                let name = declaredSections(line).first ?? "?"
                placed[name] = tab
            }
            if currentTab != nil && depth <= 0 && line.contains("}") { currentTab = nil }
        }

        let all = Set(declaredSections(text).prefix(7))
        for name in all {
            #expect(placed[name] != nil,
                    Comment(rawValue: "\"\(name)\" is not inside any tab's branch"))
        }
        #expect(Set(placed.values).count == SettingsView.Tab.allCases.count,
                Comment(rawValue: "sections reach \(Set(placed.values).sorted()), "
                        + "but there are \(SettingsView.Tab.allCases.count) tabs"))
    }

    /// A tab with nothing in it is a tab that looks broken.
    @Test("Every tab has something to show", arguments: SettingsView.Tab.allCases)
    func everyTabHasContent(tab: SettingsView.Tab) throws {
        let text = try source()
        let marker = "if tab == .\(tab.rawValue)"
        let start = try #require(text.range(of: marker),
                                 Comment(rawValue: "\(tab.rawValue) has no branch in the body"))
        let branch = String(text[start.upperBound...].prefix(400))
        #expect(branch.contains("section(\""),
                Comment(rawValue: "the \(tab.title) tab draws no section"))
    }

    @Test("Each tab names itself and carries a symbol")
    func tabsAreLabelled() {
        for tab in SettingsView.Tab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.symbol.isEmpty)
            #expect(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) != nil,
                    Comment(rawValue: "\(tab.symbol) is not a system symbol, so the \(tab.title) "
                            + "tab draws an empty space where its icon should be"))
        }
        #expect(Set(SettingsView.Tab.allCases.map(\.title)).count
                == SettingsView.Tab.allCases.count, "two tabs share a name")
        #expect(Set(SettingsView.Tab.allCases.map(\.symbol)).count
                == SettingsView.Tab.allCases.count, "two tabs share an icon")
    }

    /// The rendered sheet has to keep showing everything, or a preview taken
    /// for comparison shows one tab's worth and looks like sections were
    /// deleted.
    @Test("A sheet rendered for comparison still shows every section")
    func unboundedShowsEverything() throws {
        let text = try source()
        let count = text.components(separatedBy: "|| unbounded").count - 1
        #expect(count == SettingsView.Tab.allCases.count,
                Comment(rawValue: "\(count) of \(SettingsView.Tab.allCases.count) tabs open up "
                        + "when the whole sheet is being rendered"))
    }
}

/// The width, which is not cosmetic.
@Suite("The settings panel is wide enough for what it says", .serialized)
@MainActor
struct SettingsWidthTests {

    /// A `Toggle`'s subtitle here is held to one line and carries each
    /// provider's `setupHint` — the one string that says how to fix a
    /// provider that is not signed in. At 420pt the longest of them
    /// truncated, so the panel was hiding its own instructions.
    @Test("Every provider's setup hint fits the panel")
    func setupHintsFit() {
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)
        // The subtitle is inset by the toggle's control and the panel's own
        // padding; 96pt is the space those take before any text is drawn.
        // Divided by the column count, so splitting the list is checked
        // against the hints rather than discovered by truncating them: the
        // design review proposed two columns here, which would give each hint
        // 206pt against a widest of 378.
        let columns = CGFloat(SettingsView.agentListColumns)
        let available = (SettingsView.width - 96
                         - SettingsView.agentListGutter * (columns - 1)) / columns
        var widest = 0.0, worst = ""
        for provider in ProviderRegistry.all {
            let w = (provider.setupHint as NSString).size(withAttributes: [.font: font]).width
            if w > widest { widest = w; worst = provider.setupHint }
        }
        #expect(widest <= available,
                Comment(rawValue: "\"\(worst)\" needs \(widest)pt of a \(available)pt line"))
    }

    /// And the fit is not achieved by the panel being enormous: the widest
    /// hint should use most of the line it is given, or the width is padding.
    @Test("The panel is not wider than its longest instruction needs")
    func widthIsNotExcessive() {
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)
        let widest = ProviderRegistry.all
            .map { ($0.setupHint as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        #expect(SettingsView.width - 96 - widest <= 80,
                Comment(rawValue: "the widest hint is \(widest)pt on a "
                        + "\(SettingsView.width - 96)pt line"))
    }

    @Test("The panel is at least as wide as the dashboard's own column")
    func notNarrowerThanTheDashboard() {
        #expect(SettingsView.width >= RowMetrics.panelReduced,
                "the settings panel is narrower than the list it configures")
    }
}
