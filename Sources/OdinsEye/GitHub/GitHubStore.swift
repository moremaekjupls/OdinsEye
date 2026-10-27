import Foundation

/// Состояние публичных репозиториев GitHub: открытые PR, ревью и статус CI.
///
/// **Без токена.** Только публичные репозитории, анонимный API: 60 запросов в
/// час на адрес. Поэтому весь код здесь подчинён бюджету:
/// - обновление стоит 2 запроса на репозиторий (список PR и последний запуск
///   CI), плюс один при первой загрузке (основная ветка);
/// - ревью запрашиваются только для PR, у которых изменился `updated_at`:
///   отправленное ревью его меняет, так что новое видно, а старое не
///   перезапрашивается;
/// - интервал не короче 10 минут и растёт с числом репозиториев (200 с на
///   каждый), открытие вкладки обновляет не чаще раза в 5 минут;
/// - при остатке меньше `reserve` запросы прекращаются до сброса окна, а в
///   панели видно, до какого часа.
/// `If-None-Match` оставлен ради трафика: 304 квоту не бережёт (проверено).
@MainActor
final class GitHubStore: ObservableObject {
    enum Status: Equatable {
        case idle, loading, offline
        case rateLimited(until: Date)
    }

    @Published private(set) var repos: [RepoState] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var remaining: Int?

    static let maxRepos = 8
    /// Столько запросов остаётся про запас: на ручное обновление и сбои.
    static let reserve = 6
    static let minInterval: TimeInterval = 600
    static let staleAfter: TimeInterval = 300
    static let reviewsPerRepo = 6

    private enum Stop: Error { case limited }

    private let client: GitHubFetching
    private let now: () -> Date
    private let save: ([String]) -> Void
    private var names: [String]
    private var etags: [String: (etag: String, data: Data)] = [:]
    private var branches: [String: String] = [:]
    private var reviews: [String: ReviewState] = [:]
    private var resetAt: Date?
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var dirty = false

    init(
        client: GitHubFetching = GitHubClient(), names: [String]? = nil,
        save: (([String]) -> Void)? = nil, now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.now = now
        let initial = names ?? ConfigStore.shared.githubRepos
        self.names = initial
        self.save = save ?? { ConfigStore.shared.githubRepos = $0 }
        repos = initial.map { RepoState(fullName: $0) }
    }

    // MARK: - Расписание

    static func interval(forRepos count: Int) -> TimeInterval {
        max(minInterval, 200 * Double(max(1, count)))
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let count = self?.names.count ?? 1
                try? await Task.sleep(for: .seconds(Self.interval(forRepos: count)))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Открытие вкладки: обновить, если данные старше пяти минут.
    func refreshIfNeeded() {
        if let last = lastRefresh, now().timeIntervalSince(last) < Self.staleAfter { return }
        guard !refreshing else { return }
        Task { await refresh() }
    }

    /// Кнопка обновления: не чаще раза в минуту, чтобы не сжечь квоту.
    func refreshNow() {
        if let last = lastRefresh, now().timeIntervalSince(last) < 60 { return }
        Task { await refresh() }
    }

    // MARK: - Список репозиториев

    enum AddResult: Equatable { case added(String), invalid, duplicate, tooMany }

    /// Из буфера обмена: ссылка на репозиторий или `owner/name`.
    @discardableResult
    func add(from text: String) -> AddResult {
        guard let name = GitHubParsing.repoName(from: text) else { return .invalid }
        guard !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return .duplicate }
        guard names.count < Self.maxRepos else { return .tooMany }
        names.append(name)
        repos.append(RepoState(fullName: name))
        save(names)
        dirty = true
        Task { await refresh() }
        return .added(name)
    }

    func remove(_ name: String) {
        names.removeAll { $0 == name }
        repos.removeAll { $0.fullName == name }
        save(names)
    }

    var totalPulls: Int { repos.reduce(0) { $0 + $1.pulls.count } }
    var hasFailingCI: Bool { repos.contains { $0.ci == .failing } }

    // MARK: - Обновление

