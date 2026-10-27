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

    /// Сколько «закончил» горит, прежде чем стать «свободен».
    static let finishedLinger: TimeInterval = 5
    /// Сессия, от которой нет событий дольше, считается брошенной.
    static let staleAfter: TimeInterval = 6 * 3600

    private let server: AgentSocketServer
    private var settleTask: Task<Void, Never>?

    init(socketURL: URL = Support.file("agents.sock")) {
        server = AgentSocketServer(path: socketURL.path)
    }

    /// Самое «срочное» состояние среди сессий — для значка вкладки.
    var worst: AgentSession.State? { sessions.map(\.state).max() }

    func start() {
        server.start { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
    }

    func stop() {
        server.stop()
        settleTask?.cancel()
        sessions.removeAll()
    }

    func receive(_ data: Data) {
        guard let event = AgentEvent.parse(data) else { return }
        apply(event)
    }

    func apply(_ event: AgentEvent, now: Date = Date()) {
        sessions.removeAll { now.timeIntervalSince($0.updatedAt) > Self.staleAfter }

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

    static func state(for event: AgentEvent) -> AgentSession.State? {
        switch event.name {
        case "SessionStart": return .idle
        case "UserPromptSubmit": return .thinking
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop": return .working
        case "Notification": return .waiting
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
