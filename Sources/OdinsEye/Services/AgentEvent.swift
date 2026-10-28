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
    /// Что делает инструмент, коротко: «Bash npm test», «Edit Invoice.swift».
    /// Только у `PreToolUse`.
    let step: String?
    /// Что человек спросил. Только у `UserPromptSubmit`.
    let prompt: String?
    /// Последний ответ агента. Только у `Stop`.
    let reply: String?
    /// Имя файла, который правят: `Edit`, `Write`, `MultiEdit`, `NotebookEdit`.
    let file: String?

    init(name: String, sessionID: String, cwd: String?, toolName: String?, permission: Permission? = nil, step: String? = nil,
         prompt: String? = nil, reply: String? = nil, file: String? = nil) {
        self.name = name
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.permission = permission
        self.step = step
        self.prompt = prompt
        self.reply = reply
        self.file = file
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
        let prompt: String?
        let last_assistant_message: String?
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
            permission: name == "PermissionRequest" ? permission(in: data) : nil,
            step: name == "PreToolUse" ? step(in: data, tool: wire.tool_name) : nil,
            prompt: name == "UserPromptSubmit" ? wire.prompt.flatMap(oneLine) : nil,
            reply: name == "Stop" ? wire.last_assistant_message.flatMap(oneLine) : nil,
            file: name == "PreToolUse" ? editedFile(in: data, tool: wire.tool_name) : nil
        )
    }

    /// Сколько знаков ответа и вопроса доходит до панели.
    static let maxMessage = 400

    /// Текст в одну строку с пробелами по краям убранными, обрезанный.
    private static func oneLine(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > maxMessage ? String(flat.prefix(maxMessage - 1)) + "…" : flat
    }

    private static func editedFile(in data: Data, tool: String?) -> String? {
        guard let tool, ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let input = root["tool_input"] as? [String: Any],
              let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : clip(name)
    }

    /// Короткая строка для ленты: инструмент и его цель.
    private static func step(in data: Data, tool: String?) -> String? {
        guard let tool, !tool.isEmpty else { return nil }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let input = root?["tool_input"] as? [String: Any] ?? [:]
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        let target: String?
        switch tool {
        case "Bash": target = (input["command"] as? String)?.split(separator: "\n").first.map(String.init)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            target = (input["file_path"] as? String ?? input["notebook_path"] as? String).map(name)
        case "Grep", "Glob": target = input["pattern"] as? String
        case "WebFetch": target = (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch": target = input["query"] as? String
        default: target = nil
        }
        let text = [tool, target?.trimmingCharacters(in: .whitespaces)].compactMap { $0 }.joined(separator: " ")
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
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