    func refresh() async {
        guard !refreshing else { return }
        if let until = limitedUntil() {
            status = .rateLimited(until: until)
            return
        }
        refreshing = true
        defer { refreshing = false }
        status = .loading

        var limited = false, offline = false
        for name in names {
            do { try await load(name) }
            catch Stop.limited { limited = true; break }
            catch { offline = true; mark(name, error: localized("No connection")) }
        }
        lastRefresh = now()
        if limited { status = .rateLimited(until: resetAt ?? now().addingTimeInterval(900)) }
        else { status = offline ? .offline : .idle }

        // Репозиторий добавили, пока шло обновление: он не попал в список.
        if dirty { dirty = false; await refresh() }
    }

    /// Лимит исчерпан и окно ещё не сбросилось.
    private func limitedUntil() -> Date? {
        guard let remaining, remaining < Self.reserve else { return nil }
        guard let reset = resetAt, reset > now() else {
            self.remaining = nil
            return nil
        }
        return reset
    }

    private func request(_ path: String) async throws -> GitHubResponse {
        if limitedUntil() != nil { throw Stop.limited }
        let cached = etags[path]
        let response = try await client.get(path, etag: cached?.etag)
        if let r = response.remaining { remaining = r }
        if let reset = response.reset { resetAt = reset }
        if response.status == 403 || response.status == 429 {
            // Лимит (первичный или вторичный): дальше не идём.
            remaining = 0
            if resetAt == nil || resetAt! <= now() { resetAt = now().addingTimeInterval(900) }
            throw Stop.limited
        }
        if response.status == 304, let cached {
            return GitHubResponse(status: 200, data: cached.data, etag: cached.etag, remaining: response.remaining, reset: response.reset)
        }
        if response.status == 200, let tag = response.etag { etags[path] = (tag, response.data) }
        return response
    }

    private func load(_ name: String) async throws {
        if branches[name] == nil {
            let info = try await request("/repos/\(name)")
            guard info.status == 200, let repo = try? JSONDecoder().decode(GitHubWire.Repo.self, from: info.data) else {
                mark(name, error: info.status == 404 ? localized("Not found or private") : "HTTP \(info.status)")
                return
            }
            branches[name] = repo.default_branch
            update(name) { $0.defaultBranch = repo.default_branch }
        }
        guard let branch = branches[name] else { return }

        let list = try await request("/repos/\(name)/pulls?state=open&per_page=30")
        guard list.status == 200, let wires = try? JSONDecoder().decode([GitHubWire.Pull].self, from: list.data) else {
            mark(name, error: "HTTP \(list.status)")
            return
        }

        var pulls: [PullState] = []
        var fetched = 0
        for wire in wires {
            let key = "\(name)#\(wire.number)@\(wire.updated_at ?? "")"
            var review = reviews[key] ?? .unknown
            if review == .unknown, fetched < Self.reviewsPerRepo {
                fetched += 1
                let response = try await request("/repos/\(name)/pulls/\(wire.number)/reviews?per_page=100")
                if response.status == 200, let list = try? JSONDecoder().decode([GitHubWire.Review].self, from: response.data) {
                    review = GitHubParsing.review(from: list)
                    reviews[key] = review
                }
            }
            pulls.append(GitHubParsing.pull(wire, review: review))
        }

        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        let runs = try await request("/repos/\(name)/actions/runs?branch=\(encoded)&per_page=1")
        var ci: (state: CIState, name: String?, url: URL?) = (.unknown, nil, nil)
        if runs.status == 200, let decoded = try? JSONDecoder().decode(GitHubWire.Runs.self, from: runs.data) {
            ci = GitHubParsing.ci(from: decoded.workflow_runs)
        }

        update(name) {
            $0.pulls = pulls
            ($0.ci, $0.ciName, $0.ciURL) = ci
            $0.fetchedAt = now()
            $0.error = nil
        }
    }

    private func update(_ name: String, _ change: (inout RepoState) -> Void) {
        guard let index = repos.firstIndex(where: { $0.fullName == name }) else { return }
        change(&repos[index])
    }

    private func mark(_ name: String, error: String) {
        update(name) { $0.error = error }
    }
}
