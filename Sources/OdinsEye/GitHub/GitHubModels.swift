import Foundation

enum CIState: Equatable, Sendable {
    case passing, failing, running
    /// Запусков нет: у репозитория нет CI.
    case none
    /// Последний запуск отменён, пропущен или нейтрален.
    case unknown
}

enum ReviewState: Equatable, Sendable {
    /// Ещё не смотрели или не успели загрузить.
    case unknown
    case needsReview, approved, changesRequested
}

struct PullState: Identifiable, Equatable, Sendable {
    let number: Int
    let title: String
    let author: String
    let isDraft: Bool
    let isBot: Bool
    let updatedAt: Date?
    let url: URL?
    var review: ReviewState

    var id: Int { number }
}

struct RepoState: Identifiable, Equatable, Sendable {
    let fullName: String
    var defaultBranch: String?
    var ci: CIState = .unknown
    var ciName: String?
    var ciURL: URL?
    var pulls: [PullState] = []
    var fetchedAt: Date?
    /// Короткая причина, если репозиторий не загрузился.
    var error: String?

    var id: String { fullName }
    var owner: String { String(fullName.split(separator: "/").first ?? "") }
    var name: String { String(fullName.split(separator: "/").last ?? "") }
    var url: URL? { URL(string: "https://github.com/\(fullName)") }
}

// MARK: - Разбор ответов

/// Структуры ответа GitHub: только нужные поля.
enum GitHubWire {
    struct User: Decodable { let login: String; let type: String? }
    struct Pull: Decodable {
        let number: Int
        let title: String
        let draft: Bool?
        let html_url: String
        let updated_at: String?
        let user: User
        let requested_reviewers: [User]?
    }
    struct Review: Decodable { let user: User?; let state: String }
    struct Runs: Decodable { let workflow_runs: [Run] }
    struct Run: Decodable {
        let name: String?
        let status: String?
        let conclusion: String?
        let html_url: String?
    }
    struct Repo: Decodable { let default_branch: String }
}

enum GitHubParsing {
    /// Состояние CI по последнему запуску на основной ветке.
    static func ci(from runs: [GitHubWire.Run]) -> (state: CIState, name: String?, url: URL?) {
        guard let run = runs.first else { return (.none, nil, nil) }
        let url = run.html_url.flatMap(URL.init(string:))
        guard run.status == "completed" else { return (.running, run.name, url) }
        switch run.conclusion {
        case "success": return (.passing, run.name, url)
        case "failure", "timed_out", "startup_failure": return (.failing, run.name, url)
        default: return (.unknown, run.name, url)
        }
    }

    /// Итог ревью: по последнему слову каждого ревьюера. Комментарий состояния
    /// не меняет, снятое ревью (`DISMISSED`) забывается.
    static func review(from reviews: [GitHubWire.Review]) -> ReviewState {
        var latest: [String: String] = [:]
        for review in reviews {
            guard let login = review.user?.login else { continue }
            switch review.state {
            case "APPROVED", "CHANGES_REQUESTED": latest[login] = review.state
            case "DISMISSED": latest[login] = nil
            default: break          // COMMENTED, PENDING
            }
        }
        if latest.values.contains("CHANGES_REQUESTED") { return .changesRequested }
        if latest.values.contains("APPROVED") { return .approved }
        return .needsReview
    }

    static func pull(_ wire: GitHubWire.Pull, review: ReviewState) -> PullState {
        PullState(
            number: wire.number, title: wire.title, author: wire.user.login,
            isDraft: wire.draft ?? false, isBot: wire.user.type == "Bot",
            updatedAt: wire.updated_at.flatMap { try? Date($0, strategy: .iso8601) },
            url: URL(string: wire.html_url), review: review
        )
    }

    /// `owner/name` из того, что человек скопировал: ссылка на репозиторий,
    /// ссылка на PR или сама пара. `nil`, если на репозиторий не похоже.
    static func repoName(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)); break
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        for part in [owner, name] {
            guard !part.isEmpty, part.count <= 100, part.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        }
        // Имя из одних точек это путь вверх, а не репозиторий; у владельца
        // первый знак буква или цифра (репозиторий вроде `.github` бывает).
        guard name != ".", name != "..", owner.first?.isLetter == true || owner.first?.isNumber == true else { return nil }
        return "\(owner)/\(name)"
    }
}
