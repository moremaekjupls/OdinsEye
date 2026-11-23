import CoreGraphics
import Foundation
import Testing
@testable import OdinsEye

@Suite struct LockScreenTests {
    @Test func markLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lockmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mark = LockScreenGuard(url: dir.appendingPathComponent("lockscreen.armed"))
        #expect(!mark.isArmed)
        mark.arm()
        #expect(mark.isArmed)
        mark.disarm()
        #expect(!mark.isArmed)
        mark.disarm() // повторно: без ошибки
    }

    @Test func showsOnlyWhenEverythingIsTrue() {
        #expect(LockScreenPolicy.shows(enabled: true, available: true, locked: true, hasTrack: true))
        #expect(!LockScreenPolicy.shows(enabled: false, available: true, locked: true, hasTrack: true))
        #expect(!LockScreenPolicy.shows(enabled: true, available: false, locked: true, hasTrack: true))
        #expect(!LockScreenPolicy.shows(enabled: true, available: true, locked: false, hasTrack: true))
        #expect(!LockScreenPolicy.shows(enabled: true, available: true, locked: true, hasTrack: false))
    }

    @Test func layoutStaysAboveThePasswordZone() {
        for screen in [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 0, width: 1280, height: 600),
                       CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: 0, y: 0, width: 360, height: 700), CGRect(x: 0, y: 0, width: 800, height: 300)] {
            let layout = LockScreenPolicy.layout(on: screen)
            let floor = screen.minY + screen.height * LockScreenPolicy.reservedBottomFraction
            #expect(layout.frame.minY >= floor - 0.5)
            #expect(layout.frame.maxY <= screen.maxY - screen.height * 0.31)
            #expect(abs(layout.frame.midX - screen.midX) < 0.5)
            #expect(layout.frame.width <= screen.width * 0.9 + 0.5)
            #expect(layout.coverSide <= layout.frame.width + 0.5)
        }
    }

    /// На обычном экране видны и обложка, и плеер, и вместе они дают окно.
    @Test func regularScreenShowsCoverAndPlayer() {
        let layout = LockScreenPolicy.layout(on: CGRect(x: 0, y: 0, width: 1470, height: 956))
        #expect(layout.coverSide >= 200)
        #expect(layout.playerHeight == LockScreenPolicy.playerHeight)
        #expect(abs(layout.frame.height - (layout.coverSide + LockScreenPolicy.gap + layout.playerHeight)) < 0.5)
    }

    /// Свёрнутое окно это верх раскладки: плеер в том же месте, где потом выдвигается обложка.
    @Test func collapsedFrameIsThePlayerAtTheTop() {
        let layout = LockScreenPolicy.layout(on: CGRect(x: 0, y: 0, width: 1470, height: 956))
        #expect(layout.collapsedFrame.height == layout.playerHeight)
        #expect(abs(layout.collapsedFrame.maxY - layout.frame.maxY) < 0.5)
    }

    /// На низком экране обложка уходит, плеер остаётся.
    @Test func lowScreenKeepsOnlyThePlayer() {
        let layout = LockScreenPolicy.layout(on: CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(layout.coverSide == 0)
        #expect(layout.frame.height == layout.playerHeight)
    }
}
