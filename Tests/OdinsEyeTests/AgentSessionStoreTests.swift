import Foundation
import Testing
@testable import OdinsEye

/// Сессии Claude Code: разбор события и переходы состояний. Сокет не нужен —
/// стор принимает события напрямую, а время приходит параметром.
@MainActor
struct AgentSessionStoreTests {
    private static func store() -> AgentSessionStore {
        AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
    }

    private static func event(
        _ name: String, id: String = "s1", cwd: String? = "/Users/x/proj", tool: String? = nil
    ) -> AgentEvent {
        AgentEvent(name: name, sessionID: id, cwd: cwd, toolName: tool)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Разбор

    @Test func parsesAHookPayload() {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/a/b","tool_name":"Bash","extra":{"x":1}}"#
        let event = AgentEvent.parse(Data(json.utf8))
        #expect(event == AgentEvent(name: "PreToolUse", sessionID: "abc", cwd: "/a/b", toolName: "Bash"))
    }

    @Test func rejectsGarbageAndIncompletePayloads() {
        #expect(AgentEvent.parse(Data("not json".utf8)) == nil)
        #expect(AgentEvent.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(AgentEvent.parse(Data(#"{"session_id":"a"}"#.utf8)) == nil)
        #expect(AgentEvent.parse(Data(#"{"hook_event_name":"","session_id":"a"}"#.utf8)) == nil)
    }

    @Test func clipsLongText() {
        let long = String(repeating: "x", count: 5_000)
        let json = #"{"hook_event_name":"Stop","session_id":"a","cwd":"\#(long)"}"#
        #expect(AgentEvent.parse(Data(json.utf8))?.cwd?.count == AgentEvent.maxText)
    }

    @Test func refusesOversizedMessages() {
        let pad = String(repeating: "x", count: AgentEvent.maxBytes)
        let json = #"{"hook_event_name":"Stop","session_id":"a","pad":"\#(pad)"}"#
        #expect(AgentEvent.parse(Data(json.utf8)) == nil)
    }

    // MARK: - Переходы

    @Test func followsTheHappyPath() {
        let store = Self.store()
        store.apply(Self.event("SessionStart"), now: t0)
        #expect(store.sessions.first?.state == .idle)
        store.apply(Self.event("UserPromptSubmit"), now: t0)
        #expect(store.sessions.first?.state == .thinking)
        store.apply(Self.event("PreToolUse", tool: "Bash"), now: t0)
        #expect(store.sessions.first?.state == .working)
        #expect(store.sessions.first?.tool == "Bash")
        store.apply(Self.event("PostToolUse", tool: "Bash"), now: t0)
        #expect(store.sessions.first?.state == .working)
        store.apply(Self.event("Stop"), now: t0)
        #expect(store.sessions.first?.state == .finished)
        #expect(store.sessions.first?.tool == nil)
    }

    @Test func finishedSettlesToIdleAfterFiveSeconds() {
        let store = Self.store()
        store.apply(Self.event("Stop"), now: t0)
        store.settleFinished(now: t0.addingTimeInterval(4))
        #expect(store.sessions.first?.state == .finished)
        store.settleFinished(now: t0.addingTimeInterval(5))
        #expect(store.sessions.first?.state == .idle)
    }

    @Test func sessionEndRemovesIt() {
        let store = Self.store()
        store.apply(Self.event("SessionStart"), now: t0)
        store.apply(Self.event("SessionEnd"), now: t0)
        #expect(store.sessions.isEmpty)
    }

    @Test func midSessionEventCreatesTheSession() {
        let store = Self.store()
        store.apply(Self.event("PreToolUse", id: "late", tool: "Read"), now: t0)
        #expect(store.sessions.map(\.id) == ["late"])
        #expect(store.sessions.first?.project == "proj")
    }

    @Test func unknownEventsAreIgnored() {
        let store = Self.store()
        store.apply(Self.event("SomethingNew"), now: t0)
        #expect(store.sessions.isEmpty)
        store.apply(Self.event("SessionEnd", id: "ghost"), now: t0)
        #expect(store.sessions.isEmpty)
    }

    @Test func notificationMeansWaitingAndOutranksWorking() {
        let store = Self.store()
        store.apply(Self.event("PreToolUse", id: "a"), now: t0)
        store.apply(Self.event("Notification", id: "b"), now: t0)
        #expect(store.worst == .waiting)
    }

    @Test func freshestSessionIsFirst() {
        let store = Self.store()
        store.apply(Self.event("SessionStart", id: "old"), now: t0)
        store.apply(Self.event("SessionStart", id: "new"), now: t0.addingTimeInterval(10))
        #expect(store.sessions.map(\.id) == ["new", "old"])
    }

    @Test func abandonedSessionsAreDropped() {
        let store = Self.store()
        store.apply(Self.event("SessionStart", id: "gone"), now: t0)
        store.apply(Self.event("SessionStart", id: "now"), now: t0.addingTimeInterval(AgentSessionStore.staleAfter + 1))
        #expect(store.sessions.map(\.id) == ["now"])
    }

    @Test func projectIsTheLastPathComponent() {
        #expect(AgentSessionStore.project(of: "/Users/x/Projects/cyclop") == "cyclop")
        #expect(AgentSessionStore.project(of: "/") == "/")
        #expect(AgentSessionStore.project(of: nil) == "—")
    }
}

/// Настоящий хук: `/usr/bin/nc -U` в настоящий сокет. Проверяет то, что в
/// архитектуре было под вопросом, — что `nc` уходит быстро и что JSON без
/// перевода строки доходит.
@MainActor
struct AgentSocketRoundTripTests {
    private static func path() -> String {
        "/tmp/oe-\(UUID().uuidString.prefix(8)).sock"
    }

