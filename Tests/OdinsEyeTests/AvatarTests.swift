import Foundation
import Testing
@testable import OdinsEye

/// Peeky: позы и разметка глаз, соответствие сессий настроениям, движок
/// анимации и короткая строка шага. Рисование проверяется глазами; здесь
/// логика, в которой время приходит параметром.
@MainActor
struct AvatarTests {
    /// Настоящие позы из репозитория, а не заглушки.
    private static let poses: [PeekyMood: PeekyPose] = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/peeky", isDirectory: true)
        return PeekyAssets.load(from: folder) ?? [:]
    }()

    private func session(_ state: AgentSession.State, _ id: String = "a") -> AgentSession {
        AgentSession(id: id, project: "p", state: state, tool: nil, updatedAt: Date())
    }

    private func store() -> AgentSessionStore {
        AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
    }

    // MARK: - Позы

    @Test func everyMoodHasAPoseWithSaneEyeMarkup() throws {
        #expect(Self.poses.count == 6)
        for (mood, pose) in Self.poses {
            #expect(pose.image.width == 320, "\(mood) image size")
            #expect((0...1).contains(pose.faceCenter.x) && (0...1).contains(pose.faceCenter.y))
            #expect(pose.faceWidth > 0.3 && pose.faceWidth < 0.8, "\(mood) face width \(pose.faceWidth)")
            #expect(pose.eyeSeparation >= pose.faceWidth * 0.36 && pose.eyeSeparation <= pose.faceWidth * 0.6)
            #expect(abs(pose.eyeAngle) <= 0.35)
            // Глаза лежат внутри лица.
            #expect(abs(pose.eyeMid.x - pose.faceCenter.x) < pose.faceWidth / 2)
            #expect(abs(pose.eyeMid.y - pose.faceCenter.y) < pose.faceHeight / 2)
        }
    }

    @Test func missingFilesMeanNoAvatar() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("odinseye-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(PeekyAssets.load(from: empty) == nil)
    }

    // MARK: - Настроение по сессиям

    @Test func noSessionsMeansNoMood() {
        #expect(AvatarModel.mood(for: [], hasPending: false) == nil)
    }

    @Test func moodFollowsTheMostUrgentSession() {
        #expect(AvatarModel.mood(for: [session(.idle)], hasPending: false) == .awake)
        #expect(AvatarModel.mood(for: [session(.idle), session(.thinking, "b")], hasPending: false) == .thinking)
        #expect(AvatarModel.mood(for: [session(.working), session(.thinking, "b")], hasPending: false) == .working)
        #expect(AvatarModel.mood(for: [session(.working), session(.waiting, "b")], hasPending: false) == .waiting)
        #expect(AvatarModel.mood(for: [session(.finished)], hasPending: false) == .done)
    }

    @Test func aPendingRequestOutranksEverything() {
        #expect(AvatarModel.mood(for: [session(.working)], hasPending: true) == .waiting)
        #expect(AvatarModel.mood(for: [], hasPending: true) == .waiting)
    }

    @Test func theModelFollowsTheStore() {
        let store = store()
        let model = AvatarModel(store: store, poses: Self.poses)
        #expect(model.isShown == false)

        store.apply(AgentEvent(name: "PreToolUse", sessionID: "a", cwd: "/x/p", toolName: "Bash"))
        #expect(model.isShown)
        #expect(model.mood == .working)
        #expect(model.engine?.mood == .working)
        #expect(model.dots == [.working])

        store.apply(AgentEvent(name: "Notification", sessionID: "a", cwd: "/x/p", toolName: nil))
        #expect(model.mood == .waiting)

        store.apply(AgentEvent(name: "SessionEnd", sessionID: "a", cwd: "/x/p", toolName: nil))
        #expect(model.isShown == false)
        #expect(model.mood == .asleep)
    }

    @Test func withoutPosesThereIsNoAvatar() {
        let store = store()
        let model = AvatarModel(store: store, poses: nil)
        store.apply(AgentEvent(name: "SessionStart", sessionID: "a", cwd: nil, toolName: nil))
        #expect(model.engine == nil)
        #expect(model.isShown == false)
    }

    @Test func anOpenPanelCoversTheIsland() {
        let store = store()
        let model = AvatarModel(store: store, poses: Self.poses)
        store.apply(AgentEvent(name: "SessionStart", sessionID: "a", cwd: nil, toolName: nil))
        #expect(model.isShown)
        model.setCovered(true)
        #expect(model.isShown == false)
        model.setCovered(false)
        #expect(model.isShown)
    }

    @Test func anIdlePeekyDozesOffAndAnEventWakesHim() async throws {
        let store = store()
        let model = AvatarModel(store: store, poses: Self.poses, dozeAfter: 0.05)
        store.apply(AgentEvent(name: "SessionStart", sessionID: "a", cwd: nil, toolName: nil))
        #expect(model.mood == .awake)
        for _ in 0..<40 where model.mood != .asleep { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.mood == .asleep)
        #expect(model.isPresent, "asleep but still there")

        store.apply(AgentEvent(name: "PostToolUse", sessionID: "a", cwd: nil, toolName: "Bash"))
        #expect(model.mood == .working)
    }

    // MARK: - Движок

    private func engine(_ mood: PeekyMood) -> (PeekyEngine, Double) {
        let engine = PeekyEngine(poses: Self.poses)
        var t = 100.0
        engine.update(now: t)
        engine.setMood(mood, now: t)
        // Настроение начинается без твинов: даём ему устояться.
        t += 0.001
        return (engine, t)
    }

    /// Гоним кадры на 30 к/с и возвращаем всё, что вернёт `probe`.
    private func run(_ engine: PeekyEngine, from start: Double, seconds: Double, _ probe: (PeekyEngine) -> Void) {
        var t = start
        while t < start + seconds { engine.update(now: t); probe(engine); t += 1.0 / 30 }
    }

    @Test func everyMoodKeepsEveryValueInBounds() {
        for mood in [PeekyMood.asleep, .awake, .thinking, .working, .waiting, .done] {
            var (engine, t) = engine(mood)
            engine.cursor = CGPoint(x: 1, y: -1)
            run(engine, from: t, seconds: 12) { e in
                for (prop, v) in e.value {
                    #expect(v.isFinite, "\(mood) \(prop) is not finite")
                }
                #expect((0...1.001).contains(e.value[.open] ?? 0), "\(mood) open \(e.value[.open] ?? -1)")
                #expect((0.6...1.4).contains(e.value[.sy] ?? 0), "\(mood) sy")
                #expect((0.6...1.4).contains(e.value[.sx] ?? 0), "\(mood) sx")
                #expect(abs(e.value[.gx] ?? 0) <= 1.05 && abs(e.value[.gy] ?? 0) <= 1.05, "\(mood) gaze")
            }
            _ = engine; t += 0
        }
    }

    @Test func anAwakePeekyBlinks() {
        var (engine, t) = engine(.awake)
        var lowest = 1.0
        run(engine, from: t, seconds: 8) { lowest = min(lowest, $0.value[.open] ?? 1) }
        #expect(lowest < 0.2, "never blinked, lowest open \(lowest)")
        _ = engine; t += 0
    }

    @Test func aSleepingPeekyKeepsHisEyesClosedAndSendsZs() {
        var (engine, t) = engine(.asleep)
        var highest = 0.0, sawZ = false
        run(engine, from: t, seconds: 4) {
            highest = max(highest, $0.value[.open] ?? 0)
            if $0.particles.contains(where: { $0.kind == .z }) { sawZ = true }
        }
        #expect(highest < 0.1)
        #expect(sawZ)
        #expect(engine.eyeStyle == .sleepy)
        _ = t; t += 0
    }

    @Test func finishedPlaysAFlipAndThrowsSparks() {
        var (engine, t) = engine(.done)
        var maxSpin = 0.0, sawSpark = false
        run(engine, from: t, seconds: 2) {
            maxSpin = max(maxSpin, $0.value[.spin] ?? 0)
            if $0.particles.contains(where: { $0.kind == .spark }) { sawSpark = true }
        }
        #expect(maxSpin > 5.5, "flip reached \(maxSpin) rad")
        #expect(abs(engine.value[.spin] ?? 9) < 0.001, "flip must land back at 0")
        #expect(sawSpark)
        #expect(engine.eyeStyle == .arc)
        _ = t; t += 0
    }

    @Test func waitingHopsAndOpensItsEyesWide() {
        var (engine, t) = engine(.waiting)
        var highest = 0.0
        run(engine, from: t, seconds: 1) { highest = max(highest, -($0.value[.oy] ?? 0)) }
        #expect(highest > 0.04, "no hop, peak \(highest)")
        #expect(engine.eyeStyle == .round)
        _ = t; t += 0
    }

    @Test func aPokeSquashesAndSettles() {
        var (engine, t) = engine(.working)
        run(engine, from: t, seconds: 1) { _ in }
        t += 1
        engine.poke(now: t)
        var lowest = 1.0
        run(engine, from: t, seconds: 0.2) { lowest = min(lowest, $0.value[.sy] ?? 1) }
        #expect(lowest < 0.97, "poke did not squash, sy \(lowest)")
        run(engine, from: t + 0.2, seconds: 1) { _ in }
        #expect(abs((engine.value[.sy] ?? 0) - 1) < 0.06)
    }

    @Test func aPokeDoesNothingToASleepingPeeky() {
        var (engine, t) = engine(.asleep)
        run(engine, from: t, seconds: 1) { _ in }
        t += 1
        engine.poke(now: t)
        var lowest = 1.0
        run(engine, from: t, seconds: 0.2) { lowest = min(lowest, $0.value[.sy] ?? 1) }
        #expect(lowest > 0.9)
    }

    @Test func gazeFollowsTheCursorWhenAwake() {
        var (engine, t) = engine(.awake)
        engine.cursor = CGPoint(x: 1, y: 0)
        run(engine, from: t, seconds: 2) { _ in }
        #expect((engine.value[.gx] ?? 0) > 0.5)
        engine.cursor = CGPoint(x: -1, y: 0)
        t += 2
        run(engine, from: t, seconds: 2) { _ in }
        #expect((engine.value[.gx] ?? 0) < -0.5)
    }

    @Test func framesSlowDownWhenNothingMoves() {
        var (engine, t) = engine(.asleep)
        run(engine, from: t, seconds: 6) { _ in }
        #expect(engine.fps == 10)
        engine.setMood(.working, now: t + 6)
        #expect(engine.fps == 30)
    }

    // MARK: - Шаг

    @Test func theStepNamesToolAndTarget() {
        func step(_ json: String) -> String? { AgentEvent.parse(Data(json.utf8))?.step }
        func pre(_ tool: String, _ input: String) -> String {
            #"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"\#(tool)","tool_input":\#(input)}"#
        }
        #expect(step(pre("Bash", #"{"command":"npm test\nnpm run build"}"#)) == "Bash npm test")
        #expect(step(pre("Edit", #"{"file_path":"/a/b/Invoice.swift"}"#)) == "Edit Invoice.swift")
        #expect(step(pre("Grep", #"{"pattern":"TODO"}"#)) == "Grep TODO")
        #expect(step(pre("WebFetch", #"{"url":"https://example.com/x"}"#)) == "WebFetch example.com")
        #expect(step(pre("Task", #"{"prompt":"x"}"#)) == "Task")
        let long = String(repeating: "a", count: 200)
        #expect(step(pre("Bash", #"{"command":"\#(long)"}"#))?.count == 60)
    }

    @Test func onlyPreToolUseCarriesAStep() {
        let event = AgentEvent.parse(Data(#"{"hook_event_name":"Stop","session_id":"a","tool_name":"Bash"}"#.utf8))
        #expect(event?.step == nil)
    }

    @Test func theStepReachesTheSessionAndClearsOnStop() {
        let store = store()
        store.apply(AgentEvent(name: "PreToolUse", sessionID: "a", cwd: nil, toolName: "Edit", step: "Edit Invoice.swift"))
        #expect(store.sessions.first?.step == "Edit Invoice.swift")
        store.apply(AgentEvent(name: "Stop", sessionID: "a", cwd: nil, toolName: nil))
        #expect(store.sessions.first?.step == nil)
    }
}

@MainActor
struct PeekyEngineFollowUpTests {
    private static let poses: [PeekyMood: PeekyPose] = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/peeky", isDirectory: true)
        return PeekyAssets.load(from: folder) ?? [:]
    }()

    @Test func wakingUpDropsTheSleepersZs() {
        let engine = PeekyEngine(poses: Self.poses)
        var t = 10.0
        engine.update(now: t)
        engine.setMood(.asleep, now: t)
        while t < 12 { t += 1.0 / 30; engine.update(now: t) }
        #expect(engine.particles.contains { $0.kind == .z })
        engine.setMood(.awake, now: t)
        #expect(engine.particles.contains { $0.kind == .z } == false)
    }
}
