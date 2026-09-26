import CoreGraphics

/// Where a panel sits, decided without a window in hand.
///
/// Separated from the panels because the rule it enforces last — that the
/// panel stays on the screen — was enforced in one direction only, and
/// nothing could say so: the decision needed an `NSPanel`, an `NSScreen` and
/// a status item button, so the only way to reach it was to have a panel open
/// on a particular Mac with a particular display attached.
///
/// There were three copies of this, and they agreed only by accident. The
/// dashboard's clamped its vertical position at the bottom alone. The
/// settings panel's had an anchor branch that could not do anything, since
/// `min(max(a, E), E)` is `E` whatever `a` is, and clamped neither axis at
/// all. The third, for a settings panel the user had dragged, clamped both
/// axes but inverted on a screen smaller than the panel. One rule now, and
/// the awkward cases are written down once.
enum PanelPlacement {

    static let margin: CGFloat = 8

    /// The panel's origin, in screen coordinates.
    ///
    /// `anchor` is the status item button's frame, already converted, or
    /// nothing when there is no button to hang from.
    static func origin(saved: CGPoint?, userMoved: Bool, pinned: Bool,
                       anchor: CGRect?, visible: CGRect, size: CGSize,
                       margin: CGFloat = margin) -> CGPoint {
        // Always hangs from the menu bar, never lower.
        let topY = visible.maxY - size.height
        var origin: CGPoint

        if userMoved, let saved {
            // Once you have placed it yourself, that wins — pinning included.
            origin = saved
        } else if pinned {
            origin = CGPoint(x: visible.maxX - size.width - margin, y: topY)
        } else if let anchor {
            // Right-aligned to the status item, but never further left than
            // the screen edge would put it — hanging a 580pt panel off a
            // button near the right of the bar otherwise threw it well to the
            // left.
            origin = CGPoint(x: max(anchor.maxX - size.width,
                                    visible.maxX - size.width - margin),
                             y: topY)
        } else {
            origin = CGPoint(x: visible.maxX - size.width - margin, y: topY)
        }

        // Never let it run off the screen edges — in either direction.
        //
        // The vertical clamp used to raise a low origin and nothing else, so
        // a position saved on a tall display survived onto a short one
        // unchanged and put the panel above everything visible. Unplugging an
        // external monitor was enough, and because `userMoved` keeps the saved
        // origin in front of every other rule, the dashboard stayed invisible
        // on every launch after. Editing config.json was the way back.
        origin.x = clamp(origin.x,
                         low: visible.minX + margin,
                         high: visible.maxX - size.width - margin)
        origin.y = clamp(origin.y, low: visible.minY + margin, high: topY)
        return origin
    }

    /// How many columns the agent list should use.
    ///
    /// One, for as long as one fits. The list splits only when a single
    /// column would not fit the screen it hangs on — at which point the
    /// choice is between two columns and a scrollbar, and two columns show
    /// more of the list at once.
    ///
    /// This was a row count: nine rows became two columns whether or not one
    /// column had room. On an ordinary display one column holds about thirty
    /// rows, so the panel was splitting long before it needed to and the
    /// common case — a handful of agents — was being shown in a layout meant
    /// for a long list.
    ///
    /// Decided from the row count and two constants, so it is still settled
    /// before any layout happens. Measuring the rendered height instead would
    /// close a loop: the height depends on the column count, and the column
    /// count would depend on the height.
    ///
    /// `previous` gives the switch hysteresis. Without it a list sitting on
    /// the boundary — which a list of live agents does — changes the panel's
    /// shape every time a session starts or ends.
    static func columns(rowCount: Int, previous: Int, contentHeight: CGFloat,
                        panel: CGFloat, visibleWidth: CGFloat, visibleHeight: CGFloat,
                        margin: CGFloat = margin) -> Int {
        let room = visibleHeight - verticalAllowance
        // One column, whenever one will do.
        if contentHeight <= room { return 1 }
        guard visibleWidth * maxScreenShare >= 2 * panel + 2 * margin else { return 1 }
        guard rowCount > 1 else { return 1 }
        return 2
    }

    /// How much of the screen's width a panel may occupy before a second
    /// column stops being an improvement.
    ///
    /// Fitting is not the same as belonging. Two 600pt columns and their
    /// margins are 1216pt, which does fit a 13" display's 1440 — at 84% of
    /// it, where a transient panel anchored to the menu bar stops reading as
    /// a panel and starts reading as a window missing its title bar. This
    /// keeps a tenth of the screen clear, which still admits the 13" and
    /// refuses the genuinely small displays below it.
    static let maxScreenShare: CGFloat = 0.9

    /// The menu bar, the panel's own margin and the space a panel is not
    /// allowed to fill. The same figure the list uses to cap its height, so
    /// "would not fit" here and "starts to scroll" there are one question.
    static let verticalAllowance: CGFloat = 130

    /// The rows of one column, filled column-major.
    ///
    /// Column-major because the list is sorted, and the sort is the point: a
    /// row-major fill would put the second-most-recent row beside the most
    /// recent rather than beneath it, and reading order would stop matching
    /// the order the user chose. It is also the order VoiceOver walks a grid,
    /// so the spoken list stays in the sorted order too.
    static func column(_ index: Int, of count: Int, rows: Int) -> Range<Int> {
        guard count > 1, rows > 0, index >= 0, index < count else {
            return index == 0 ? 0..<max(0, rows) : 0..<0
        }
        // The taller column comes first, so a list that does not divide evenly
        // leans left rather than leaving a gap in the middle of the first one.
        let base = rows / count, extra = rows % count
        let start = index * base + min(index, extra)
        let length = base + (index < extra ? 1 : 0)
        return start..<(start + length)
    }

    /// Low wins when the window is wider than the space, which is the case a
    /// plain `min(max(…))` gets backwards: on a screen narrower than the
    /// panel the high bound falls below the low one, and clamping to it would
    /// push the panel off the left edge rather than leaving it at the
    /// margin.
    ///
    /// Shared rather than private because the banner stack clamps the same
    /// way and had the same inversion. Its own rule differs — a banner
    /// follows its button leftward where a panel pins to the edge — so the
    /// two are not one placement, but they cross their bounds identically.
    static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard value.isFinite else { return low }
        return high <= low ? low : min(max(value, low), high)
    }
}
