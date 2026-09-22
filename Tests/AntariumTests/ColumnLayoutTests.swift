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
    /// A 1920x1080 display, which holds two columns side by side.
    private let wide: CGFloat = 1_920
    private let tall: CGFloat = 1_055
    /// Narrow enough that two columns and their margins would leave less
    /// than a tenth of the screen clear.
    private let narrow: CGFloat = 1_280

    private func columns(_ rows: Int, previous: Int = 1,
                         width: CGFloat? = nil, height: CGFloat? = nil,
                         reduced: Bool = false) -> Int {
        PanelPlacement.columns(
            rowCount: rows, previous: previous,
            contentHeight: RowMetrics.singleColumnHeight(rows: rows, reduced: reduced),
            panel: panel, visibleWidth: width ?? wide, visibleHeight: height ?? tall)
    }

    /// How many rows one column holds on a given display, from the same
    /// arithmetic the decision uses.
    private func fits(_ height: CGFloat, reduced: Bool = false) -> Int {
        var n = 0
        while RowMetrics.singleColumnHeight(rows: n + 1, reduced: reduced)
                <= height - PanelPlacement.verticalAllowance { n += 1 }
        return n
    }

    /// The rule, and the thing that was wrong before it: the list used to
    /// split at nine rows whether or not one column had room, and one column
    /// holds about twenty-three on a 1080p display.
    @Test("One column, for as long as one column fits")
    func oneColumnWhileItFits() {
        let capacity = fits(tall)
        #expect(capacity > 15,
                Comment(rawValue: "one column holds only \(capacity) rows, so this display "
                        + "cannot show the rule"))
        for rows in [0, 1, 4, 9, 12, capacity] {
            #expect(columns(rows) == 1,
                    Comment(rawValue: "\(rows) rows split into two columns with room for "
                            + "\(capacity) in one"))
        }
    }

    @Test("Two columns only once one will not fit")
    func twoColumnsWhenItDoesNot() {
        let capacity = fits(tall)
        #expect(columns(capacity + 1) == 2,
                Comment(rawValue: "\(capacity + 1) rows stayed in one column on a display "
                        + "holding \(capacity)"))
        #expect(columns(capacity * 3) == 2)
    }

    /// A shorter display splits sooner, which is the point: the question is
    /// whether it fits, not how many there are.
    @Test("The same list splits on a short display and not on a tall one")
    func theDisplayDecides() {
        let short: CGFloat = 700
        let rows = fits(short) + 2
        #expect(columns(rows, height: short) == 2,
                Comment(rawValue: "\(rows) rows fitted a \(short)pt display in one column"))
        #expect(columns(rows, height: 1_800) == 1,
                Comment(rawValue: "\(rows) rows split on an 1800pt display"))
    }

    /// The compact list is half the height, so it fits about twice as many.
    @Test("A reduced row is shorter, so more of them fit before splitting")
    func reducedFitsMore() {
        #expect(fits(tall, reduced: true) > fits(tall),
                "the compact list does not hold more rows than the full one")
        let justOverFull = fits(tall) + 1
        #expect(columns(justOverFull) == 2)
        #expect(columns(justOverFull, reduced: true) == 1,
                "a list that fits when compact was split anyway")
    }

    /// A display too narrow for two columns keeps one, however long the list.
    /// Being clipped is worse than scrolling.
    @Test("A display too narrow for two columns keeps one")
    func narrowDisplaysKeepOneColumn() {
        #expect(columns(200, width: narrow) == 1)
        #expect(columns(200, previous: 2, width: narrow) == 1)
        #expect(columns(200, width: 1_440) == 2, "a 13\" display was refused two columns")
    }

    /// One row cannot be split, whatever the arithmetic says about height.
    @Test("A single row is never two columns")
    func oneRowIsOneColumn() {
        #expect(columns(1, height: 200) == 1)
        #expect(columns(0, height: 200) == 1)
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

    private func fittingHeight(rowCount: Int) -> CGFloat {
        let store = AgentStore.shared
        store.adoptForPreview(rows(rowCount))
        let host = NSHostingView(rootView: DashboardView(store: store, onSettings: {},
                                                          onTogglePin: {}, singleColumn: true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func fittingWidth(rowCount: Int) -> CGFloat {
        let store = AgentStore.shared
        store.adoptForPreview(rows(rowCount))
        let host = NSHostingView(rootView: DashboardView(store: store, onSettings: {},
                                                         onTogglePin: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Enough rows that one column will not fit this display, so the render
    /// tests are about the decision rather than about the screen.
    /// The most rows one column holds on this display, and one more.
    private var rowsThatFit: Int {
        let room = (NSScreen.main?.visibleFrame.height ?? 900)
            - PanelPlacement.verticalAllowance
        var n = 0
        while RowMetrics.singleColumnHeight(rows: n + 1, reduced: false) <= room { n += 1 }
        return n
    }
    private var rowsThatDoNotFit: Int { rowsThatFit + 1 }

    /// Wide enough to be allowed two columns at all, or this measures the
    /// ceiling instead of the decision.
    private var screenIsWideEnough: Bool {
        let screen = NSScreen.main?.visibleFrame
        return PanelPlacement.columns(
            rowCount: rowsThatDoNotFit, previous: 1,
            contentHeight: RowMetrics.singleColumnHeight(rows: rowsThatDoNotFit,
                                                         reduced: false),
            panel: RowMetrics.panelFull,
            visibleWidth: screen?.width ?? RowMetrics.panelFull,
            visibleHeight: screen?.height ?? 900) == 2
    }

    /// The two constants the split decision rests on, re-measured against
    /// the real view. They are what turns a row count into a height, so if
    /// they drift the panel splits at the wrong moment — and nothing about
    /// the result would look wrong.
    @Test("A row costs what the metrics say it costs")
    func pitchAndChromeAreReal() {
        let one = fittingHeight(rowCount: 1)
        let two = fittingHeight(rowCount: 2)
        let nine = fittingHeight(rowCount: 9)
        #expect(abs((two - one) - RowMetrics.rowPitch) < 0.5,
                Comment(rawValue: "a row adds \(two - one)pt, not \(RowMetrics.rowPitch)"))
        #expect(abs((one - RowMetrics.rowPitch) - RowMetrics.chrome) < 0.5,
                Comment(rawValue: "the chrome is \(one - RowMetrics.rowPitch)pt, not "
                        + "\(RowMetrics.chrome)"))
        // And the arithmetic predicts a longer list, not just two short ones.
        #expect(abs(RowMetrics.singleColumnHeight(rows: 9, reduced: false) - nine) < 0.5,
                Comment(rawValue: "nine rows measure \(nine)pt and the metrics predict "
                        + "\(RowMetrics.singleColumnHeight(rows: 9, reduced: false))"))
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
        let width = fittingWidth(rowCount: rowsThatDoNotFit)
        #expect(abs(width - expected) < 1,
                Comment(rawValue: "\(rowsThatDoNotFit) rows produced a \(width)pt panel, "
                        + "not \(expected)"))
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
        store.adoptForPreview(rows(rowsThatDoNotFit * 2))
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
        // The largest list one column holds, against twice that list. The
        // second is split, so it shows twice as many rows in about the same
        // height — which is the whole reason to split.
        let short = height(rowsThatFit)
        let long = height(rowsThatFit * 2)
        #expect(long <= short * 1.05,
                Comment(rawValue: "\(rowsThatFit * 2) rows in two columns came to \(long)pt "
                        + "against \(short)pt for \(rowsThatFit) in one — twice the rows "
                        + "should cost about the same height"))
    }
}
