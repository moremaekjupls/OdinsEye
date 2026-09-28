import Testing
@testable import OdinsEye

/// Решение, которое отличает тачпад, пришедший в неактивную панель как
/// «колёсико по строкам», от настоящего колёсика. Само событие AppKit здесь
/// не собирается — на Linux его не из чего собрать, а на Mac его проверяет
/// глаз; числа ниже это то, что `NotchPanel.sendEvent` потом записывает.
struct PanelScrollTests {
    @Test func preciseTrackpadIsLeftAlone() {
        var sample = PanelScrollSample()
        sample.hasPreciseScrollingDeltas = true
        sample.continuous = true
        sample.scrollingDeltaY = 6.5
        sample.pointY = 6.5
        sample.phaseRaw = 4
        #expect(PanelScroll.repair(sample) == nil)
    }

    @Test func notchedWheelIsLeftToAppKit() {
        var sample = PanelScrollSample()
        sample.scrollingDeltaY = -3
        sample.pointY = -3
        #expect(PanelScroll.repair(sample) == nil)
    }

    @Test func acceleratedNotchStaysAWheel() {
        // Acceleration makes the line count larger. It is still a whole
        // number of lines and still has no gesture phase.
        var sample = PanelScrollSample()
        sample.scrollingDeltaY = 5
        sample.pointY = 5
        #expect(PanelScroll.repair(sample) == nil)
    }

    @Test func continuousEventUsesThePixelDelta() {
        var sample = PanelScrollSample()
        sample.continuous = true
        sample.scrollingDeltaY = 1
        sample.pointY = 14.25
        sample.pointX = -2.5
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: -2.5, y: 14.25))
    }

    @Test func phaseAlonePromotesALineSizedTrackpad() {
        var sample = PanelScrollSample()
        sample.phaseRaw = 4
        sample.scrollingDeltaY = 1
        sample.pointY = 9
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: 9))
    }

    @Test func momentumPhaseIsAGesture() {
        var sample = PanelScrollSample()
        sample.momentumPhaseRaw = 4
        sample.pointY = 3.5
        sample.scrollingDeltaY = 1
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: 3.5))
    }

    @Test func cgPhaseCountsWhenCocoaPhaseWasStripped() {
        var sample = PanelScrollSample()
        sample.cgMomentum = 2
        sample.pointY = -4
        sample.scrollingDeltaY = -1
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: -4))
    }

    @Test func fractionalLineScalesByTheScrollViewLine() {
        // No pixel delta left on the event: the line delta is fractional,
        // which a notch never is. One line is `pointsPerLine` points.
        var sample = PanelScrollSample()
        sample.scrollingDeltaY = -0.4
        sample.scrollingDeltaX = 0.2
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 2, y: -4))
    }

    @Test func pixelDeltaThatDisagreesWithTheLineIsNotAWheel() {
        var sample = PanelScrollSample()
        sample.pointY = 16
        sample.scrollingDeltaY = 1
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: 16))
    }

    @Test func fractionalPointDeltaIsNotAWheel() {
        var sample = PanelScrollSample()
        sample.pointY = 7.5
        sample.scrollingDeltaY = 1
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: 7.5))
    }

    @Test func deviceSpacePointDeltaFollowsNaturalDirection() {
        // `scrollingDelta` is already the user's direction. A point delta
        // with the opposite sign is still device-space and must be flipped,
        // or natural scrolling moves the list backwards.
        var sample = PanelScrollSample()
        sample.continuous = true
        sample.pointY = 11
        sample.scrollingDeltaY = -1
        sample.pointX = -4
        sample.scrollingDeltaX = 1
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 4, y: -11))
    }

    @Test func zeroScrollingDoesNotFlipAPointDelta() {
        var sample = PanelScrollSample()
        sample.momentumPhaseRaw = 4
        sample.pointY = 2
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: 2))
    }

    @Test func endedPhaseWithNoDeltaStillRepairs() {
        // The flick's last event carries the phase and a zero delta. It has
        // to stay a precise gesture or the scroll view never hears that the
        // momentum ended.
        var sample = PanelScrollSample()
        sample.phaseRaw = 8
        #expect(PanelScroll.repair(sample) == PanelScrollPixels(x: 0, y: 0))
    }
}
