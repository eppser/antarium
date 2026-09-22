import AppKit
import Foundation
import Testing
@testable import Antarium

/// The dashboard row's fixed columns, measured against what can actually
/// appear in them.
///
/// Three columns carry hardcoded widths so the figures line up down the list.
/// Nothing checked that the content fits, and nothing checked the reverse —
/// a width far wider than its content is dead space in every row, which is
/// most of why the panel is as narrow-and-deep as it is.
///
/// Measured through AppKit rather than asserted from memory, so the numbers
/// answer to the fonts the views actually use.
@Suite("A row's fixed columns fit what goes in them")
struct RowColumnWidthTests {

    private func width(_ text: String, size: CGFloat,
                       weight: NSFont.Weight, monospacedDigits: Bool = false) -> CGFloat {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var font = base
        if monospacedDigits {
            let descriptor = base.fontDescriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
            font = NSFont(descriptor: descriptor, size: size) ?? base
        }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Dot, its gap, the label, and the capsule's horizontal padding —
    /// Dashboard.swift's `pill(dim:)`.
    private func pillWidth(_ label: String) -> CGFloat {
        5 + 3 + width(label, size: 9, weight: .semibold) + 5 + 5
    }

    /// Every state the app can name itself. A cloud task's label is whatever
    /// the service calls its status and is not in this set — that one
    /// truncates, which is what the line limit is for.
    private var builtInLabels: [String] {
        [AgentRow.State.waiting, .working, .looping, .shell, .ended, .unobserved].map(\.label)
    }

    @Test("Every state this app names fits the pill")
    func builtInStatesFit() {
        #expect(builtInLabels.count == 6, "a state was added or removed without being measured")
        for label in builtInLabels {
            #expect(pillWidth(label) <= RowMetrics.pill,
                    Comment(rawValue: "\"\(label)\" needs \(pillWidth(label))pt "
                            + "in a \(RowMetrics.pill)pt pill"))
        }
    }

