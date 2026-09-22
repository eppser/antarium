import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Antarium

/// Splitting the agent list into two columns.
///
/// The panel is a single column that grows to the height of the screen, on a
/// display that is wider than it is tall. Two columns halve that height. The
/// decision is arithmetic on the row count, so it is settled here rather than
/// inside a layout pass.
@Suite("How many columns the list uses")
struct ColumnDecisionTests {

    private let panel: CGFloat = 600
    /// A 1920-wide display, comfortably able to hold two 600pt columns.
    private let wide: CGFloat = 1_920
    /// Narrow enough that two columns and their margins would leave less
    /// than a tenth of the screen clear. A 13" MacBook's 1440 is *not* this
    /// case — 1216pt of panel fits it, at 84% — which is why the ceiling is
    /// a share of the screen and not a plain fit.
    private let narrow: CGFloat = 1_280

    private func columns(_ rows: Int, previous: Int = 1, width: CGFloat? = nil) -> Int {
        PanelPlacement.columns(rowCount: rows, previous: previous,
                               panel: panel, visibleWidth: width ?? wide)
    }

    @Test("A short list stays in one column")
    func shortListsAreOneColumn() {
        for rows in 0...7 { #expect(columns(rows) == 1, Comment(rawValue: "\(rows) rows")) }
    }

    @Test("A long list uses two")
    func longListsAreTwoColumns() {
        for rows in [9, 12, 40, 200] { #expect(columns(rows) == 2, Comment(rawValue: "\(rows) rows")) }
    }

    /// The boundary keeps what it had. A list of live agents crosses it
    /// constantly as sessions start and finish, and without this the panel
    /// changes width under the pointer every time.
    @Test("The boundary row count keeps whatever layout it had")
    func theBoundaryIsSticky() {
        #expect(columns(8, previous: 1) == 1, "eight rows widened the panel")
        #expect(columns(8, previous: 2) == 2, "eight rows narrowed the panel")
        // And the hysteresis is a band, not a single sticky value: coming down
        // from a long list, two columns survive until the list is properly short.
        #expect(columns(9, previous: 1) == 2)
        #expect(columns(7, previous: 2) == 1)
    }

    /// A screen that cannot hold two columns gets one, however long the list.
    /// Being clipped is worse than scrolling.
    @Test("A display too narrow for two columns keeps one")
    func narrowDisplaysKeepOneColumn() {
        #expect(columns(40, width: narrow) == 1)
        #expect(columns(40, previous: 2, width: narrow) == 1,
                "a panel dragged to a smaller display stayed two columns wide")
        // Exactly enough is enough.
        let exact = (2 * panel + 2 * PanelPlacement.margin) / PanelPlacement.maxScreenShare
        #expect(columns(40, width: exact.rounded(.up)) == 2)
        #expect(columns(40, width: exact - 1) == 1)
        // A 13" MacBook does hold two columns; the ceiling is what decides,
        // not whether they merely fit.
        #expect(columns(40, width: 1_440) == 2, "a 13\" display was refused two columns")
    }
}

/// Which rows go in which column.
@Suite("Filling the columns")
struct ColumnFillTests {

    private func split(_ rows: Int, into count: Int) -> [[Int]] {
        (0..<count).map { Array(PanelPlacement.column($0, of: count, rows: rows)) }
    }

    /// Column-major: the sort is the reason the list is ordered at all, so
    /// reading down column one then down column two must reproduce it.
    @Test("Reading down the columns in turn gives the original order")
    func fillIsColumnMajor() {
        for rows in [1, 2, 7, 8, 9, 15, 16, 41] {
            let joined = split(rows, into: 2).flatMap { $0 }
            #expect(joined == Array(0..<rows),
                    Comment(rawValue: "\(rows) rows came back as \(joined)"))
        }
    }

    @Test("Every row appears exactly once")
    func noRowIsLostOrRepeated() {
        for rows in [0, 1, 9, 41, 100] {
            let all = split(rows, into: 2).flatMap { $0 }
            #expect(all.count == rows, Comment(rawValue: "\(rows) rows became \(all.count)"))
            #expect(Set(all).count == rows, "a row appeared in both columns")
        }
    }

