import CoreGraphics
import Foundation
import Testing
@testable import Antarium

/// Where the dashboard panel lands.
///
/// Untested until now because the decision needed an NSPanel, an NSScreen and
/// a status item button, so reaching it meant having a dashboard open on a
/// particular Mac with a particular display attached — which is the one
/// arrangement that cannot be varied in a test.
@Suite("The dashboard stays on the screen")
struct DashboardPlacementTests {

    /// A laptop display, and a taller external one.
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let external = CGRect(x: 0, y: 0, width: 2560, height: 1400)
    private let size = CGSize(width: 580, height: 620)

    private func place(saved: CGPoint? = nil, userMoved: Bool = false,
                       pinned: Bool = false, anchor: CGRect? = nil,
                       on screen: CGRect) -> CGPoint {
        DashboardPlacement.origin(saved: saved, userMoved: userMoved, pinned: pinned,
                                  anchor: anchor, visible: screen, size: size)
    }

    private func isOnScreen(_ origin: CGPoint, _ screen: CGRect) -> Bool {
        CGRect(origin: origin, size: size).intersection(screen).height > size.height / 2
    }

    /// The bug. A position saved on the tall display survived onto the short
    /// one unchanged and put the panel above everything visible — and because
    /// a position the user placed wins over every other rule, it stayed there
    /// on every launch after. Unplugging a monitor was enough to reach it.
    @Test("A position saved on a taller display is brought back onto a shorter one")
    func savedOnATallerDisplay() {
        let onExternal = place(userMoved: true, on: external)
        let moved = CGPoint(x: onExternal.x, y: 1_300)
        let backOnLaptop = place(saved: moved, userMoved: true, on: laptop)
        #expect(isOnScreen(backOnLaptop, laptop),
                "the panel sat at y \(backOnLaptop.y) on a screen \(laptop.height) tall")
        #expect(backOnLaptop.y <= laptop.maxY - size.height)
    }

    @Test("A position saved off the bottom is brought back up")
    func savedBelowTheScreen() {
        let origin = place(saved: CGPoint(x: 200, y: -900), userMoved: true, on: laptop)
        #expect(origin.y >= laptop.minY)
        #expect(isOnScreen(origin, laptop))
    }

    @Test("A position saved off either side is brought back in",
          arguments: [-5_000.0, 9_999.0])
    func savedOffTheSides(x: CGFloat) {
        let origin = place(saved: CGPoint(x: x, y: 300), userMoved: true, on: laptop)
        #expect(origin.x >= laptop.minX)
        #expect(origin.x + size.width <= laptop.maxX)
    }

    /// And a position that is already fine is left exactly where it was, or
    /// the clamp above would be a way of ignoring the user's placement.
    @Test("A position already on the screen is left alone")
    func savedPositionIsRespected() {
        let wanted = CGPoint(x: 120, y: 90)
        #expect(place(saved: wanted, userMoved: true, on: laptop) == wanted)
    }

    /// The saved position only wins once the user has actually moved it.
    @Test("A saved position is ignored until the user has moved the panel")
    func savedIsIgnoredWhenNotMoved() {
        let wanted = CGPoint(x: 120, y: 90)
        #expect(place(saved: wanted, userMoved: false, on: laptop) != wanted)
    }

    @Test("Pinned puts it against the right edge, hanging from the menu bar")
    func pinnedGoesRight() {
        let origin = place(pinned: true, on: laptop)
        #expect(origin.x + size.width == laptop.maxX - DashboardPlacement.margin)
        #expect(origin.y == laptop.maxY - size.height)
    }

    /// Right-aligned to the button, but never further *left* than the screen
    /// edge would put it — hanging a 580pt panel off a button in the middle
    /// of the bar otherwise threw it well to the left. So a button toward the
    /// middle does not drag the panel with it; that is the rule, not a gap in
    /// it, and only a button further right than the edge position moves it.
    @Test("It is right-aligned to its button, but never past the screen edge")
    func anchoredToTheButton() {
        let edge = laptop.maxX - size.width - DashboardPlacement.margin
        let middle = CGRect(x: 700, y: 850, width: 40, height: 22)
        #expect(place(anchor: middle, on: laptop).x == edge,
                "a button in the middle of the bar pulled the panel off the edge position")

        // Far enough right that aligning to the button is the rightmost of
        // the two, and the screen edge still wins over running off it.
        let farRight = CGRect(x: 1_425, y: 850, width: 40, height: 22)
        let origin = place(anchor: farRight, on: laptop)
        #expect(origin.x >= edge, "the panel went further left than the edge position")
        #expect(origin.x + size.width <= laptop.maxX, "the panel ran off the right edge")
    }

    /// A display narrower than the panel: the two bounds cross, and clamping
    /// to the high one would push it off the left edge instead of leaving it
    /// at the margin.
    @Test("A screen narrower than the panel leaves it at the left margin")
    func screenNarrowerThanThePanel() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 500)
        let origin = DashboardPlacement.origin(
            saved: CGPoint(x: 9_000, y: 9_000), userMoved: true, pinned: false,
            anchor: nil, visible: tiny, size: size)
        #expect(origin.x == tiny.minX + DashboardPlacement.margin)
    }

    /// A screen whose origin is not zero — a second display to the left of
    /// the first has negative coordinates, and "on screen" is not "positive".
    @Test("A display left of the main one is still the screen")
    func negativeScreenOrigin() {
        let left = CGRect(x: -2_560, y: 0, width: 2_560, height: 1_400)
        let origin = place(saved: CGPoint(x: -9_000, y: 200), userMoved: true, on: left)
        #expect(origin.x >= left.minX)
        #expect(origin.x + size.width <= left.maxX)
    }

    /// Nothing in a config file is trusted to be a number that can be drawn.
    @Test("A saved position that is not a position does not become a frame")
    func nonFiniteSavedOrigin() {
        let nan = CGFloat.nan, huge = CGFloat.infinity
        for bad in [CGPoint(x: nan, y: 100), CGPoint(x: 100, y: huge),
                    CGPoint(x: huge, y: nan)] {
            let origin = place(saved: bad, userMoved: true, on: laptop)
            #expect(origin.x.isFinite && origin.y.isFinite,
                    Comment(rawValue: "\(bad) produced \(origin)"))
        }
    }
}