    /// The other side. Without this the pill could be 200pt and still "fit".
    @Test("The pill is not wider than the widest thing in it needs")
    func pillIsNotWasteful() {
        let widest = builtInLabels.map(pillWidth).max() ?? 0
        #expect(RowMetrics.pill - widest <= 10,
                Comment(rawValue: "the pill is \(RowMetrics.pill)pt for content "
                        + "needing \(widest)pt — \(RowMetrics.pill - widest)pt of every row is empty"))
    }

    /// Both formatters, across the bands they actually branch on, paired the
    /// way the view pairs them.
    @Test("Every cost the formatters can print fits its column")
    func realCostsFit() {
        let costs: [Double] = [0, 0.004, 0.01, 9.99, 10.0, 99.94, 100, 167, 9_999]
        let durations: [TimeInterval] = [30, 60, 3_500, 3_600, 86_399, 86_400, 86_400 * 120]
        var widest = 0.0, worst = ""
        for cost in costs {
            for over in durations {
                let money = Pricing.money(cost)
                let total = width(money, size: 10, weight: .medium, monospacedDigits: true)
                    + 3
                    + width("/ " + Fmt.duration(over), size: 9, weight: .regular,
                            monospacedDigits: true)
                if total > widest { widest = total; worst = "\(money) / \(Fmt.duration(over))" }
            }
        }
        #expect(widest <= RowMetrics.cost,
                Comment(rawValue: "\"\(worst)\" needs \(widest)pt in a \(RowMetrics.cost)pt column"))
        #expect(RowMetrics.cost - widest <= 16,
                Comment(rawValue: "the cost column is \(RowMetrics.cost)pt for content "
                        + "needing \(widest)pt"))
    }

    /// The meter slot, which three different things occupy: a context bar, an
    /// account bar with a percentage, an account bar showing a bare balance,
    /// or a blank reserve when the row has none of them.
    ///
    /// They measured 29.9pt to 64.3pt while the reserve was a flat 61pt. The
    /// row's trailing group is pushed right by whatever precedes it, so the
    /// cost column sat in a different place on every row depending on which
    /// meter that row had.
    @Test("Every meter a row can show fits the slot reserved for it")
    func meterVariantsFitTheSlot() {
        // Capsule plus the HStack's spacing, from both bar views.
        let bar: CGFloat = 34 + 3.5
        func percent(_ text: String) -> CGFloat {
            bar + width(text, size: 9, weight: .medium, monospacedDigits: true)
        }
        func balance(_ text: String) -> CGFloat {
            width(text, size: 9, weight: .medium, monospacedDigits: true)
        }
        // Every shape `Gauge.percentText` can return, and a balance in each
        // currency form `Gauge.amountText` can build.
        let metered = ["0%", "<1%", "42%", ">99%", "100%"].map(percent)
        let balances = ["$95.50", "$1204", "8.25 CNY", "1204.00 CNY", "¥88.00"].map(balance)
        let widest = (metered + balances).max() ?? 0

        #expect(widest <= RowMetrics.meter,
                Comment(rawValue: "a meter needs \(widest)pt in a \(RowMetrics.meter)pt slot"))
        // And not so generous that the common case is padding. The narrowest
        // is a bare balance, which is legitimately short — judge against the
        // widest, as with the other two columns.
        #expect(RowMetrics.meter - widest <= 12,
                Comment(rawValue: "the meter slot is \(RowMetrics.meter)pt for content "
                        + "needing \(widest)pt"))
    }

    /// The reserve and the bars have to agree, or the column it exists to
    /// align is only aligned for the rows that have no meter at all.
    @Test("The blank reserve is the same width as the meters it stands in for")
    func reserveMatchesTheMeters() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        #expect(source.contains("Color.clear.frame(width: RowMetrics.meter, height: 1)"),
                "the blank reserve carries its own number again")
        let pinned = source.components(separatedBy: "minWidth: RowMetrics.meter").count - 1
        #expect(pinned == 2,
                Comment(rawValue: "\(pinned) of the two meter views size themselves to the slot"))
    }

    /// The row has to fit the panel it is drawn in.
    ///
    /// Nothing said so. Three columns of fixed width, a glyph, five gaps and
    /// two sets of insets take their share first, and whatever is left is for
    /// the project name and its path. Widening any one of them narrows that
    /// remainder, and the only way to find out used to be to look at a Mac.
    @Test("What is left for the name and path is enough to show both")
    func theNameBudgetIsEnough() {
        let budget = RowMetrics.nameBudget()
        // Two thirds of the panel is furniture if this drops much below a
        // third of it — which is the shape the whole row is being revisited
        // for, so it is worth a number rather than an opinion.
        #expect(budget >= RowMetrics.panelFull / 3,
                Comment(rawValue: "only \(budget)pt of \(RowMetrics.panelFull) is left "
                        + "for the name and the path"))
        // And a name of ordinary length leaves room for a useful amount of
        // path beside it.
        let ordinary = width("claude-code-usage-bar", size: 11.5, weight: .semibold)
        #expect(budget - ordinary >= 120,
                Comment(rawValue: "an ordinary name leaves \(budget - ordinary)pt for the path"))
    }

    /// The name is a directory's last path component, which macOS allows up
    /// to 255 bytes. It cannot be given a fixed size, or it cannot truncate,
    /// and a long one then asks for a row wider than the panel.
    @Test("A long project name is wider than the row can give it")
    func longNamesExceedTheBudget() {
        let budget = RowMetrics.nameBudget()
        let long = String(repeating: "project-", count: 8)   // 64 characters
        let measured = width(long, size: 11.5, weight: .semibold)
        #expect(measured > budget,
                Comment(rawValue: "a 64-character name measures \(measured)pt against a "
                        + "\(budget)pt budget — if this ever fits, the case below is untested"))
    }

    /// So it must be allowed to give way. `layoutPriority` keeps it served
    /// before the path; a fixed size made it unshrinkable instead, and
    /// overrode the line limit and truncation written directly above it.
    @Test("The row name can truncate, and is still served before the path")
    func nameTruncatesButKeepsPriority() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "Text(row.coreName)"),
                                 "the row name is no longer drawn from coreName")
        let declaration = String(source[start.lowerBound...].prefix(400))
        #expect(!declaration.contains(".fixedSize("),
                "the name is pinned to its ideal width again, so it cannot truncate")
        #expect(declaration.contains(".truncationMode(.tail)"))
        #expect(declaration.contains(".lineLimit(1)"))
        #expect(declaration.contains(".layoutPriority(1)"),
                "without this the path competes with the name for the same space")
    }

    /// The row's *second* line, which nothing measured.
    ///
    /// `RowMetrics` and the tests above are about the three fixed columns on
    /// line one. Line two carries the capability strip, the sparkline, up to
    /// seven stats and the last-reply — every one of them `.fixedSize()`, so
    /// none can give way — and it is the wider of the two lines. It is what
    /// sets this panel's width, which is why the row could not be narrowed to
    /// 460 as the design review proposed.
    ///
    /// It also had no slack to spare, and one of its cells was unbounded.
    @Test("Every cell line two can carry fits the width it has")
    func secondLineFits() {
        func stat(_ text: String, cap: CGFloat? = nil) -> CGFloat {
            let natural = 9 + 2 + width(text, size: 9.5, weight: .regular, monospacedDigits: true)
            return cap.map { min(natural, $0) } ?? natural
        }
        // Constants read from the views: five capability dots at 17 with 2.5
        // between, and one sparkline bar per ten-minute bucket over six hours.
        let capabilities = 5 * 17 + 4 * 2.5
        let buckets = CGFloat(TranscriptStats.historyHours * 3600 / TranscriptStats.bucketSeconds)
        let sparkline = buckets * 1.6 + (buckets - 1) * 0.9
        let lastReply: CGFloat = 54

        // The widest each slot can be. The plan label stands in for the model
        // and is the one that is vendor text rather than a formatted figure.
        let cells = [stat("Sonnet 4.6"), stat("412MB"), stat("2.4M"), stat("890k"),
                     stat("1.2k"), stat("480"), stat("12")]
        let gaps = CGFloat(2 + cells.count + 1 - 1) * 7
        let used = capabilities + sparkline + cells.reduce(0, +) + lastReply + gaps + 6
        let available = RowMetrics.panelFull - 2 * RowMetrics.listInset - 2 * RowMetrics.rowInset
        #expect(used <= available,
                Comment(rawValue: "line two needs \(used)pt of \(available)"))

        // And the plan label, which a vendor names, cannot be wider than the
        // model name it replaces — or a long plan pushes the row past its
        // panel, which a 64-character one did by 242pt.
        let longestPlan = stat(String(repeating: "Enterprise ", count: 6),
                               cap: RowMetrics.planLabel)
        #expect(longestPlan <= stat("Sonnet 4.6") + 1,
                Comment(rawValue: "a plan label can be \(longestPlan)pt where a model is "
                        + "\(stat("Sonnet 4.6"))pt"))
    }

    /// And the ceiling is actually applied. The arithmetic above uses the
    /// constant, so it holds whether or not the row passes it — which is the
    /// shape AGENTS.md records as checking the author's own allowlist rather
    /// than the code, and it survived a mutation that dropped the argument.
    @Test("The plan label's ceiling reaches the row that draws it")
    func planLabelCeilingIsApplied() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        let call = try #require(source.range(of: "Stat(\"creditcard\""),
                                "the plan is no longer drawn as a stat")
        let declaration = String(source[call.lowerBound...].prefix(220))
        #expect(declaration.contains("maxWidth: RowMetrics.planLabel"),
                Comment(rawValue: "the plan stat is drawn without its ceiling: \(declaration)"))
        // Nothing else on that line is vendor text, so nothing else needs one.
        let capped = source.components(separatedBy: "maxWidth: RowMetrics.planLabel").count - 1
        #expect(capped == 1, Comment(rawValue: "\(capped) stats carry the plan ceiling"))
    }

    /// Every cell on that line is held to one line, for the reason the pill
    /// was: `fixedSize` prevents a shrink, not a wrap, so a cell given less
    /// width than it wants still wraps and takes its row's height with it.
    @Test("The second line's cells cannot wrap")
    func secondLineCellsAreSingleLine() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private struct Stat: View"))
        let rest = source[start.upperBound...]
        let body = rest.range(of: "\nprivate struct ").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        #expect(body.contains(".lineLimit(1)"),
                "a stat can wrap, and a taller cell makes a taller row")
    }

    /// Both are single-line by declaration. A wrapped cell makes its row
    /// taller than its neighbours, which is the defect `LastReply` already
    /// names — and the pill, whose content comes from a cloud service, had
    /// no such limit at all.
    @Test("Every fixed-width cell in a row is held to one line")
    func fixedWidthCellsAreSingleLine() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        var checked = 0
        for cell in ["StatePill", "CostLabel", "LastReply"] {
            guard let start = source.range(of: "private struct \(cell): View") else {
                Issue.record(Comment(rawValue: "\(cell) is no longer a view in Dashboard.swift"))
                continue
            }
            // To the end of that declaration, not the end of the file.
            let rest = source[start.upperBound...]
            let body = rest.range(of: "\nprivate struct ").map { String(rest[..<$0.lowerBound]) }
                ?? String(rest)
            checked += 1
            #expect(body.contains(".lineLimit(1)"),
                    Comment(rawValue: "\(cell) has a fixed width and no line limit, so its "
                            + "content can wrap and make its row taller than the rest"))
        }
        #expect(checked == 3, "a fixed-width cell was not examined")
    }
}

