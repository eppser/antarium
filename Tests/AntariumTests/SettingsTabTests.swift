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

    /// What the panel actually draws under an agent's name.
    ///
    /// The first version of this measured `provider.setupHint` at 10pt. The
    /// view draws neither: it draws `row.detail` at 9.5pt, and `detail`
    /// composes "Sessions on this Mac · " in front of the hint for an agent
    /// that has sessions here but is not signed in. For Codex that is 467pt
    /// against a 424pt line — so the test passed while the panel truncated
    /// the instruction for fixing exactly the state the row was reporting.
    ///
    /// It wraps to a second line now, so the question is whether two lines
    /// are enough rather than whether one is.
    @Test("Every subtitle the agent list can draw fits two lines")
    func subtitlesFitTwoLines() {
        let font = NSFont.systemFont(ofSize: 9.5)
        // The subtitle is inset by the toggle's control and the panel's own
        // padding; 96pt is the space those take before any text is drawn.
        let line = SettingsView.width - 96
        let providers = ProviderRegistry.all
        // Both states that compose a subtitle, over every shipped provider.
        let states = [(false, true), (false, false), (true, true), (true, false)]
        var widest = 0.0, worst = ""
        for (signedIn, hasSessions) in states {
            let rows = SettingsView.agentRows(
                providers: providers, enabled: [],
                evidence: providers.map { .init(id: $0.id, signedIn: signedIn,
                                                hasSessions: hasSessions) })
            for row in rows {
                let w = (row.detail as NSString).size(withAttributes: [.font: font]).width
                if w > widest { widest = w; worst = row.detail }
            }
        }
        #expect(widest > 0, "no subtitles were measured")
        #expect(widest <= line * 2,
                Comment(rawValue: "\"\(worst)\" needs \(widest)pt of two \(line)pt lines"))
    }

    /// And the wrap is declared, or the measurement above is about a panel
    /// that still cuts the text off at one line.
    @Test("The subtitle wraps rather than truncating")
    func subtitleWraps() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "Text(subtitle)"),
                                 "the toggle no longer draws a subtitle")
        let declaration = String(source[start.lowerBound...].prefix(220))
        #expect(declaration.contains(".lineLimit(2)"),
                Comment(rawValue: "the subtitle is held to one line: \(declaration)"))
        #expect(declaration.contains("fixedSize(horizontal: false, vertical: true)"),
                "without this the second line has no height to wrap into")
    }

    /// The label column in front of each control.
    ///
    /// Measured in both directions, like the dashboard's row: too narrow
    /// truncates a label, and too wide puts an inch of nothing between a
    /// label and the control it names. It was 78pt for a widest label of
    /// 36.5 — more than half empty — because it was sized when the panel was
    /// 420 and nobody measured it again.
    @Test("The label column fits its labels and no more")
    func labelColumnFitsItsLabels() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
        // The labels the panel actually passes, read out of the source rather
        // than listed here — a list of mine would agree with itself.
        var labels: Set<String> = ["Accent"]
        var search = source[...]
        while let match = search.range(of: "title: \"") {
            let rest = search[match.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                let text = String(rest[..<end])
                if text.count <= 12, text.allSatisfy({ $0.isLetter }) { labels.insert(text) }
            }
            search = search[match.upperBound...]
        }
        #expect(labels.count >= 6,
                Comment(rawValue: "only \(labels.count) labels were found: \(labels.sorted())"))

        let font = NSFont.systemFont(ofSize: 11)
        var widest = 0.0, worst = ""
        for label in labels {
            let w = (label as NSString).size(withAttributes: [.font: font]).width
            if w > widest { widest = w; worst = label }
        }
        #expect(widest <= SettingsView.labelColumn,
                Comment(rawValue: "\"\(worst)\" needs \(widest)pt of a "
                        + "\(SettingsView.labelColumn)pt column"))
        #expect(SettingsView.labelColumn - widest <= 12,
                Comment(rawValue: "the column is \(SettingsView.labelColumn)pt for a widest "
                        + "label of \(widest)pt"))
    }

    /// And the labels end where the controls begin, rather than starting
    /// together and leaving a ragged gap of different widths.
    @Test("Labels are right-aligned against their controls")
    func labelsAreTrailingAligned() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
        let trailing = source.components(
            separatedBy: "frame(width: SettingsView.labelColumn, alignment: .trailing)").count - 1
        #expect(trailing == 3,
                Comment(rawValue: "\(trailing) of the three label columns are aligned to "
                        + "their controls"))
        #expect(!source.contains("width: 78"), "a label column carries its old number again")
    }

    /// The point of the tabs: the panel has to fit the display it opens on.
    ///
    /// Seven sections in one column came to about 1,600pt. A 13" MacBook has
    /// roughly 715pt of visible height once the menu bar and the Dock are
    /// accounted for, so two fifths of the panel was reachable at a time.
    /// Measured against the real view rather than estimated.
    @Test("The panel fits a 13\" display without scrolling")
    func theOpenTabFitsASmallDisplay() {
        let host = NSHostingView(rootView: SettingsView(model: SettingsModel()))
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        #expect(height > 200, Comment(rawValue: "the panel came to \(height)pt, which is "
                                      + "too small to be the whole of it"))
        #expect(height <= 715,
                Comment(rawValue: "the first tab is \(height)pt against the 715 a 13\" "
                        + "display has — it scrolls before anything is even switched on"))
    }

    /// And the chrome above the first control is a title bar, not a poster.
    /// The mark was 56pt over the name over the word "Settings", which was
    /// the whole of the panel's navigation when it was one long scroll. The
    /// tab bar carries that now.
    @Test("The header is one row")
    func headerIsOneRow() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private var header: some View"))
        let header = String(source[start.upperBound...].prefix(900))
        #expect(!header.contains("width: 56, height: 56"),
                "the header mark is back to poster size")
        #expect(header.contains("HStack"),
                "the header is a stack of rows again rather than one row")
    }

    @Test("The panel is at least as wide as the dashboard's own column")
    func notNarrowerThanTheDashboard() {
        #expect(SettingsView.width >= RowMetrics.panelReduced,
                "the settings panel is narrower than the list it configures")
    }
}
