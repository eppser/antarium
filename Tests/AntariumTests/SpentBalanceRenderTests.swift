import AppKit
import Foundation
import Testing
@testable import Antarium

/// A balance that cannot be spent, in the place a user actually looks.
///
/// Severity colours the bar, and a balance has no bar — it draws its figure
/// and nothing else, because a meter pinned full reads the same whether five
/// hundred dollars or two cents remain. So a gauge the provider reports as
/// spent, or one whose amount has reached nought, was drawn exactly like a
/// full account: same figure, same colour, no bar either way.
///
/// The model learned to say "spent" and nothing rendered it, which is a fix
/// that exists only in a type.
@Suite("A spent balance is drawn differently from a funded one", .serialized)
@MainActor
struct SpentBalanceRenderTests {

    private func render(severity: Severity) -> StatusRender {
        StatusRender(agentID: "synthetic",
                     rows: [StatusRender.Row(fill: nil, percentText: "$500",
                                             resetText: "", severity: severity)])
    }

    private func pixels(_ render: StatusRender) throws -> Data {
        let image = Renderer.image(render, appearance: NSAppearance(named: .darkAqua)!, scale: 2)
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The same figure, the same width, one of them spent. Compared as drawn
    /// rather than as a colour value: the assertion is that a reader can tell
    /// them apart, which is the whole point.
    @Test("The same amount looks different when the provider reports it spent")
    func spentBalanceDiffers() throws {
        let funded = try pixels(render(severity: .normal))
        let spent = try pixels(render(severity: .critical))
        #expect(funded != spent,
                "a balance reported spent renders identically to a funded one")
    }

    /// And the difference is not that one of them failed to draw.
    @Test("Both renders are real images of the same size")
    func bothRenderProperly() throws {
        let funded = try pixels(render(severity: .normal))
        let spent = try pixels(render(severity: .critical))
        #expect(funded.count > 100 && spent.count > 100,
                Comment(rawValue: "images are \(funded.count) and \(spent.count) bytes"))
        #expect(Renderer.width(for: render(severity: .normal))
                    == Renderer.width(for: render(severity: .critical)),
                "the colour changed the width, so something other than colour changed")
    }

    /// The decision itself, which is where it can actually be checked.
    ///
    /// Sampling the drawn pixels does not work: the figure sits in a field
    /// whose width is private and whose text is right-aligned, and a strip
    /// taken from the left edge reported no difference where there plainly
    /// was one — the same recolouring that the image comparison above does
    /// catch. A strip that cannot see the glyphs is a test that passes for
    /// the wrong reason.
    @Test("Only a row without a bar takes the warning colour")
    func onlyBarlessRowsAreRecoloured() {
        func colour(fill: Double?, _ severity: Severity) -> NSColor {
            Renderer.figureColor(for: StatusRender.Row(fill: fill, percentText: "50%",
                                                      resetText: "", severity: severity),
                                 agentID: "synthetic", row: 0)
        }
        let warning = Renderer.color(for: .critical, agentID: "synthetic", row: 0)
        // A balance the provider reports spent.
        #expect(colour(fill: nil, .critical) == warning)
        // A balance with money in it.
        #expect(colour(fill: nil, .normal) == .labelColor)
        #expect(colour(fill: nil, .low) == .labelColor)
        // A metered row, which already has a bar to carry the warning.
        #expect(colour(fill: 0.5, .critical) == .labelColor,
                "a metered row's figure took the warning colour, so the bar says it twice")
        #expect(colour(fill: 1.0, .critical) == .labelColor)
        #expect(colour(fill: 0.0, .normal) == .labelColor)
        // And the warning colour is not the label colour, or none of the above
        // distinguishes anything.
        #expect(warning != NSColor.labelColor)
    }

    /// The rule is about a row with no bar, not about a balance in particular:
    /// anything that draws a figure alone and is reported spent should say so.
    @Test("It is the absent bar that decides, not the currency")
    func anyBarlessRowQualifies() throws {
        let plain = StatusRender(agentID: "synthetic",
                                 rows: [StatusRender.Row(fill: nil, percentText: "1.2M",
                                                         resetText: "", severity: .normal)])
        let spent = StatusRender(agentID: "synthetic",
                                 rows: [StatusRender.Row(fill: nil, percentText: "1.2M",
                                                         resetText: "", severity: .critical)])
        #expect(try pixels(plain) != (try pixels(spent)))
    }
}
