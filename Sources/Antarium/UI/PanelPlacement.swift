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

    /// Low wins when the window is wider than the space, which is the case a
    /// plain `min(max(…))` gets backwards: on a screen narrower than the
    /// panel the high bound falls below the low one, and clamping to it would
    /// push the panel off the left edge rather than leaving it at the
    /// margin.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard value.isFinite else { return low }
        return high <= low ? low : min(max(value, low), high)
    }
}
