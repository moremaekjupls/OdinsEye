import AVFoundation
import Foundation
import Testing
@testable import OdinsEye

/// Приветствие взмахом и тихие звуки.
@MainActor
struct PeekyGreetingAndSoundsTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)

    private static let poses: [PeekyMood: PeekyPose] =
        PeekyAssets.load(from: resources.appendingPathComponent("peeky", isDirectory: true)) ?? [:]

    private func engine(_ mood: PeekyMood) -> (PeekyEngine, Double) {
        let engine = PeekyEngine(poses: Self.poses)
        let t = 100.0
        engine.update(now: t)
        engine.setMood(mood, now: t)
        return (engine, t + 0.001)
    }

    private func run(_ engine: PeekyEngine, from start: Double, seconds: Double, _ probe: (PeekyEngine, Double) -> Void) {
        var t = start
        while t < start + seconds { engine.update(now: t); probe(engine, t - start); t += 1.0 / 30 }
    }

    private func sounds(enabled: Bool = true) -> PeekySounds {
        let sounds = PeekySounds()
        sounds.folder = Self.resources.appendingPathComponent("sounds", isDirectory: true)
        sounds.isEnabled = { enabled }
        sounds.volume = 0
        return sounds
    }

    // MARK: - Взмах

    @Test func theGreetingFollowsItsTimeline() {
        let (engine, t) = engine(.awake)
        #expect(engine.greet(now: t))
        var poseAtStart: PeekyMood?, poseMidWave: PeekyMood?, poseAfter: PeekyMood?
        var eyesDuring: PeekyEngine.EyeStyle?
        run(engine, from: t, seconds: 2.4) { e, dt in
            if abs(dt - 0.1) < 0.02 { poseAtStart = e.displayMood }
            if abs(dt - 0.9) < 0.02 { poseMidWave = e.displayMood; eyesDuring = e.eyeStyle }
            if abs(dt - 2.2) < 0.02 { poseAfter = e.displayMood }
        }
        #expect(poseAtStart == .awake, "the dip comes first")
        #expect(poseMidWave == .waiting, "the hand goes up")
        #expect(eyesDuring == .arc, "happy eyes")
        #expect(poseAfter == .awake, "and comes back")
        #expect(engine.greetPhase == nil)
    }

    @Test func theGreetingNodsTheHeadAndDips() {
        let (engine, t) = engine(.awake)
        engine.greet(now: t)
        var tiltRange = (lo: 1.0, hi: -1.0), lowestOY = 0.0, highestOY = 0.0
        run(engine, from: t, seconds: 1.7) { e, _ in
            let tilt = e.value[.tilt] ?? 0
            tiltRange = (min(tiltRange.lo, tilt), max(tiltRange.hi, tilt))
            lowestOY = min(lowestOY, e.value[.oy] ?? 0); highestOY = max(highestOY, e.value[.oy] ?? 0)
        }
        #expect(tiltRange.hi - tiltRange.lo > 0.05, "no sway")
        #expect(lowestOY < -0.03, "no hop")
        #expect(highestOY > 0.005, "no dip")
    }

    @Test func aGreetingDoesNotRestartTooSoon() {
        let (engine, t) = engine(.awake)
        #expect(engine.greet(now: t))
        #expect(engine.greet(now: t + 1) == false)
        #expect(engine.greet(now: t + 5))
    }

    @Test func peekyDoesNotGreetWhileAskingOrCelebrating() {
        let (asking, t1) = engine(.waiting)
        #expect(asking.greet(now: t1) == false)
        let (celebrating, t2) = engine(.done)
        #expect(celebrating.greet(now: t2) == false)
    }

    @Test func aSleepingPeekyWavesToo() {
        let (engine, t) = engine(.asleep)
        #expect(engine.greet(now: t))
        var openDuring = 0.0
        run(engine, from: t, seconds: 1.2) { e, dt in if dt > 0.9 { openDuring = e.eyeStyle == .arc ? 1 : 0 } }
        #expect(openDuring == 1)
    }

    @Test func noBlinkingDuringTheGreeting() {
        // Глаза сперва открываются из сна и делают первое моргание; ждём, пока
        // всё уляжется, и только потом здороваемся.
        let (engine, t) = engine(.awake)
        run(engine, from: t, seconds: 0.9) { _, _ in }
        let start = t + 0.9
        #expect((engine.value[.open] ?? 0) > 0.9, "eyes should be open before the test starts")
        engine.greet(now: start)
        var lowestOpen = 1.0
        run(engine, from: start, seconds: 1.8) { e, _ in lowestOpen = min(lowestOpen, e.value[.open] ?? 1) }
        #expect(lowestOpen > 0.5)
    }

    @Test func theModelGreetsOnlyWhileShown() {
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
        let sounds = sounds()
        let model = AvatarModel(store: store, poses: Self.poses, sounds: sounds)
        model.greet()
        #expect(sounds.lastPlayed == nil, "no session, no avatar, no greeting")

        store.apply(AgentEvent(name: "SessionStart", sessionID: "a", cwd: nil, toolName: nil))
        model.greet()
        #expect(sounds.lastPlayed == .hello)
        #expect(model.engine?.greetPhase != nil || model.engine?.displayMood != nil)
    }

    // MARK: - Звуки

    @Test func everySoundIsAShortFile() throws {
        for sound in PeekySounds.Sound.allCases {
            let url = Self.resources.appendingPathComponent("sounds/\(sound.rawValue).wav")
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0.2 && player.duration < 1.0, "\(sound) lasts \(player.duration) s")
        }
    }

    @Test func soundsPlayAndRespectTheCooldown() {
        let sounds = sounds()
        let t = Date()
        sounds.play(.done, now: t)
        #expect(sounds.lastPlayed == .done)
        sounds.play(.hello, now: t)
        #expect(sounds.lastPlayed == .hello)
        sounds.play(.done, now: t.addingTimeInterval(1))      // меньше трёх секунд
        sounds.play(.ask, now: t.addingTimeInterval(1.5))
        #expect(sounds.lastPlayed == .ask)
        sounds.play(.done, now: t.addingTimeInterval(1.6))
        #expect(sounds.lastPlayed == .ask, "done is still cooling down")
        sounds.play(.done, now: t.addingTimeInterval(4))
        #expect(sounds.lastPlayed == .done)
    }

    @Test func switchedOffMeansSilence() {
        let sounds = sounds(enabled: false)
        for sound in PeekySounds.Sound.allCases { sounds.play(sound) }
        #expect(sounds.lastPlayed == nil)
    }

    @Test func aMissingSoundIsSilentNotAnError() {
        let sounds = PeekySounds()
        sounds.folder = URL(fileURLWithPath: "/nonexistent")
        sounds.isEnabled = { true }
        sounds.play(.hello)
        #expect(sounds.lastPlayed == nil)
    }

    @Test func finishingATaskPlaysTheDoneChime() {
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
        let sounds = sounds()
        let model = AvatarModel(store: store, poses: Self.poses, sounds: sounds)
        defer { withExtendedLifetime(model) {} }
        store.apply(AgentEvent(name: "PreToolUse", sessionID: "a", cwd: nil, toolName: "Bash"))
        #expect(sounds.lastPlayed == nil, "working is silent")
        store.apply(AgentEvent(name: "Stop", sessionID: "a", cwd: nil, toolName: nil))
        #expect(sounds.lastPlayed == .done)
    }
}
