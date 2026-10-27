import Foundation

/// Ответ GitHub: то, что нужно стору, и заголовки лимита.
struct GitHubResponse: Sendable {
    let status: Int
    let data: Data
    let etag: String?
    /// Сколько запросов осталось в часовом окне; `nil`, если заголовка нет.
    let remaining: Int?
    let reset: Date?
}

/// Всё, что стору нужно от сети. Протокол, чтобы тесты подставляли свой ответ.
protocol GitHubFetching: Sendable {
    func get(_ path: String, etag: String?) async throws -> GitHubResponse
}

/// Публичный REST API GitHub без токена: 60 запросов в час на адрес.
///
/// Без токена и без чего-либо личного в запросах: в `User-Agent` только имя
/// приложения. Условный запрос с `If-None-Match` экономит трафик, но НЕ
/// квоту: проверено, 304 тоже списывает один запрос из шестидесяти.
struct GitHubClient: GitHubFetching {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func get(_ path: String, etag: String?) async throws -> GitHubResponse {
        guard let url = URL(string: "https://api.github.com" + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OdinsEye", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return GitHubResponse(
            status: http.statusCode, data: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            remaining: http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init),
            reset: http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        )
    }
}