    /// An odd count leans left. A gap at the bottom of the first column with
    /// a row beside it reads as a missing entry.
    @Test("An uneven split puts the extra row in the first column")
    func unevenSplitsLeanLeft() {
        let odd = split(9, into: 2)
        #expect(odd[0].count == 5)
        #expect(odd[1].count == 4)
        #expect(split(8, into: 2).map(\.count) == [4, 4])
    }

    /// One column is the whole list, which is the case every short list and
    /// every narrow display takes.
    @Test("A single column holds everything")
    func oneColumnHoldsEverything() {
        #expect(Array(PanelPlacement.column(0, of: 1, rows: 5)) == Array(0..<5))
        #expect(PanelPlacement.column(0, of: 1, rows: 0).isEmpty)
    }

    /// Asked for a column that does not exist, it yields nothing rather than
    /// a range that would trap when used to subscript.
    @Test("An out-of-range column is empty, not a crash")
    func outOfRangeColumnsAreEmpty() {
        #expect(PanelPlacement.column(2, of: 2, rows: 9).isEmpty)
        #expect(PanelPlacement.column(-1, of: 2, rows: 9).isEmpty)
        for count in [1, 2] {
            for index in 0..<count {
                let range = PanelPlacement.column(index, of: count, rows: 9)
                #expect(range.lowerBound >= 0 && range.upperBound <= 9,
                        Comment(rawValue: "\(range) is not inside 0..<9"))
            }
        }
    }
}

/// The panel's width and the content inside it have to be the same number.
///
/// They were not. The list's horizontal inset is applied once to the stack
/// of columns, and it was being subtracted from each column — exact at one
/// column, 12pt short at two, so the error arrived with the layout that was
/// just added. A framed view pads its content to the frame, so the panel
/// looked right and carried 12pt of dead space down its middle.
@Suite("A panel is as wide as what is in it")
struct ColumnWidthIdentityTests {

    @Test("Columns, gutters and insets add up to the panel",
          arguments: [(1, 600.0, 6.0), (2, 1212.0, 6.0), (1, 400.0, 5.0), (2, 812.0, 5.0)])
    func widthsAddUp(columns: Int, panel: CGFloat, inset: CGFloat) {
        let inner = RowMetrics.columnInner(panel: panel, columns: columns, inset: inset)
        let content = CGFloat(columns) * inner
            + RowMetrics.gutter * CGFloat(columns - 1)
            + 2 * inset
        #expect(abs(content - panel) < 0.01,
                Comment(rawValue: "\(columns) column(s) of \(inner) come to \(content) "
                        + "inside a \(panel)pt panel"))
    }

    /// And a column is still most of the panel, or the arithmetic could
    /// balance by making the columns nothing.
    @Test("A column keeps most of the width it is given")
    func columnsAreNotDegenerate() {
        let inner = RowMetrics.columnInner(panel: 1_212, columns: 2, inset: 6)
        #expect(inner > 560, Comment(rawValue: "a column came to \(inner)pt"))
    }

    @Test("A column count of zero does not divide by it")
    func zeroColumnsIsOne() {
        #expect(RowMetrics.columnInner(panel: 600, columns: 0, inset: 6)
                == RowMetrics.columnInner(panel: 600, columns: 1, inset: 6))
    }
}

/// The decision above, actually applied to a panel.
///
/// The arithmetic being right is not the same as the layout using it. This
/// builds the real view over a synthetic store and measures what AppKit
/// gives it, so "the panel widens" is a measurement rather than a claim.
@Suite("The panel lays itself out in the columns it chose", .serialized)
@MainActor
struct ColumnLayoutRenderTests {

    private func rows(_ count: Int) -> [AgentRow] {
        (0..<count).map {
            AgentRow(id: "row-\($0)", agentID: "claude-code", name: "project-\($0)",
                     cwd: "/synthetic/project-\($0)", state: .waiting)
        }
    }

