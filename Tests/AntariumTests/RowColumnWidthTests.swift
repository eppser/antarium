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