    private static func send(_ payload: String, to path: String) throws -> TimeInterval {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", "-w1", path]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return Date().timeIntervalSince(started)
    }

    private static func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<40 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func eventsSentByNcArriveAndNcReturnsQuickly() async throws {
        let path = Self.path()
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: path))
        store.start()
        defer { store.stop() }

        let withNewline = #"{"hook_event_name":"SessionStart","session_id":"a","cwd":"/x/one"}"# + "\n"
        let without = #"{"hook_event_name":"UserPromptSubmit","session_id":"b","cwd":"/x/two"}"#
        let t1 = try Self.send(withNewline, to: path)
        let t2 = try Self.send(without, to: path)

        await Self.wait { store.sessions.count == 2 }
        #expect(Set(store.sessions.map(\.project)) == ["one", "two"])
        #expect(t1 < 0.5)
        #expect(t2 < 0.5)

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func garbageOnTheSocketIsIgnored() async throws {
        let path = Self.path()
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: path))
        store.start()
        defer { store.stop() }
        _ = try Self.send("hello\n", to: path)
        _ = try Self.send(#"{"hook_event_name":"SessionStart","session_id":"ok"}"# + "\n", to: path)
        await Self.wait { store.sessions.count == 1 }
        #expect(store.sessions.map(\.id) == ["ok"])
    }

    @Test func stopRemovesTheSocketFile() throws {
        let path = Self.path()
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: path))
        store.start()
        #expect(FileManager.default.fileExists(atPath: path))
        store.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

struct AgentRowTimeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func agoIsShort() {
        #expect(AgentRow.ago(t0, now: t0.addingTimeInterval(5)) == "now")
        #expect(AgentRow.ago(t0, now: t0.addingTimeInterval(300)) == "5 min")
        #expect(AgentRow.ago(t0, now: t0.addingTimeInterval(7300)) == "2 h")
        #expect(AgentRow.ago(t0, now: t0.addingTimeInterval(-9)) == "now")
    }
}

/// Полезные нагрузки, снятые с настоящего Claude Code 2.1.304 (27.10.2026):
/// проверка, что разбор не разошёлся с тем, что хуки шлют на самом деле.
@MainActor
struct AgentRealPayloadTests {
    private static let sessionStart = #"{"session_id":"2789c30d-a259-4587-980f-d2149bd19770","transcript_path":"/Users/x/.claude/projects/-private-tmp-oe-live/2789c30d.jsonl","cwd":"/private/tmp/oe-live","hook_event_name":"SessionStart","source":"startup"}"#
    private static let prompt = #"{"session_id":"2789c30d-a259-4587-980f-d2149bd19770","cwd":"/private/tmp/oe-live","permission_mode":"default","prompt_id":"p1","prompt":"Run echo hi","hook_event_name":"UserPromptSubmit"}"#
    private static let preTool = #"{"session_id":"2789c30d-a259-4587-980f-d2149bd19770","cwd":"/private/tmp/oe-live","permission_mode":"auto","effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi","description":"x"},"tool_use_id":"toolu_01"}"#
    private static let sessionEnd = #"{"session_id":"2789c30d-a259-4587-980f-d2149bd19770","cwd":"/private/tmp/oe-live","hook_event_name":"SessionEnd","reason":"other"}"#

    @Test func realPayloadsDriveTheStateMachine() {
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
        store.receive(Data(Self.sessionStart.utf8))
        #expect(store.sessions.first?.state == .idle)
        #expect(store.sessions.first?.project == "oe-live")
        store.receive(Data(Self.prompt.utf8))
        #expect(store.sessions.first?.state == .thinking)
        store.receive(Data(Self.preTool.utf8))
        #expect(store.sessions.first?.state == .working)
        #expect(store.sessions.first?.tool == "Bash")
        store.receive(Data(Self.sessionEnd.utf8))
        #expect(store.sessions.isEmpty)
    }
}
