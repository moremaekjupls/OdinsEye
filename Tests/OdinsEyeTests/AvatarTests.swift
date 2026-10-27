import AppKit
import Foundation
import Testing
@testable import OdinsEye

/// Аватар: какое настроение по каким сессиям и откуда берутся свои картинки.
/// Сама анимация проверяется глазами.
@MainActor
struct AvatarTests {
    private func session(_ state: AgentSession.State, _ id: String = "a") -> AgentSession {
        AgentSession(id: id, project: "p", state: state, tool: nil, updatedAt: Date())
    }

    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("odinseye-avatar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store() -> AgentSessionStore {
        AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
    }

    // MARK: - Настроение

    @Test func noSessionsMeansNoAvatar() {
        #expect(AvatarModel.mood(for: [], hasPending: false) == nil)
    }

    @Test func moodFollowsTheMostUrgentSession() {
        #expect(AvatarModel.mood(for: [session(.idle)], hasPending: false) == .asleep)
        #expect(AvatarModel.mood(for: [session(.idle), session(.thinking, "b")], hasPending: false) == .thinking)
        #expect(AvatarModel.mood(for: [session(.working), session(.thinking, "b")], hasPending: false) == .working)
        #expect(AvatarModel.mood(for: [session(.working), session(.waiting, "b")], hasPending: false) == .waiting)
        #expect(AvatarModel.mood(for: [session(.finished)], hasPending: false) == .done)
    }

    @Test func aPendingRequestOutranksEverything() {
        #expect(AvatarModel.mood(for: [session(.working)], hasPending: true) == .waiting)
        #expect(AvatarModel.mood(for: [], hasPending: true) == .waiting)
    }

    @Test func theModelFollowsTheStore() throws {
        let store = store()
        let model = AvatarModel(store: store, skins: AvatarSkins(folder: try folder()))
        #expect(model.isPresent == false)
        #expect(model.isShown == false)

        store.apply(AgentEvent(name: "PreToolUse", sessionID: "a", cwd: "/x/p", toolName: "Bash"))
        #expect(model.isPresent)
        #expect(model.mood == .working)

        store.apply(AgentEvent(name: "Notification", sessionID: "a", cwd: "/x/p", toolName: nil))
        #expect(model.mood == .waiting)

        store.apply(AgentEvent(name: "SessionEnd", sessionID: "a", cwd: "/x/p", toolName: nil))
        #expect(model.isPresent == false)
    }

    @Test func anOpenPanelCoversTheAvatar() throws {
        let store = store()
        let model = AvatarModel(store: store, skins: AvatarSkins(folder: try folder()))
        store.apply(AgentEvent(name: "SessionStart", sessionID: "a", cwd: nil, toolName: nil))
        #expect(model.isShown)
        model.setCovered(true)
        #expect(model.isShown == false)
        model.setCovered(false)
        #expect(model.isShown)
    }

    // MARK: - Свои картинки

    private func writePNG(_ url: URL) throws {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func aSkinIsUsedForItsMoodOnly() throws {
        let dir = try folder()
        try writePNG(dir.appendingPathComponent("thinking.png"))
        let skins = AvatarSkins(folder: dir)
        #expect(skins.image(for: .thinking) != nil)
        #expect(skins.image(for: .working) == nil)
    }

    @Test func aReplacedFileIsPickedUpAndADeletedOneIsForgotten() throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("idle.png")
        try writePNG(file)
        let skins = AvatarSkins(folder: dir)
        #expect(skins.image(for: .asleep) != nil)
        try FileManager.default.removeItem(at: file)
        #expect(skins.image(for: .asleep) == nil)
    }

    @Test func aBrokenFileFallsBackToTheEye() throws {
        let dir = try folder()
        try Data("not a png".utf8).write(to: dir.appendingPathComponent("done.png"))
        #expect(AvatarSkins(folder: dir).image(for: .done) == nil)
    }

    @Test func aSkinReachesTheModel() throws {
        let dir = try folder()
        try writePNG(dir.appendingPathComponent("idle.png"))
        let store = store()
        let model = AvatarModel(store: store, skins: AvatarSkins(folder: dir))
        store.apply(AgentEvent(name: "SessionStart", sessionID: "a", cwd: nil, toolName: nil))
        #expect(model.skin != nil)
    }

    @Test func theReadmeExplainsTheFileNames() throws {
        let dir = try folder()
        _ = AvatarSkins(folder: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("README.txt"), encoding: .utf8)
        for name in ["idle.png", "thinking.png", "working.png", "waiting.png", "done.png"] {
            #expect(text.contains(name))
        }
    }
}
