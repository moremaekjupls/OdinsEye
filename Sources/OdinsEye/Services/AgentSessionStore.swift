import Combine
import Foundation

/// Сессия Claude Code, как её видно в чёлке.
struct AgentSession: Identifiable, Equatable, Sendable {
    enum State: Int, Comparable, Sendable {
        case idle, finished, thinking, working, waiting

        static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    var project: String
    var state: State
    var tool: String?
    var updatedAt: Date
}

/// Запрос разрешения от Claude Code, ждущий ответа в чёлке.
struct PendingPermission: Identifiable, Sendable {
    let id = UUID()
    let sessionID: String
    let project: String
    let tool: String
    let detail: String
    let isComplete: Bool
    let suggestion: Data?
    let receivedAt: Date
    let reply: AgentReply

    /// Одобрять можно только то, что показано целиком.
    var canAllow: Bool { isComplete }
    var canAlways: Bool { isComplete && suggestion != nil }
}

enum PermissionDecision: Sendable {
    case allow, allowForSession, deny
}

/// Состояния сессий по событиям хуков.
///
/// Логика — в `apply`, без сокета и без часов: время приходит параметром, и
/// тест проверяет переходы, не дожидаясь пяти секунд. Сокет — отдельно, в
/// `AgentSocketServer`; здесь он только подключён.
///
/// В простое стор ничего не делает: ни опроса, ни таймера. Единственный
/// таймер — разовый, на пять секунд после `Stop`.
@MainActor
final class AgentSessionStore: ObservableObject {
    /// Свежие сверху.
    @Published private(set) var sessions: [AgentSession] = []
    /// Запросы разрешения, ждущие кнопки. Старые первыми: отвечать по порядку.
    @Published private(set) var pending: [PendingPermission] = []

    /// Сколько «закончил» горит, прежде чем стать «свободен».
    static let finishedLinger: TimeInterval = 5
    /// Сколько хук ждёт кнопку. Дольше нельзя: пока он ждёт, Claude Code
    /// стоит. По истечении ответа нет, и Claude Code спрашивает в терминале.
    /// Хук в `settings.json` ждёт чуть дольше (`timeout`, `nc -w`).
    static let holdLimit: TimeInterval = 110
    /// Сессия, от которой нет событий дольше, считается брошенной.
    static let staleAfter: TimeInterval = 6 * 3600

    /// Имя каждого принятого события — для того, кто хочет отреагировать на
    /// него сразу, а не на итоговое состояние (аватар).
    let events = PassthroughSubject<String, Never>()

    private let server: AgentSocketServer
    private var settleTask: Task<Void, Never>?

    init(socketURL: URL = Support.file("agents.sock")) {
        server = AgentSocketServer(path: socketURL.path)
    }

    /// Самое «срочное» состояние среди сессий — для значка вкладки.
    var worst: AgentSession.State? { sessions.map(\.state).max() }
    var hasPending: Bool { !pending.isEmpty }

    func start() {
        server.start(
            expectsReply: { AgentEvent.parse($0)?.name == "PermissionRequest" },
            onMessage: { [weak self] data, reply in
                Task { @MainActor in self?.receive(data, reply: reply) }
            }
        )
    }

    func stop() {
        server.stop()
        settleTask?.cancel()
        sessions.removeAll()
        // Хук, ждущий кнопку, не должен висеть из-за выключенной вкладки:
        // закрытый пустым, он отдаёт вопрос терминалу.
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.reply.send(nil) }
    }

    /// `reply` есть только у запроса разрешения. Без решения он закрывается
    /// пустым — для Claude Code это «решения нет», то есть вопрос в терминале.
    func receive(_ data: Data, reply: AgentReply? = nil) {
        guard let event = AgentEvent.parse(data) else { reply?.send(nil); return }
        apply(event)
        guard event.name == "PermissionRequest" else { reply?.send(nil); return }
        guard let reply, let request = event.permission else { reply?.send(nil); return }
        hold(request, for: event, reply: reply)
    }

