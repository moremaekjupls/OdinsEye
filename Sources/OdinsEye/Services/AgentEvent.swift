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

    /// Сколько символов текста из чужого JSON доходит до панели.
    static let maxText = 200
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
            toolName: wire.tool_name.map(clip)
        )
    }

    private static func clip(_ text: String) -> String {
        text.count > maxText ? String(text.prefix(maxText)) : text
    }
}
