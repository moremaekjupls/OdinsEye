import AppKit
import ObjectiveC

/// Scroll events as the notch panel actually receives them, reduced to the
/// fields the repair decision needs. A real `NSEvent` cannot be built in a
/// test, so the decision stays on this value.
struct PanelScrollSample: Equatable {
    var hasPreciseScrollingDeltas = false
    var scrollingDeltaX: CGFloat = 0
    var scrollingDeltaY: CGFloat = 0
    /// `NSEvent.Phase.rawValue`. Zero is "no phase".
    var phaseRaw: UInt = 0
    var momentumPhaseRaw: UInt = 0
    /// `kCGScrollWheelEventIsContinuous`. Trackpads set it; a notched wheel does not.
    var continuous = false
    /// Pixel deltas from the CGEvent (`pointDeltaAxis2` / `pointDeltaAxis1`).
    var pointX: CGFloat = 0
    var pointY: CGFloat = 0
    var cgPhase: Int64 = 0
    var cgMomentum: Int64 = 0
}

/// Pixel deltas to write back onto a scroll event so AppKit treats it as a
/// precise, continuous gesture. `nil` means the event is already what a
/// normal window would have been given, and must be left alone.
struct PanelScrollPixels: Equatable {
    var x: CGFloat
    var y: CGFloat
}

/// Restores trackpad scrolling on a non-activating panel.
///
/// An `.accessory` panel that is not key — the clipboard tab never takes the
/// keyboard, unlike snippets — is not the active app. WindowServer then
/// delivers the trackpad as a line-sized wheel: `hasPreciseScrollingDeltas`
/// is false and `scrollingDeltaY` counts lines, while the pixel delta and
/// the gesture phase are still on the CGEvent. SwiftUI's scroll view follows
/// that literally, so the clipboard (and any other non-key pane) jumps by
/// lines, ignores momentum, and can disagree with the natural-scrolling
/// direction the rest of the system is using.
///
/// A notched mouse wheel is the same shape on purpose: integer line deltas,
/// no phase. That one is left for `NSScrollView`, which already turns one
/// line into `pointsPerLine` pixels and honours the user's scroll direction.
enum PanelScroll {
    /// `NSScrollView.verticalLineScroll` / `horizontalLineScroll` default.
    /// One reported line is this many points on a normal window.
    static let pointsPerLine: CGFloat = 10

    static func repair(_ sample: PanelScrollSample) -> PanelScrollPixels? {
        guard !sample.hasPreciseScrollingDeltas else { return nil }
        guard isStrippedTrackpad(sample) else { return nil }
        return PanelScrollPixels(
            x: pixels(point: sample.pointX, scrolling: sample.scrollingDeltaX),
            y: pixels(point: sample.pointY, scrolling: sample.scrollingDeltaY)
        )
    }

