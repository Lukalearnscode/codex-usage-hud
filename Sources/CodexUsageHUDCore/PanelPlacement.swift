import CoreGraphics

/// Geometry that decides where the HUD sits. Kept free of AppKit so the rules
/// can be tested against synthetic screen layouts: both of them are otherwise
/// silent on a single-display machine, where a wrong formula and a right one
/// look identical.
public enum PanelPlacement {
    /// Quartz global coordinates start at the top-left of the primary display
    /// and grow downward; AppKit starts at its bottom-left and grows upward.
    /// Only the primary screen's height relates the two, regardless of how many
    /// other displays are attached or where they sit.
    public static func appKitFrame(quartzFrame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: quartzFrame.minX,
            y: primaryScreenMaxY - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }

    /// A saved panel position counts as reachable only when enough of it lands
    /// on a screen to be seen, dragged, and right-clicked. The reset control
    /// lives in the panel's own context menu, so a panel that is fully
    /// off-screen cannot be recovered from the interface at all.
    public static func isReachable(
        _ rect: CGRect,
        visibleFrames: [CGRect],
        minimumVisibleExtent: CGFloat = 40
    ) -> Bool {
        visibleFrames.contains { frame in
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { return false }
            return overlap.width >= minimumVisibleExtent
                && overlap.height >= minimumVisibleExtent
        }
    }
}

/// Connection state of the app-server link, shared with the presentation layer
/// so the empty-state wording can be tested without building a panel.
public enum AppServerClientStatus: Sendable {
    case connecting
    case available
    case notAuthenticated
    case unavailable
}
