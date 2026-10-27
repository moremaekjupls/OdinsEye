import Foundation
import Testing
@testable import OdinsEye

/// Поддельный GitHub: отвечает заготовками и пишет, о чём его спросили.
final class FakeGitHub: GitHubFetching, @unchecked Sendable {
    struct Route { var status = 200; var body = "[]"; var etag: String? }
    private let lock = NSLock()
    private var _log: [(path: String, etag: String?)] = []
    var routes: [String: Route] = [:]
    var remaining: Int? = 50
    var reset: Date? = Date().addingTimeInterval(3000)
    var failure: Error?

    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _log.map(\.path) }
    var log: [(path: String, etag: String?)] { lock.lock(); defer { lock.unlock() }; return _log }
    func clearLog() { lock.lock(); _log = []; lock.unlock() }


    /// Синхронная часть: замок нельзя брать из `async`.
    private func record(_ path: String, _ etag: String?) -> (route: Route?, failure: Error?, remaining: Int?, reset: Date?) {
        lock.lock(); defer { lock.unlock() }
        _log.append((path, etag))
        return (routes[path], failure, remaining, reset)
    }

    func get(_ path: String, etag: String?) async throws -> GitHubResponse {
        let seen = record(path, etag)
        if let failure = seen.failure { throw failure }
        guard let route = seen.route else {
            return GitHubResponse(status: 404, data: Data(), etag: nil, remaining: seen.remaining, reset: seen.reset)
        }
        if let tag = route.etag, tag == etag {
            return GitHubResponse(status: 304, data: Data(), etag: tag, remaining: seen.remaining, reset: seen.reset)
        }
        return GitHubResponse(status: route.status, data: Data(route.body.utf8), etag: route.etag, remaining: seen.remaining, reset: seen.reset)
    }
}

@MainActor
struct GitHubTests {
    // MARK: - Заготовки (форма настоящих ответов api.github.com)

