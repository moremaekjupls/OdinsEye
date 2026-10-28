import SwiftUI

/// Сессии Claude Code: проект, что делает, как давно.
struct AgentsPane: View {
    @ObservedObject var agents: AgentSessionStore
    @ObservedObject var avatar: AvatarModel

    var body: some View {
        HStack(spacing: 12) {
            // Большой Peeky: в панели он тот же, что в «ухе», с тем же настроением.
            if let engine = avatar.engine {
                PeekyView(engine: engine, screenAnchor: avatar.panelAnchor, isRunning: true, bodySide: 96, bottomInset: 6)
                    .frame(width: 112)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let request = agents.pending.first {
            PermissionCard(request: request, more: agents.pending.count - 1) { decision in
                agents.respond(to: request, decision)
            }
            .id(request.id)
        } else if agents.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 22, weight: .light))
                Text("No Claude Code sessions")
                    .font(.panelCaption)
            }
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    ForEach(agents.sessions) { session in
                        AgentRow(session: session)
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.top, 2)
        }
    }
}

struct AgentRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 7, height: 7)
                    .frame(width: 16)
                Text(session.project)
                    .font(.panelBodyMedium)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Раз в минуту, а не каждую секунду, как `.relative`: панель
                // открыта подолгу, и тикающие секунды — это перерисовка впустую.
                TimelineView(.everyMinute) { context in
                    Text(Self.ago(session.updatedAt, now: context.date))
                        .font(.panelCaption.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }

            if let prompt = session.prompt {
                line("person.fill", prompt, color: Theme.secondary)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                line(index == steps.count - 1 && session.state == .working ? "arrow.right" : "checkmark",
                     step, color: Theme.tertiary, mono: true)
            }
            if !session.files.isEmpty {
                line("doc.badge.ellipsis", filesText, color: Theme.tertiary)
            }
            if let reply = session.reply, session.state != .thinking, session.state != .working {
                Text(reply)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(3)
                    .padding(.leading, 25)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface)
        )
    }

    private func line(_ symbol: String, _ text: String, color: Color, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8))
                .frame(width: 12)
            Text(text)
                .font(mono ? .system(size: 10.5, design: .monospaced) : .panelCaption)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.leading, 13)
    }

    /// Ход короче трёх шагов показывает всё, длиннее — три последних.
    private var steps: [String] { Array(session.steps.suffix(3)) }

    private var filesText: String {
        let shown = session.files.prefix(3).joined(separator: ", ")
        let rest = session.files.count - 3
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return localized("now") }
        if seconds < 3600 { return localized("%d min", Int(seconds / 60)) }
        return localized("%d h", Int(seconds / 3600))
    }

    private var detail: String {
        if session.state == .working, let step = session.step ?? session.tool { return step }
        return session.state.title
    }
}

extension AgentSession.State {
    var title: String {
        switch self {
        case .idle: return localized("Idle")
        case .finished: return localized("Done")
        case .thinking: return localized("Thinking")
        case .working: return localized("Working")
        case .waiting: return localized("Waiting for you")
        }
    }

    var color: Color {
        switch self {
        case .idle: return Theme.tertiary
        case .finished: return .green
        case .thinking, .working: return .blue
        case .waiting: return .orange
        }
    }
}

/// Запрос разрешения: что просят, и три кнопки. Одна карточка за раз, чтобы
/// влезть в панель; остальные ждут за ней.
struct PermissionCard: View {
    let request: PendingPermission
    let more: Int
    let answer: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text(request.tool)
                    .font(.panelBodyMedium)
                    .foregroundStyle(Theme.primary)
                Text(request.project)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if more > 0 {
                    Text("+\(more)")
                        .font(.panelCaptionMedium.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }

            // Команда целиком и моноширинным: от того, что видно, зависит,
            // что человек разрешает.
            ScrollView(showsIndicators: true) {
                Text(request.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .frame(maxHeight: .infinity)

            if request.isComplete {
                HStack(spacing: 8) {
                    Button("Deny") { answer(.deny) }
                        .buttonStyle(.plate)
                    Spacer(minLength: 6)
                    if request.canAlways {
                        Button("Always this session") { answer(.allowForSession) }
                            .buttonStyle(.plate)
                    }
                    Button("Allow") { answer(.allow) }
                        .buttonStyle(.plate)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Too long to review here. Answer in the terminal.")
                        .font(.panelCaption)
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 6)
                    Button("Deny") { answer(.deny) }
                        .buttonStyle(.plate)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
    }
}
