import Foundation

/// Одно событие хука Claude Code, как оно приходит в сокет.
///
/// Входящее — это данные от любого процесса того же пользователя, поэтому
/// всё необязательное необязательно, лишние поля игнорируются, а текст
/// обрезается: ничего отсюда не исполняется и не пишется на диск.
struct AgentEvent: Equatable, Sendable {
    let name: String
    let sessionID: String
    let cwd: String?
    let toolName: String?
    /// Только у `PermissionRequest`.
    let permission: Permission?

    init(name: String, sessionID: String, cwd: String?, toolName: String?, permission: Permission? = nil) {
        self.name = name
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.permission = permission
    }

    /// То, что нужно показать в карточке разрешения.
    struct Permission: Equatable, Sendable {
        let tool: String
        /// Команда, путь или адрес — то, о чём просят разрешение.
        let detail: String
        /// `false`, если `detail` обрезан: одобрять то, чего не видно целиком,
        /// нельзя, и карточка предлагает ответить в терминале.
        let isComplete: Bool
        /// Правило «разрешать всегда», как его предложил Claude Code, уже с
        /// областью `session`. `nil`, если предложений нет.
        let suggestion: Data?
    }

    /// Сколько символов текста из чужого JSON доходит до панели.
    static let maxText = 200
    /// Сколько знаков команды показывает карточка разрешения. Длиннее — не
    /// одобряется отсюда.
    static let maxDetail = 4000
    /// Больше этого сообщение не читается вовсе.
    static let maxBytes = 256 * 1024

    private struct Wire: Decodable {
        let hook_event_name: String?
        let session_id: String?
        let cwd: String?
        let tool_name: String?
    }

    /// `nil`, если это не JSON хука или в нём нет имени события и сессии.
    static func parse(_ data: Data) -> AgentEvent? {
        guard data.count <= maxBytes,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let name = wire.hook_event_name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let id = wire.session_id?.trimmingCharacters(in: .whitespaces), !id.isEmpty
        else { return nil }
        return AgentEvent(
            name: clip(name),
            sessionID: clip(id),
            cwd: wire.cwd.map(clip),
            toolName: wire.tool_name.map(clip),
            permission: name == "PermissionRequest" ? permission(in: data) : nil
        )
    }

    /// Разбор полезной нагрузки `PermissionRequest`: имя инструмента, что
    /// именно просят сделать, и предложенное правило.
    private static func permission(in data: Data) -> Permission? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tool = root["tool_name"] as? String, !tool.isEmpty
        else { return nil }
        let input = root["tool_input"] as? [String: Any] ?? [:]
        let full = describe(tool: tool, input: input)
        let complete = full.count <= maxDetail
        return Permission(
            tool: clip(tool),
            detail: complete ? full : String(full.prefix(maxDetail)),
            isComplete: complete,
            suggestion: sessionRule(from: root["permission_suggestions"])
        )
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            if let command = input["command"] as? String { return command }
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let path = input["file_path"] as? String ?? input["notebook_path"] as? String { return path }
        case "WebFetch":
            if let url = input["url"] as? String { return url }
        case "WebSearch":
            if let query = input["query"] as? String { return query }
        default:
            break
        }
        // Остальное — как есть, ключи по порядку: чтобы не прятать аргументы.
        guard !input.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: json, encoding: .utf8)
        else { return "—" }
        return text
    }

    /// Первое предложенное правило `addRules`, с областью, суженной до
    /// сессии: «всегда» из чёлки не должно писать в настройки на диске.
    private static func sessionRule(from raw: Any?) -> Data? {
        guard let list = raw as? [[String: Any]],
              var rule = list.first(where: { ($0["type"] as? String) == "addRules" })
        else { return nil }
        rule["destination"] = "session"
        return try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys])
    }

    private static func clip(_ text: String) -> String {
        text.count > maxText ? String(text.prefix(maxText)) : text
    }
}