    /// The event the scroll view should see. The original comes back when
    /// there is nothing to repair or the rebuilt event cannot be hit-tested
    /// in this window — a scroll that lands in the wrong view is worse than
    /// a coarse one.
    static func event(byRepairing event: NSEvent, in window: NSWindow) -> NSEvent {
        guard event.type == .scrollWheel else { return event }
        guard let pixels = repair(sample(from: event)) else { return event }
        guard let cg = event.cgEvent?.copy() else { return event }

        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(pixels.y))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(pixels.x))
        // A real trackpad stores lines in the fixed-point and integer fields
        // and pixels in the point fields. Readers that ignore the continuous
        // flag still move one line per `pointsPerLine` pixels, same direction.
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(pixels.y / pointsPerLine))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(pixels.x / pointsPerLine))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineCount(pixels.y))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineCount(pixels.x))

        // Phases are what the scroll view uses for the flick after the
        // fingers lift. They are usually still on the CGEvent; if only the
        // Cocoa event kept them, write them back onto the copy.
        if cg.getIntegerValueField(.scrollWheelEventScrollPhase) == 0, event.phase.rawValue != 0 {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(event.phase.rawValue))
        }
        if cg.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0, event.momentumPhase.rawValue != 0 {
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(event.momentumPhase.rawValue))
        }

        guard let rebuilt = NSEvent(cgEvent: cg) else { return event }
        guard bind(rebuilt, to: window) else { return event }
        let moved = abs(rebuilt.locationInWindow.x - event.locationInWindow.x) > 1
            || abs(rebuilt.locationInWindow.y - event.locationInWindow.y) > 1
        guard !moved else { return event }
        return rebuilt
    }

    // MARK: - Decision

    /// A trackpad (or Magic Mouse) gesture that arrived without its precise
    /// flag. A notched wheel has none of these: it is not continuous, it has
    /// no phase, and both of its deltas are whole lines.
    private static func isStrippedTrackpad(_ sample: PanelScrollSample) -> Bool {
        if sample.continuous || sample.phaseRaw != 0 || sample.momentumPhaseRaw != 0 {
            return true
        }
        if sample.cgPhase != 0 || sample.cgMomentum != 0 { return true }
        if !isWhole(sample.pointX) || !isWhole(sample.pointY) { return true }
        if !isWhole(sample.scrollingDeltaX) || !isWhole(sample.scrollingDeltaY) { return true }
        // Pixel delta survived, line delta did not: 16 pixels against 1 line.
        // A notched wheel reports the same count in both fields.
        if pointDeltaDisagreesWithLines(sample) { return true }
        return false
    }

    private static func pointDeltaDisagreesWithLines(_ sample: PanelScrollSample) -> Bool {
        guard sample.pointX != 0 || sample.pointY != 0 else { return false }
        return abs(sample.pointX - sample.scrollingDeltaX) > 0.5
            || abs(sample.pointY - sample.scrollingDeltaY) > 0.5
    }

    /// `scrollingDelta` is already in the user's direction — natural scrolling
    /// included — which is the sign `NSScrollView` would have applied. The
    /// point delta is the pixel distance; when the two disagree, the point
    /// delta is still in device space and has to be flipped to match.
    private static func pixels(point: CGFloat, scrolling: CGFloat) -> CGFloat {
        guard point != 0 else { return scrolling * pointsPerLine }
        guard scrolling != 0, (point > 0) != (scrolling > 0) else { return point }
        return -point
    }

    private static func isWhole(_ value: CGFloat) -> Bool {
        abs(value - value.rounded()) < 0.001
    }

    /// Whole lines for the legacy delta fields. A sub-line pixel move still
    /// reports its sign, so a reader of the line delta does not see "no
    /// scroll" for a gesture that did move.
    private static func lineCount(_ pixels: CGFloat) -> Int64 {
        if pixels == 0 { return 0 }
        let lines = (pixels / pointsPerLine).rounded()
        if lines == 0 { return pixels > 0 ? 1 : -1 }
        return Int64(lines)
    }

    // MARK: - NSEvent

    private static func sample(from event: NSEvent) -> PanelScrollSample {
        let cg = event.cgEvent
        return PanelScrollSample(
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            phaseRaw: event.phase.rawValue,
            momentumPhaseRaw: event.momentumPhase.rawValue,
            continuous: cg.map { $0.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 } ?? false,
            pointX: cg.map { CGFloat($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) } ?? 0,
            pointY: cg.map { CGFloat($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) } ?? 0,
            cgPhase: cg?.getIntegerValueField(.scrollWheelEventScrollPhase) ?? 0,
            cgMomentum: cg?.getIntegerValueField(.scrollWheelEventMomentumPhase) ?? 0
        )
    }

    /// `NSEvent.window` is read-only, and an event built from a CGEvent copy
    /// has none — `sendEvent` would then hit-test it nowhere. The ivar is
    /// what AppKit set on the original event. If it is not there, the repair
    /// is skipped and the coarse event is delivered as it arrived.
    private static func bind(_ event: NSEvent, to window: NSWindow) -> Bool {
        if event.window === window { return true }
        guard event.window == nil, let ivar = class_getInstanceVariable(NSEvent.self, "_window") else {
            return false
        }
        object_setIvarWithStrongDefault(event, ivar, window)
        return event.window === window
    }
}
