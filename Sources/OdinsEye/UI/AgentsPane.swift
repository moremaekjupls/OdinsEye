import SwiftUI

/// Сессии Claude Code: проект, что делает, как давно.
struct AgentsPane: View {
    @ObservedObject var agents: AgentSessionStore

    var body: some View {
        if agents.sessions.isEmpty {
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
                LazyVStack(spacing: 3) {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface)
        )
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return localized("now") }
        if seconds < 3600 { return localized("%d min", Int(seconds / 60)) }
        return localized("%d h", Int(seconds / 3600))
    }

    private var detail: String {
        if session.state == .working, let tool = session.tool { return tool }
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
