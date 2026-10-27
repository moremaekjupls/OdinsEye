import AppKit
import Testing
@testable import OdinsEye

/// Наведение на «ухо»: Peeky здоровается сразу, панель раскрывается после
/// паузы, а чёлка по-прежнему открывает её без неё. Курсор синтетический,
/// пороги сжаты до десятков миллисекунд.
@MainActor
struct PointerWatcherEarTests {
    private let notch = CGRect(x: 600, y: 900, width: 180, height: 32)
    private let ear = CGRect(x: 552, y: 898, width: 276, height: 34)       // чёлка и оба «уха»
    private let leftEar = CGPoint(x: 575, y: 915)
    private let rightEar = CGPoint(x: 805, y: 915)
    private let elsewhere = CGPoint(x: 100, y: 300)

    private func watcher(panelOpen: Bool = false) -> (PointerWatcher, Log) {
        let log = Log()
        let w = PointerWatcher()
        w.openRect = notch
        w.closeRect = CGRect(x: 400, y: 700, width: 580, height: 240)
        w.earRect = ear
        w.earDwell = 0.05
        w.openDelay = 0.01
        w.closeDelay = 0.01
        w.isPanelOpen = { panelOpen }
        w.onEarHover = { log.hovers.append($0) }
        w.onChange = { log.changes.append($0) }
        return (w, log)
    }

    @MainActor final class Log {
        var hovers: [Bool] = []
        var changes: [Bool] = []
    }

    private func wait(_ ms: Int = 70) async { try? await Task.sleep(for: .milliseconds(ms)) }

    @Test func enteringAnEarGreetsOnceAtOnceAndNothingOpensYet() async {
        let (w, log) = watcher()
        defer { w.stop() }
        w.tick(at: leftEar)
        #expect(log.hovers == [true])
        w.tick(at: leftEar)
        w.tick(at: leftEar)
        #expect(log.hovers == [true], "greets once per visit")
        #expect(log.changes.isEmpty, "not before the dwell")
    }

    @Test func stayingLongEnoughOpensThePanel() async {
        let (w, log) = watcher()
        defer { w.stop() }
        w.tick(at: leftEar)
        await wait()
        w.tick(at: leftEar)        // пауза прошла: ждём порог открытия
        await wait(30)
        w.tick(at: leftEar)
        #expect(log.changes == [true])
        #expect(w.isInside)
    }

    @Test func theRightEarWorksToo() async {
        let (w, log) = watcher()
        defer { w.stop() }
        w.tick(at: rightEar)
        await wait()
        w.tick(at: rightEar); await wait(30); w.tick(at: rightEar)
        #expect(log.hovers.first == true)
        #expect(log.changes == [true])
    }

    @Test func leavingEarlyOpensNothingAndSaysGoodbye() async {
        let (w, log) = watcher()
        defer { w.stop() }
        w.tick(at: leftEar)
        w.tick(at: elsewhere)
        #expect(log.hovers == [true, false])
        await wait()
        w.tick(at: elsewhere)
        #expect(log.changes.isEmpty)
    }

    @Test func passingThroughAndComingBackGreetsAgain() async {
        let (w, log) = watcher()
        defer { w.stop() }
        w.tick(at: leftEar); w.tick(at: elsewhere); w.tick(at: leftEar)
        #expect(log.hovers == [true, false, true])
    }

    @Test func theNotchItselfStillOpensWithoutTheDwellOrAGreeting() async {
        let (w, log) = watcher()
        defer { w.stop() }
        let inNotch = CGPoint(x: 690, y: 915)
        w.tick(at: inNotch)
        await wait(30)
        w.tick(at: inNotch)
        #expect(log.changes == [true])
        #expect(log.hovers.isEmpty, "the notch is not an ear")
    }

    @Test func noGreetingWhileThePanelIsAlreadyOpen() async {
        let (w, log) = watcher(panelOpen: true)
        defer { w.stop() }
        w.tick(at: leftEar)
        await wait()
        w.tick(at: leftEar)
        #expect(log.hovers.isEmpty)
    }

    @Test func withoutAnAvatarTheEarsAreDeadZones() async {
        let (w, log) = watcher()
        defer { w.stop() }
        w.earRect = .zero
        w.tick(at: leftEar)
        await wait()
        w.tick(at: leftEar)
        #expect(log.hovers.isEmpty)
        #expect(log.changes.isEmpty)
    }
}
