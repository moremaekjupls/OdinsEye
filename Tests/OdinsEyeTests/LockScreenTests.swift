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

    @Test func cardStaysAboveThePasswordZone() {
        for screen in [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 0, width: 1280, height: 600),
                       CGRect(x: -1920, y: 0, width: 1920, height: 1080)] {
            let frame = LockScreenPolicy.frame(on: screen)
            let floor = screen.minY + screen.height * LockScreenPolicy.reservedBottomFraction
            #expect(frame.minY >= floor - 0.5)
            #expect(frame.maxY <= screen.maxY - screen.height * 0.3)
            #expect(abs(frame.midX - screen.midX) < 0.5)
        }
    }
}
