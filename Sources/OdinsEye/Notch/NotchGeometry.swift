import AppKit

/// Physical description of the notch plus every derived rect the panel needs,
/// all in screen coordinates.
///
/// Only a real cutout: this build stands on the one display that has a notch
/// and on no other, and draws no notch of its own on screens without one.
struct NotchGeometry {
    let screen: NSScreen
    /// Size of the physical notch in points.
    let notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    let notchCenterX: CGFloat

    /// Metrics of the tab rail that do not depend on the notch. `railIconHeight`
    /// is not among them — see below.
    static let railSpacing: CGFloat = 4
    /// Gap between the rail and the bottom edge of the body.
    static let bodyBottomPadding: CGFloat = 14

    /// Size of the fully expanded panel body. Held constant across every Mac:
    /// letting it follow the header made two people on the very same model
    /// see two different heights, just from different display-scaling
    /// settings — 38 pt against 32 for the same physical notch, an 11 pt
    /// spread from one slider. What differs between Macs lives in
    /// `railIconHeight` instead, which is the one thing in the body actually
    /// free to give.
    let expandedSize = CGSize(width: 620, height: 208)

    /// What the body has left for content once the header and the padding
    /// beneath are taken out.
    var standardContentHeight: CGFloat {
        expandedSize.height - notchSize.height - Self.bodyBottomPadding
    }

    /// Height each rail icon gets. A ceiling, not a constant: six icons at
    /// the full 24 pt plus the five 4 pt gaps between them is 164 pt, and
    /// the body only has `standardContentHeight` left to give the rail once
    /// the header — the notch itself — and the padding beneath are taken out
    /// of the fixed 208. Rounded down rather than to the nearest point: a
    /// rail that asks for more than it is given should visibly yield, not
    /// overflow by a fraction that clips it.
    var railIconHeight: CGFloat {
        let icons = CGFloat(NotchViewModel.Tab.rail.count)
        let ceiling = (standardContentHeight - (icons - 1) * Self.railSpacing) / icons
        return min(24, ceiling).rounded(.down)
    }

    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// Stable name for the display this geometry was cut from. AppKit hands
    /// out a fresh `NSScreen` for the same monitor on every reconfiguration,
    /// so this is the one thing worth keying a panel on — an index into
    /// `NSScreen.screens` is not, because that array reorders too.
    var displayID: CGDirectDisplayID? { screen.displayID }

    /// The display the panel stands on: the one with a notch cut into it, and
    /// nothing when there is none.
    ///
    /// Nothing is a real answer, not a failure. With the lid closed and an
    /// external monitor attached, the built-in display leaves
    /// `NSScreen.screens` altogether; the panel then has nowhere to stand and
    /// is not built, rather than moving to the external screen. It comes back
    /// on the next screen-parameter change that brings the notch back —
    /// opening the lid.
    @MainActor
    static func notched() -> NotchGeometry? {
        // A mirrored display repeats another one's picture; the notch that
        // matters is the source, never the copy.
        for screen in NSScreen.screens where !screen.isMirroring {
            if let geometry = current(on: screen) { return geometry }
        }
        return nil
    }

    /// The geometry of this screen's notch, or nil if it has none.
    static func current(on screen: NSScreen) -> NotchGeometry? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        return NotchGeometry(
            screen: screen,
            notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
            notchCenterX: screen.frame.minX + left.width + width / 2
        )
    }

    /// True when nothing that affects the panel has moved. Screen-parameter
    /// notifications fire for plenty of reasons that leave the notch exactly
    /// where it was, and rebuilding on those would throw away the open state
    /// and the selected tab.
    func matches(_ other: NotchGeometry) -> Bool {
        screen.frame == other.screen.frame
            && notchSize == other.notchSize
            && notchCenterX == other.notchCenterX
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        CGSize(
            width: expandedSize.width + windowPadding.left + windowPadding.right,
            height: expandedSize.height + windowPadding.bottom
        )
    }

    /// Panel frame in global screen coordinates, flush with the top of the display.
    var windowFrame: CGRect {
        CGRect(
            x: notchCenterX - windowSize.width / 2,
            y: screen.frame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `screen.frame.maxY` whenever it is thrown at the top of the
    /// display — which is precisely how one reaches the notch. Every rect that
    /// touches the top edge is grown past it so that position counts as inside.
    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= screen.frame.maxY else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Rect the content occupies inside the window, in screen coordinates.
    func contentScreenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    /// Rect the content occupies inside the window, in AppKit window coordinates.
    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Size of the collapsed notch: the hole itself. Nothing is drawn over it,
    /// and the whole of it can be claimed, because there is nothing
    /// underneath to claim it from.
    var collapsedSize: CGSize { notchSize }

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// taller than the notch so the panel opens just before the pointer lands.
    var hoverRect: CGRect {
        // The slack is what makes the panel open just before the pointer lands.
        let slack: CGFloat = 4
        return includingTopEdge(CGRect(
            x: notchCenterX - notchSize.width / 2 - 6,
            y: screen.frame.maxY - notchSize.height - slack,
            width: notchSize.width + 12,
            height: notchSize.height + slack
        ))
    }

    /// Band along the top of the display in which pointer sampling runs at
    /// full rate. Deep enough that a pointer heading for the notch is always
    /// noticed before it arrives.
    var warmZone: CGRect {
        includingTopEdge(CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - 260,
            width: screen.frame.width,
            height: 260
        ))
    }

    /// Area that keeps the panel open while expanded, in global screen coordinates.
    var expandedHoverRect: CGRect { hoverRect(for: expandedSize) }

    /// Area that keeps a body of this size open, in global screen coordinates.
    func hoverRect(for body: CGSize) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - body.width / 2 - 12,
            y: screen.frame.maxY - body.height - 12,
            width: body.width + 24,
            height: body.height + 12
        ))
    }
}

extension NSScreen {
    /// The display behind this screen, named the way the window server names
    /// it — the same number across every reconfiguration.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// True when this screen only repeats what another display already shows.
    var isMirroring: Bool {
        guard let displayID else { return false }
        return CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
    }
}
