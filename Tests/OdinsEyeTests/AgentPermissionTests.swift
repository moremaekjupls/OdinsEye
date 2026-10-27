import Foundation
import Testing
@testable import OdinsEye

/// Запросы разрешения: разбор, формат ответа хуку, жизненный цикл карточки и
/// сквозной путь через настоящий `nc`.
@MainActor
struct AgentPermissionTests {
    private static func request(
        tool: String = "Bash", input: String = #"{"command":"rm -rf node_modules"}"#,
        suggestions: String = #","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]"#,
        session: String = "s1"
    ) -> Data {
        Data(#"{"session_id":"\#(session)","cwd":"/Users/x/proj","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)\#(suggestions)}"#.utf8)
    }

    private static func store() -> AgentSessionStore {
        AgentSessionStore(socketURL: URL(fileURLWithPath: "/tmp/odinseye-test-unused.sock"))
    }

    /// Пара сокетов: одна сторона у `AgentReply`, с другой читаем, что хук получил.
    private static func pair() -> (reply: AgentReply, reader: Int32) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (AgentReply(fd: fds[0]), fds[1])
    }

    private static func drain(_ fd: Int32) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
        }
        close(fd)
        return data
    }

    private static func decision(_ data: Data) -> [String: Any]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let out = root["hookSpecificOutput"] as? [String: Any],
              out["hookEventName"] as? String == "PermissionRequest"
        else { return nil }
        return out["decision"] as? [String: Any]
    }

    // MARK: - Разбор

    @Test func parsesTheRequestAndNarrowsTheRuleToTheSession() throws {
        let event = try #require(AgentEvent.parse(Self.request()))
        let permission = try #require(event.permission)
        #expect(permission.tool == "Bash")
        #expect(permission.detail == "rm -rf node_modules")
        #expect(permission.isComplete)
        let suggestion = try #require(permission.suggestion)
        let rule = try #require(try JSONSerialization.jsonObject(with: suggestion) as? [String: Any])
        #expect(rule["destination"] as? String == "session")
        #expect(rule["type"] as? String == "addRules")
        #expect(rule["behavior"] as? String == "allow")
    }

    @Test func fileToolsShowThePath() throws {
        let event = try #require(AgentEvent.parse(Self.request(
            tool: "Write", input: #"{"file_path":"/etc/hosts","content":"x"}"#, suggestions: ""
        )))
        #expect(event.permission?.detail == "/etc/hosts")
        #expect(event.permission?.suggestion == nil)
    }

    @Test func unknownToolsShowTheirArguments() throws {
        let event = try #require(AgentEvent.parse(Self.request(
            tool: "mcp__x__y", input: #"{"b":2,"a":"1"}"#, suggestions: ""
        )))
        #expect(event.permission?.detail == #"{"a":"1","b":2}"#)
    }

    @Test func aCommandTooLongToShowIsNotApprovable() throws {
        let long = String(repeating: "a", count: AgentEvent.maxDetail + 1)
        let event = try #require(AgentEvent.parse(Self.request(input: #"{"command":"\#(long)"}"#)))
        #expect(event.permission?.isComplete == false)
        #expect(event.permission?.detail.count == AgentEvent.maxDetail)
    }

    @Test func otherEventsCarryNoPermission() throws {
        let event = try #require(AgentEvent.parse(Data(#"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"Bash"}"#.utf8)))
        #expect(event.permission == nil)
    }

    // MARK: - Формат ответа

    @Test func allowResponseMatchesTheDocumentedShape() throws {
        let data = AgentSessionStore.response(.allow, suggestion: nil)
        let decision = try #require(Self.decision(data))
        #expect(decision["behavior"] as? String == "allow")
        #expect(decision["updatedPermissions"] == nil)
    }

    @Test func denyResponseCarriesAMessage() throws {
        let decision = try #require(Self.decision(AgentSessionStore.response(.deny, suggestion: nil)))
        #expect(decision["behavior"] as? String == "deny")
        #expect((decision["message"] as? String)?.isEmpty == false)
    }

    @Test func alwaysResponseEchoesTheSessionRule() throws {
        let event = try #require(AgentEvent.parse(Self.request()))
        let data = AgentSessionStore.response(.allowForSession, suggestion: event.permission?.suggestion)
        let decision = try #require(Self.decision(data))
        let updates = try #require(decision["updatedPermissions"] as? [[String: Any]])
        #expect(updates.count == 1)
        #expect(updates[0]["destination"] as? String == "session")
    }

    // MARK: - Жизненный цикл

    @Test func allowReachesTheHookAndClearsTheCard() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(), reply: reply)
        #expect(store.pending.count == 1)
        #expect(store.sessions.first?.state == .waiting)

        store.respond(to: store.pending[0], .allow)
        #expect(store.pending.isEmpty)
        #expect(store.sessions.first?.state == .working)
        let decision = Self.decision(Self.drain(reader))
        #expect(decision?["behavior"] as? String == "allow")
    }

    @Test func denyReachesTheHook() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(), reply: reply)
        store.respond(to: store.pending[0], .deny)
        #expect(Self.decision(Self.drain(reader))?["behavior"] as? String == "deny")
        #expect(store.sessions.first?.state == .thinking)
    }

    @Test func aSecondAnswerDoesNothing() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(), reply: reply)
        let item = store.pending[0]
        store.respond(to: item, .deny)
        store.respond(to: item, .allow)
        let decision = Self.decision(Self.drain(reader))
        #expect(decision?["behavior"] as? String == "deny")
    }

    @Test func anIncompleteRequestIsNeverApprovedFromThePanel() throws {
        let store = Self.store()
        let long = String(repeating: "a", count: AgentEvent.maxDetail + 1)
        let (reply, reader) = Self.pair()
        store.receive(Self.request(input: #"{"command":"\#(long)"}"#), reply: reply)
        #expect(store.pending[0].canAllow == false)
        store.respond(to: store.pending[0], .allow)
        #expect(Self.drain(reader).isEmpty)
    }

    @Test func alwaysWithoutASuggestionIsNotApproved() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(suggestions: ""), reply: reply)
        #expect(store.pending[0].canAlways == false)
        store.respond(to: store.pending[0], .allowForSession)
        #expect(Self.drain(reader).isEmpty)
    }

    @Test func theSessionMovingOnMeansItWasAnsweredInTheTerminal() async throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(), reply: reply)
        store.receive(Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8))
        #expect(Self.drain(reader).isEmpty)
        for _ in 0..<40 where !store.pending.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(store.pending.isEmpty)
    }

    @Test func anotherSessionsEventLeavesTheCardAlone() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(session: "s1"), reply: reply)
        store.receive(Data(#"{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"Bash"}"#.utf8))
        #expect(store.pending.count == 1)
        store.respond(to: store.pending[0], .deny)
        _ = Self.drain(reader)
    }

    @Test func closingTheReplyRemovesTheCard() async throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(), reply: reply)
        reply.send(nil)
        for _ in 0..<40 where !store.pending.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(store.pending.isEmpty)
        #expect(Self.drain(reader).isEmpty)
    }

    @Test func stoppingTheStoreReleasesTheHook() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Self.request(), reply: reply)
        store.stop()
        #expect(store.pending.isEmpty)
        #expect(Self.drain(reader).isEmpty)
    }

    @Test func garbageWithAReplyStillClosesIt() throws {
        let store = Self.store()
        let (reply, reader) = Self.pair()
        store.receive(Data("nonsense".utf8), reply: reply)
        #expect(Self.drain(reader).isEmpty)
    }
}