    private func hold(_ request: AgentEvent.Permission, for event: AgentEvent, reply: AgentReply) {
        let item = PendingPermission(
            sessionID: event.sessionID, project: Self.project(of: event.cwd), tool: request.tool,
            detail: request.detail, isComplete: request.isComplete, suggestion: request.suggestion,
            receivedAt: Date(), reply: reply
        )
        pending.append(item)
        let id = item.id
        reply.whenFinished { [weak self] in
            Task { @MainActor in self?.pending.removeAll { $0.id == id } }
        }
        reply.expire(after: Self.holdLimit)
    }

    /// Ответ кнопкой. Идемпотентен: второй раз ничего не делает.
    func respond(to item: PendingPermission, _ decision: PermissionDecision) {
        guard pending.contains(where: { $0.id == item.id }) else { return }
        pending.removeAll { $0.id == item.id }
        switch decision {
        case .allow where item.canAllow: item.reply.send(Self.response(.allow, suggestion: nil))
        case .allowForSession where item.canAlways: item.reply.send(Self.response(.allowForSession, suggestion: item.suggestion))
        case .deny: item.reply.send(Self.response(.deny, suggestion: nil))
        default: item.reply.send(nil)
        }
        if let index = sessions.firstIndex(where: { $0.id == item.sessionID }) {
            sessions[index].state = decision == .deny ? .thinking : .working
            sessions[index].updatedAt = Date()
            sessions.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    /// То, что хук печатает в stdout: формат из документации Claude Code
    /// (`hookSpecificOutput.decision`).
    static func response(_ decision: PermissionDecision, suggestion: Data?) -> Data {
        var body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .allowForSession:
            body = ["behavior": "allow"]
            if let suggestion, let rule = try? JSONSerialization.jsonObject(with: suggestion) {
                body["updatedPermissions"] = [rule]
            }
        case .deny:
            body = ["behavior": "deny", "message": "Denied by the user in Odin's Eye."]
        }
        let root: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    func apply(_ event: AgentEvent, now: Date = Date()) {
        sessions.removeAll { now.timeIntervalSince($0.updatedAt) > Self.staleAfter }

        // Сессия пошла дальше — значит, на запрос ответили в терминале.
        // Хук закрываем без решения; кнопка в чёлке больше не нужна.
        if Self.movesOn.contains(event.name) {
            for item in pending where item.sessionID == event.sessionID { item.reply.send(nil) }
        }

        if event.name == "SessionEnd" {
            sessions.removeAll { $0.id == event.sessionID }
            return
        }
        guard let state = Self.state(for: event) else { return }

        // Событие от сессии, начавшейся до запуска приложения, создаёт её:
        // ждать `SessionStart` незачем.
        let index = sessions.firstIndex { $0.id == event.sessionID } ?? {
            sessions.append(AgentSession(
                id: event.sessionID, project: Self.project(of: event.cwd),
                state: .idle, tool: nil, updatedAt: now
            ))
            return sessions.count - 1
        }()

        sessions[index].state = state
        sessions[index].updatedAt = now
        if let cwd = event.cwd { sessions[index].project = Self.project(of: cwd) }
        switch event.name {
        case "PreToolUse": sessions[index].tool = event.toolName
        case "UserPromptSubmit", "Stop", "SessionStart": sessions[index].tool = nil
        default: break
        }

        sessions.sort { $0.updatedAt > $1.updatedAt }
        if state == .finished { scheduleSettle(from: now) }
        events.send(event.name)
    }

    /// «Закончил» старше пяти секунд становится «свободен».
    func settleFinished(now: Date = Date()) {
        for index in sessions.indices
        where sessions[index].state == .finished
            && now.timeIntervalSince(sessions[index].updatedAt) >= Self.finishedLinger {
            sessions[index].state = .idle
        }
    }

    private func scheduleSettle(from now: Date) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedLinger))
            guard !Task.isCancelled else { return }
            self?.settleFinished(now: now.addingTimeInterval(Self.finishedLinger))
        }
    }

    private static let movesOn: Set<String> = ["UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd"]

    static func state(for event: AgentEvent) -> AgentSession.State? {
        switch event.name {
        case "SessionStart": return .idle
        case "UserPromptSubmit": return .thinking
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop": return .working
        case "Notification", "PermissionRequest": return .waiting
        case "Stop": return .finished
        default: return nil
        }
    }

    /// Имя проекта — последний компонент рабочей папки.
    static func project(of cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}