/// The context bar's figure, which is a percentage computed from two numbers
/// a harness reports.
///
/// `contextFraction` capped above at 1 from the day it was written and never
/// below at 0. The dashboard renders it as `Int(fraction * 100)`, and that
/// traps rather than rounds: a harness reporting a negative context against a
/// small window took the menu bar down with SIGTRAP.
@Suite("The context figure is a measurement or it is nothing")
struct ContextFractionTests {

    private func row(tokens: Int?, window: Int?) -> AgentRow {
        var row = AgentRow(id: "synthetic", agentID: "claude-code", name: "p",
                           cwd: "/synthetic/p", state: .working)
        row.contextTokens = tokens
        row.contextWindow = window
        return row
    }

    @Test("A negative count is no measurement, not an empty one",
          arguments: [-1, -1_000, Int.min])
    func negativeCountsAreRefused(tokens: Int) {
        #expect(row(tokens: tokens, window: 200_000).contextFraction == nil,
                Comment(rawValue: "\(tokens) tokens produced a fraction"))
    }

    /// The case that actually crashed: the percentage is taken of the
    /// fraction, so a huge negative over a tiny window overflows `Int`.
    @Test("The figure that trapped now yields nothing")
    func theTrappingCaseIsGone() {
        let fraction = row(tokens: Int.min, window: 1).contextFraction
        #expect(fraction == nil)
        // And anything a fraction can be survives the conversion the bar does.
        for value in [row(tokens: 0, window: 1), row(tokens: Int.max, window: 1),
                      row(tokens: 199_000, window: 200_000)] {
            guard let f = value.contextFraction else { continue }
            #expect((0...1).contains(f), Comment(rawValue: "\(f) is not a fraction"))
            #expect(Int(f * 100) >= 0 && Int(f * 100) <= 100)
        }
    }

    /// Zero is a real measurement and must still draw. Refusing negatives by
    /// refusing everything at or below zero would hide a fresh session.
    @Test("An empty context is still a measurement")
    func zeroIsAMeasurement() {
        #expect(row(tokens: 0, window: 200_000).contextFraction == 0)
    }

    @Test("An ordinary reading is unchanged")
    func ordinaryReading() throws {
        let f = try #require(row(tokens: 50_000, window: 200_000).contextFraction)
        #expect(abs(f - 0.25) < 1e-9)
    }

    /// The other half of the guard, which was already there.
    @Test("A window of zero or less says nothing", arguments: [0, -1])
    func windowMustBePositive(window: Int) {
        #expect(row(tokens: 10, window: window).contextFraction == nil)
    }

    @Test("A missing half says nothing")
    func missingHalves() {
        #expect(row(tokens: nil, window: 200_000).contextFraction == nil)
        #expect(row(tokens: 10, window: nil).contextFraction == nil)
    }
}