/// Хук целиком: настоящий `nc -U` ждёт ответ и печатает его в stdout, как
/// Claude Code его прочитает.
@MainActor
struct AgentPermissionRoundTripTests {
    private static func path() -> String { "/tmp/oe-\(UUID().uuidString.prefix(8)).sock" }

    private static let payload = #"{"session_id":"live","cwd":"/x/proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"# + "\n"

    private static func startHook(_ path: String) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", "-w10", path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        return (process, output)
    }

    /// Не дольше пяти секунд: зависший `nc` не должен держать набор тестов.
    private static func finish(_ process: Process) async -> Bool {
        for _ in 0..<200 where process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        let exited = !process.isRunning
        if !exited { process.terminate() }
        return exited
    }

    private static func waitForCard(_ store: AgentSessionStore) async {
        for _ in 0..<60 where store.pending.isEmpty { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func allowIsPrintedOnTheHooksStdout() async throws {
        let path = Self.path()
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: path))
        store.start()
        defer { store.stop() }

        let (process, output) = try Self.startHook(path)
        await Self.waitForCard(store)
        try #require(store.pending.count == 1)
        #expect(store.pending[0].detail == "ls")
        store.respond(to: store.pending[0], .allow)

        let exited = await Self.finish(process)
        #expect(exited, "nc did not exit after the answer")
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decision = (root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow")
        #expect(process.terminationStatus == 0)
    }

    @Test func stoppingTheServerLeavesTheHookSilent() async throws {
        let path = Self.path()
        let store = AgentSessionStore(socketURL: URL(fileURLWithPath: path))
        store.start()

        let (process, output) = try Self.startHook(path)
        await Self.waitForCard(store)
        try #require(store.pending.count == 1)
        store.stop()

        let exited = await Self.finish(process)
        #expect(exited, "nc did not exit when the server stopped")
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
