import AppKit
import SwiftUI

/// Публичные репозитории GitHub: у каждого строка с CI основной ветки и числом
/// открытых PR, под ней сами PR с итогом ревью. Клик открывает страницу в
/// браузере. Репозиторий добавляется кнопкой «+» из буфера обмена: скопировали
/// ссылку в браузере, нажали. Поле ввода здесь не нужно, а с ним панели
/// пришлось бы забирать клавиатуру.
struct GitHubPane: View {
    @ObservedObject var github: GitHubStore
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            if github.repos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 22, weight: .light))
                    Text("Copy a repository link, then press +")
                        .font(.panelCaption)
                }
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(github.repos) { repo in
                            RepoRow(repo: repo) { github.remove(repo.fullName) }
                            ForEach(repo.pulls) { pull in
                                PullRow(pull: pull)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            footer
        }
        .padding(.top, 2)
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusLine)
                .font(.panelCaption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button { github.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.secondary)
            .help(localized("Refresh"))
            Button(action: addFromClipboard) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.secondary)
            .help(localized("Add repository from clipboard"))
        }
        .padding(.top, 2)
    }

    private var statusLine: String {
        if let notice { return notice }
        switch github.status {
        case .loading: return localized("Loading…")
        case .offline: return localized("Offline")
        case .rateLimited(let until):
            return localized("Rate limit reached, retry at %@", until.formatted(date: .omitted, time: .shortened))
        case .idle:
            guard let last = github.lastRefresh else { return "" }
            let age = AgentRow.ago(last, now: Date())
            if let left = github.remaining { return localized("Updated %@ · %d requests left", age, left) }
            return localized("Updated %@", age)
        }
    }

    private func addFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        switch github.add(from: text) {
        case .added(let name): show(localized("Added %@", name))
        case .invalid: show(localized("That is not a GitHub repository link"))
        case .duplicate: show(localized("Already in the list"))
        case .tooMany: show(localized("Up to 8 repositories"))
        }
    }

    private func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }
}

// MARK: - Строки

struct RepoRow: View {
    let repo: RepoState
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 16)
            Text(repo.name)
                .font(.panelBodyMedium)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Text(repo.owner)
                .font(.panelCaption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let error = repo.error {
                Text(error).font(.panelCaption).foregroundStyle(Theme.secondary).lineLimit(1)
            } else {
                GitHubPill(text: ciText, color: ciColor)
                    .help(repo.ciName ?? "")
                GitHubPill(text: localized("%d PR", repo.pulls.count), color: Theme.tertiary)
            }
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.secondary)
                .help(localized("Remove"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.surfaceHover : Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { if let url = repo.ciURL ?? repo.url { NSWorkspace.shared.open(url) } }
    }

    private var ciText: String {
        switch repo.ci {
        case .passing: return localized("passing")
        case .failing: return localized("failing")
        case .running: return localized("running")
        case .none: return localized("no CI")
        case .unknown: return localized("CI ?")
        }
    }

    private var ciColor: Color {
        switch repo.ci {
        case .passing: return .green
        // Красный только для ошибок: сломанная сборка на основной ветке.
        case .failing: return Color(red: 0.91, green: 0.0, blue: 0.04)
        case .running: return .blue
        case .none, .unknown: return Theme.tertiary
        }
    }
}

struct PullRow: View {
    let pull: PullState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("#\(pull.number)")
                .font(.panelCaption.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 34, alignment: .trailing)
            Text(pull.title)
                .font(.panelBody)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Text(pull.author.replacingOccurrences(of: "[bot]", with: ""))
                .font(.panelCaption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if pull.isDraft { GitHubPill(text: localized("draft"), color: Theme.tertiary) }
            switch pull.review {
            case .unknown: EmptyView()
            case .needsReview: GitHubPill(text: localized("needs review"), color: .blue)
            case .approved: GitHubPill(text: localized("approved"), color: .green)
            case .changesRequested: GitHubPill(text: localized("changes"), color: .orange)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.surface : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { if let url = pull.url { NSWorkspace.shared.open(url) } }
    }
}

/// Пилюля статуса: точка цвета и короткий текст.
struct GitHubPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.panelMini)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.surface))
    }
}