    private func fittingWidth(rowCount: Int) -> CGFloat {
        let store = AgentStore.shared
        store.adoptForPreview(rows(rowCount))
        let host = NSHostingView(rootView: DashboardView(store: store, onSettings: {},
                                                         onTogglePin: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Wide enough to be allowed two columns at all, or this measures the
    /// ceiling instead of the decision.
    private var screenIsWideEnough: Bool {
        PanelPlacement.columns(rowCount: 40, previous: 1, panel: RowMetrics.panelFull,
                               visibleWidth: NSScreen.main?.visibleFrame.width
                                   ?? RowMetrics.panelFull) == 2
    }

    @Test("A short list is one column wide")
    func shortListIsOneColumn() {
        let width = fittingWidth(rowCount: 4)
        #expect(abs(width - RowMetrics.panelFull) < 1,
                Comment(rawValue: "four rows produced a \(width)pt panel"))
    }

    @Test("A long list is two columns wide")
    func longListIsTwoColumns() throws {
        try #require(screenIsWideEnough, "this display cannot hold two columns")
        let expected = RowMetrics.panelFull * 2 + RowMetrics.gutter
        let width = fittingWidth(rowCount: 20)
        #expect(abs(width - expected) < 1,
                Comment(rawValue: "twenty rows produced a \(width)pt panel, not \(expected)"))
    }

    /// Widening the panel must not widen its content past it. The divider
    /// between the columns is drawn over the stack rather than placed in it,
    /// because a view between two columns takes a gutter's spacing on each
    /// side — which would push the content 12pt past the frame and undo the
    /// identity the arithmetic test asserts.
    @Test("The column divider does not take part in the layout")
    func dividerIsAnOverlay() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        let stack = try #require(source.range(of: "HStack(alignment: .top, spacing: RowMetrics.gutter)"),
                                 "the columns are no longer an HStack")
        // To the end of the list's own view, which is where the height it
        // reports is measured — a window chosen by counting rather than by
        // picking a round number that happened to reach.
        let rest = source[stack.upperBound...]
        let end = try #require(rest.range(of: ".modifier(MeasureHeight())"),
                               "the list no longer measures its own height")
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains(".overlay(alignment: .topLeading)"),
                "the divider is not an overlay, so it is taking layout space")
        #expect(!body.contains("Divider()"),
                "a Divider between the columns adds a gutter on each side of itself")
        // And the two columns still come to the panel's width with it there.
        let inner = RowMetrics.columnInner(panel: 1_212, columns: 2, inset: 6)
        #expect(abs((2 * inner + RowMetrics.gutter + 12) - 1_212) < 0.01)
    }

    /// A sheet rendered for comparison must not depend on the display that
    /// happened to be attached. `SettingsView` has carried that rule since it
    /// was written; the column count reads `NSScreen`, so the dashboard
    /// needed the same escape and did not have one.
    @Test("A rendered sheet is one column whatever the list holds")
    func renderedSheetsAreDeterministic() {
        let store = AgentStore.shared
        store.adoptForPreview(rows(40))
        let host = NSHostingView(rootView: DashboardView(store: store, onSettings: {},
                                                          onTogglePin: {}, singleColumn: true))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.width - RowMetrics.panelFull) < 1,
                Comment(rawValue: "forty rows rendered \(host.fittingSize.width)pt wide"))
    }

    /// And the escape is used where the sheet is written, or the parameter
    /// exists and the image still depends on the machine.
    @Test("The diagnostic renderer asks for one column")
    func theRendererUsesIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/Diagnostics.swift"), encoding: .utf8)
        let call = try #require(source.range(of: "DashboardView(store: store"),
                                "the dashboard sheet is no longer rendered here")
        #expect(String(source[call.lowerBound...].prefix(240)).contains("singleColumn: true"),
                "the rendered sheet still widens with the display it is taken on")
    }

    /// And the second column earns its width: twenty rows in two columns must
    /// be shorter than twenty in one, or the panel got wider for nothing —
    /// which is the whole complaint this answers.
    @Test("Two columns make the panel shorter, not just wider")
    func twoColumnsAreShorter() throws {
        try #require(screenIsWideEnough, "this display cannot hold two columns")
        let store = AgentStore.shared
        func height(_ count: Int) -> CGFloat {
            store.adoptForPreview(rows(count))
            let host = NSHostingView(rootView: DashboardView(store: store, onSettings: {},
                                                             onTogglePin: {}))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let short = height(6)            // one column, six rows
        let long = height(12)            // two columns, six rows each
        #expect(long < short * 1.35,
                Comment(rawValue: "twelve rows in two columns came to \(long)pt against "
                        + "\(short)pt for six in one — the split did not halve the height"))
    }
}