    private static func pull(_ n: Int, _ title: String = "Fix", updated: String = "2026-10-10T08:02:17Z",
                             draft: Bool = false, user: String = "moremaekjupls", type: String = "User") -> String {
        #"{"number":\#(n),"title":"\#(title)","draft":\#(draft),"html_url":"https://github.com/o/r/pull/\#(n)","updated_at":"\#(updated)","user":{"login":"\#(user)","type":"\#(type)"},"requested_reviewers":[]}"#
    }
    private static func review(_ user: String, _ state: String) -> String { #"{"user":{"login":"\#(user)"},"state":"\#(state)"}"# }
    private static let repoInfo = #"{"default_branch":"main","full_name":"o/r"}"#
    private static func runs(_ status: String, _ conclusion: String?) -> String {
        let c = conclusion.map { "\"\($0)\"" } ?? "null"
        return #"{"total_count":1,"workflow_runs":[{"name":"CI","status":"\#(status)","conclusion":\#(c),"html_url":"https://github.com/o/r/actions/runs/1"}]}"#
    }

    private func fake(prs: [String] = [], ci: (String, String?)? = ("completed", "success")) -> FakeGitHub {
        let f = FakeGitHub()
        f.routes["/repos/o/r"] = .init(body: Self.repoInfo)
        f.routes["/repos/o/r/pulls?state=open&per_page=30"] = .init(body: "[" + prs.joined(separator: ",") + "]")
        f.routes["/repos/o/r/actions/runs?branch=main&per_page=1"] = .init(body: ci.map { Self.runs($0.0, $0.1) } ?? #"{"total_count":0,"workflow_runs":[]}"#)
        for n in 1...12 { f.routes["/repos/o/r/pulls/\(n)/reviews?per_page=100"] = .init(body: "[" + Self.review("a", "APPROVED") + "]") }
        return f
    }

    private func store(_ client: FakeGitHub, names: [String] = ["o/r"], now: @escaping () -> Date = Date.init,
                       saved: @escaping ([String]) -> Void = { _ in }) -> GitHubStore {
        GitHubStore(client: client, names: names, save: saved, now: now)
    }

    // MARK: - CI

    @Test func ciFollowsTheLatestRunOnTheDefaultBranch() throws {
        func ci(_ status: String, _ conclusion: String?) throws -> CIState {
            let runs = try JSONDecoder().decode(GitHubWire.Runs.self, from: Data(Self.runs(status, conclusion).utf8))
            return GitHubParsing.ci(from: runs.workflow_runs).state
        }
        #expect(try ci("completed", "success") == .passing)
        #expect(try ci("completed", "failure") == .failing)
        #expect(try ci("completed", "timed_out") == .failing)
        #expect(try ci("in_progress", nil) == .running)
        #expect(try ci("queued", nil) == .running)
        #expect(try ci("completed", "cancelled") == .unknown)
        #expect(GitHubParsing.ci(from: []).state == .none)
    }

    // MARK: - Ревью

    private func reviews(_ items: [(String, String)]) -> ReviewState {
        let wires = items.map { GitHubWire.Review(user: .init(login: $0.0, type: nil), state: $0.1) }
        return GitHubParsing.review(from: wires)
    }

    @Test func reviewStateIsEachReviewersLastWord() {
        #expect(reviews([]) == .needsReview)
        #expect(reviews([("a", "COMMENTED")]) == .needsReview)
        #expect(reviews([("a", "APPROVED")]) == .approved)
        #expect(reviews([("a", "APPROVED"), ("b", "CHANGES_REQUESTED")]) == .changesRequested)
        #expect(reviews([("a", "CHANGES_REQUESTED"), ("a", "APPROVED")]) == .approved, "the same person changed their mind")
        #expect(reviews([("a", "APPROVED"), ("a", "COMMENTED")]) == .approved, "a comment changes nothing")
        #expect(reviews([("a", "CHANGES_REQUESTED"), ("a", "DISMISSED")]) == .needsReview)
    }

    // MARK: - Ссылки

    @Test func aRepositoryIsRecognisedFromWhateverWasCopied() {
        for text in ["moremaekjupls/OdinsEye", "https://github.com/moremaekjupls/OdinsEye", "https://github.com/moremaekjupls/OdinsEye/",
                     "https://github.com/moremaekjupls/OdinsEye.git", "github.com/moremaekjupls/OdinsEye",
                     "git@github.com:moremaekjupls/OdinsEye.git", "https://github.com/moremaekjupls/OdinsEye/pull/4",
                     "  moremaekjupls/OdinsEye\n"] {
            #expect(GitHubParsing.repoName(from: text) == "moremaekjupls/OdinsEye", "\(text)")
        }
    }

    @Test func nonsenseIsNotARepository() {
        let bad = ["", "hello", "owner/", "/name", "./x", "x/..", "-x/y", ".x/y", "a b/c", "../etc/passwd", "o/r?x=1", "o/<script>", "o/r;rm -rf"]
        #expect(GitHubParsing.repoName(from: "a/.github") == "a/.github", "dot-repositories exist")
        for text in bad {
            let name = GitHubParsing.repoName(from: text)
            #expect(name == nil, "\(text) was taken for \(name ?? "nil")")
        }
    }

    // MARK: - Бюджет запросов

    @Test func theFirstLoadCostsRepoPullsReviewsAndRuns() async {
        let client = fake(prs: [Self.pull(1), Self.pull(2), Self.pull(3)])
        let s = store(client)
        await s.refresh()
        let expected: Int = 6                       // repo, pulls, 3 reviews, runs
        let made: Int = client.paths.count
        #expect(made == expected, "requests: \(client.paths)")
        #expect(s.repos[0].pulls.count == 3)
        #expect(s.repos[0].ci == .passing)
        #expect(s.repos[0].pulls.allSatisfy { $0.review == .approved })
        #expect(s.repos[0].defaultBranch == "main")
    }

    @Test func aRepeatCostsOnlyPullsAndRuns() async {
        let client = fake(prs: [Self.pull(1), Self.pull(2), Self.pull(3)])
        let s = store(client)
        await s.refresh()
        client.clearLog()
        await s.refresh()
        let expectedPaths: [String] = ["/repos/o/r/pulls?state=open&per_page=30", "/repos/o/r/actions/runs?branch=main&per_page=1"]
        let madePaths: [String] = client.paths
        #expect(madePaths == expectedPaths)
        #expect(s.repos[0].pulls.allSatisfy { $0.review == .approved }, "reviews are kept, not asked for again")
    }

    @Test func onlyAChangedPullGetsItsReviewsAskedAgain() async {
        let client = fake(prs: [Self.pull(1), Self.pull(2)])
        let s = store(client)
        await s.refresh()
        client.clearLog()
        client.routes["/repos/o/r/pulls?state=open&per_page=30"] = .init(body: "[" + Self.pull(1) + "," + Self.pull(2, updated: "2026-10-12T10:00:00Z") + "]")
        client.routes["/repos/o/r/pulls/2/reviews?per_page=100"] = .init(body: "[" + Self.review("b", "CHANGES_REQUESTED") + "]")
        await s.refresh()
        #expect(client.paths.filter { $0.contains("/reviews") } == ["/repos/o/r/pulls/2/reviews?per_page=100"])
        #expect(s.repos[0].pulls.first { $0.number == 2 }?.review == .changesRequested)
        #expect(s.repos[0].pulls.first { $0.number == 1 }?.review == .approved)
    }

    @Test func reviewRequestsPerRepoAreCapped() async {
        let client = fake(prs: (1...9).map { Self.pull($0) })
        for n in 1...12 { client.routes["/repos/o/r/pulls/\(n)/reviews?per_page=100"] = .init(body: "[]") }
        let s = store(client)
        await s.refresh()
        #expect(client.paths.filter { $0.contains("/reviews") }.count == GitHubStore.reviewsPerRepo)
        #expect(s.repos[0].pulls.count == 9)
        #expect(s.repos[0].pulls.last?.review == .unknown)
    }

    @Test func theIntervalGrowsWithTheNumberOfRepositories() {
        #expect(GitHubStore.interval(forRepos: 1) == 600)
        #expect(GitHubStore.interval(forRepos: 3) == 600)
        #expect(GitHubStore.interval(forRepos: 5) == 1000)
        #expect(GitHubStore.interval(forRepos: 8) == 1600)
        // Бюджет: 2 запроса на репозиторий за обновление в пределах 36 в час.
        for n in 1...8 {
            let interval: Double = GitHubStore.interval(forRepos: n)
            let perHour: Double = 2.0 * Double(n) * 3600.0 / interval
            #expect(perHour <= 36.01, "\(n) repos use \(perHour) requests an hour")
        }
    }

    // MARK: - ETag и лимиты

    @Test func etagIsSentAndANotModifiedAnswerReusesTheData() async {
        let client = fake(prs: [Self.pull(1)])
        client.routes["/repos/o/r/pulls?state=open&per_page=30"] = .init(body: "[" + Self.pull(1) + "]", etag: "W/\"abc\"")
        let s = store(client)
        await s.refresh()
        client.clearLog()
        await s.refresh()
        let sent = client.log.first { $0.path.hasPrefix("/repos/o/r/pulls?") }?.etag
        #expect(sent == "W/\"abc\"")
        #expect(s.repos[0].pulls.count == 1, "304 keeps the list")
    }

    @Test func runningLowStopsTheRequestsUntilTheWindowResets() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let client = fake(prs: [Self.pull(1)])
        client.remaining = 4
        client.reset = clock.addingTimeInterval(1800)
        let s = store(client, now: { clock })
        await s.refresh()
        guard case .rateLimited = s.status else { Issue.record("not limited: \(s.status)"); return }

        client.clearLog()
        await s.refresh()
        #expect(client.paths.isEmpty, "no requests while limited")

        clock = clock.addingTimeInterval(1900)
        client.remaining = 60
        await s.refresh()
        #expect(client.paths.isEmpty == false, "resumes after the reset")
        #expect(s.status == .idle)
    }

    @Test func aRateLimitAnswerStopsEverythingAndShowsWhen() async {
        let clock = Date(timeIntervalSince1970: 2_000_000)
        let client = fake(prs: [Self.pull(1)])
        client.routes["/repos/o/r"] = .init(status: 403, body: #"{"message":"API rate limit exceeded"}"#)
        client.reset = nil
        let s = store(client, now: { clock })
        await s.refresh()
        #expect(s.status == .rateLimited(until: clock.addingTimeInterval(900)))
        #expect(client.paths == ["/repos/o/r"])
    }

    // MARK: - Ошибки

    @Test func aMissingOrPrivateRepositoryIsSaidSoAndOthersStillLoad() async {
        let client = fake(prs: [Self.pull(1)])
        let s = store(client, names: ["o/gone", "o/r"])
        await s.refresh()
        #expect(s.repos[0].error == "Not found or private")
        #expect(s.repos[1].error == nil)
        #expect(s.repos[1].pulls.count == 1)
    }

    @Test func offlineKeepsWhatWasKnown() async {
        let client = fake(prs: [Self.pull(1)])
        let s = store(client)
        await s.refresh()
        client.failure = URLError(.notConnectedToInternet)
        await s.refresh()
        #expect(s.status == .offline)
        #expect(s.repos[0].pulls.count == 1, "the old list stays")
        client.failure = nil
        await s.refresh()
        #expect(s.status == .idle)
        #expect(s.repos[0].error == nil)
    }

    // MARK: - Список репозиториев

    @Test func addingFromTheClipboardValidatesDedupesCapsAndSaves() async {
        let client = fake()
        var saved: [[String]] = []
        let s = store(client, names: ["o/r"], saved: { saved.append($0) })
        #expect(s.add(from: "nonsense") == .invalid)
        #expect(s.add(from: "https://github.com/O/R") == .duplicate, "case-insensitive")
        #expect(s.add(from: "https://github.com/a/b") == .added("a/b"))
        #expect(saved.last == ["o/r", "a/b"])
        for i in 0..<10 { _ = s.add(from: "x/y\(i)") }
        #expect(s.repos.count == GitHubStore.maxRepos)
        #expect(s.add(from: "x/last") == .tooMany)
        // Дать фоновому обновлению отработать, чтобы тест не оставил задач.
        for _ in 0..<40 where s.status == .loading { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func removingForgetsAndSaves() {
        var saved: [[String]] = []
        let s = store(fake(), names: ["o/r", "a/b"], saved: { saved.append($0) })
        s.remove("o/r")
        #expect(s.repos.map(\.fullName) == ["a/b"])
        #expect(saved.last == ["a/b"])
    }

    @Test func theTotalsAndTheFailingFlagFollowTheData() async {
        let client = fake(prs: [Self.pull(1), Self.pull(2)], ci: ("completed", "failure"))
        let s = store(client)
        #expect(s.totalPulls == 0)
        await s.refresh()
        #expect(s.totalPulls == 2)
        #expect(s.hasFailingCI)
    }

    @Test func requestsCarryNothingPersonal() async {
        // Идентифицирует только имя приложения (заголовки собирает GitHubClient,
        // а путь это то, что здесь проверяется): в пути нет ничего, кроме репозитория.
        let client = fake(prs: [Self.pull(1)])
        let s = store(client)
        await s.refresh()
        for path in client.paths { #expect(path.hasPrefix("/repos/o/r"), "\(path)") }
    }
}
