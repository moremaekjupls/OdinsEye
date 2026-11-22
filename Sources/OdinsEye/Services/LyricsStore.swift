import Foundation

/// Одна строка текста песни и секунда, с которой она звучит.
struct LyricLine: Equatable, Sendable {
    var time: TimeInterval
    var text: String
}

/// Разбор синхронизированного текста в формате LRC: `[01:23.45] строка`.
///
/// Чистая функция, без сети и без времени: так её можно проверять на кривых
/// файлах, а их в LRC-базах хватает.
enum LRC {
    /// Метки времени в начале строки. Секунды после точки (иногда двоеточия)
    /// бывают в два и в три знака: сотые или миллисекунды.
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    /// Пословные метки `<00:12.34>` из расширенного LRC: нам нужна строка целиком.
    private static let wordStamp = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            let matches = stamp.matches(in: line, range: range)
            // Строка без меток — это `[ar:Artist]`, `[length:...]` или мусор.
            guard matches.first?.range.location == 0 else { continue }

            // Метки идут подряд в начале: `[00:10.00][01:30.00] припев`.
            var consumed = 0
            var times: [TimeInterval] = []
            for match in matches {
                guard match.range.location == consumed else { break }
                times.append(seconds(from: match, in: line))
                consumed = match.range.location + match.range.length
            }
            guard !times.isEmpty else { continue }

            var body = (line as NSString).substring(from: consumed)
            body = wordStamp.stringByReplacingMatches(
                in: body, range: NSRange(body.startIndex..., in: body), withTemplate: ""
            )
            body = body.trimmingCharacters(in: .whitespaces)
            for time in times { lines.append(LyricLine(time: time, text: body)) }
        }
        // Сортировка устойчивая по времени: равные метки остаются в порядке файла.
        return lines.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    private static func seconds(from match: NSTextCheckingResult, in line: String) -> TimeInterval {
        func part(_ index: Int) -> String? {
            let r = match.range(at: index)
            guard r.location != NSNotFound, let range = Range(r, in: line) else { return nil }
            return String(line[range])
        }
        let minutes = Double(part(1) ?? "0") ?? 0
        let secs = Double(part(2) ?? "0") ?? 0
        var fraction = 0.0
        if let digits = part(3), let value = Double(digits) {
            fraction = value / pow(10, Double(digits.count))
        }
        return minutes * 60 + secs + fraction
    }

    /// Какая строка звучит на этой секунде: последняя из начавшихся. До первой
    /// строки (вступление) — `nil`.
    static func index(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty, position >= lines[0].time else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Что спрашиваем у сервиса текстов.
struct LyricsQuery: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// 0, если плеер длительность не сообщил.
    var duration: TimeInterval
}

protocol LyricsFetching: Sendable {
    /// Синхронизированный текст в LRC или `nil`, если его нет или сервис не ответил.
    func fetch(_ query: LyricsQuery) async -> String?
}

/// Выбор из ответа поиска: чужой текст под нашей песней хуже, чем никакого,
/// поэтому берётся только то, где совпадает название и сходится длительность.
enum LyricsMatch {
    struct Candidate: Sendable {
        var trackName: String
        var artistName: String
        var duration: TimeInterval
        var syncedLyrics: String?
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func best(from candidates: [Candidate], for query: LyricsQuery) -> String? {
        let title = normalize(query.title)
        let artist = normalize(query.artist)
        guard !title.isEmpty else { return nil }
        let scored = candidates.compactMap { c -> (Double, String)? in
            guard let lyrics = c.syncedLyrics, !lyrics.isEmpty else { return nil }
            let name = normalize(c.trackName)
            guard name == title else { return nil }
            // Исполнитель должен совпасть, если плеер его назвал.
            if !artist.isEmpty {
                let who = normalize(c.artistName)
                guard who == artist || who.contains(artist) || artist.contains(who) else { return nil }
            }
            var gap = 0.0
            if query.duration > 0 && c.duration > 0 {
                gap = abs(c.duration - query.duration)
                guard gap <= 6 else { return nil }
            }
            return (gap, lyrics)
        }
        return scored.min { $0.0 < $1.0 }?.1
    }
}

/// lrclib.net: бесплатная база синхронизированных текстов, без ключа.
/// Уходят название, исполнитель, альбом и длительность трека, больше ничего.
struct LRCLibFetcher: LyricsFetching {
    private static let base = "https://lrclib.net/api"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private struct Item: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var syncedLyrics: String?
    }

    func fetch(_ query: LyricsQuery) async -> String? {
        guard !query.title.isEmpty else { return nil }
        // Точное совпадение: у сервиса это самый надёжный путь.
        var exact = [URLQueryItem(name: "track_name", value: query.title)]
        if !query.artist.isEmpty { exact.append(URLQueryItem(name: "artist_name", value: query.artist)) }
        if !query.album.isEmpty { exact.append(URLQueryItem(name: "album_name", value: query.album)) }
        if query.duration > 0 { exact.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded())))) }
        if let data = await get("get", exact), let item = try? JSONDecoder().decode(Item.self, from: data),
           let lyrics = item.syncedLyrics, !lyrics.isEmpty {
            return lyrics
        }

        // Не нашлось: поиск по названию и исполнителю, с проверкой совпадения.
        var search = [URLQueryItem(name: "track_name", value: query.title)]
        if !query.artist.isEmpty { search.append(URLQueryItem(name: "artist_name", value: query.artist)) }
        guard let data = await get("search", search),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        let candidates = items.map {
            LyricsMatch.Candidate(
                trackName: $0.trackName ?? "", artistName: $0.artistName ?? "",
                duration: $0.duration ?? 0, syncedLyrics: $0.syncedLyrics
            )
        }
        return LyricsMatch.best(from: candidates, for: query)
    }

    private func get(_ path: String, _ items: [URLQueryItem]) async -> Data? {
        guard var components = URLComponents(string: "\(Self.base)/\(path)") else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// Текст песни для вкладки «Музыка».
///
/// Ходит в сеть только пока панель открыта на этой вкладке: закрытой панели
/// текст не нужен, а запрос на каждую смену трека рассказывал бы чужому
/// серверу, что слушают весь день. Найденное и ненайденное помнится в памяти,
/// чтобы перемотка назад и повтор трека не повторяли запрос.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lines: [LyricLine] = []

    private let fetcher: LyricsFetching
    private let delay: Duration
    private let duration: @MainActor () -> TimeInterval

    private var wanted = false
    private var track: MediaController.Track?
    /// Для какого трека сейчас лежат `lines`. Пусто, пока ответа нет.
    private var loadedKey: String?
    private var cache: [String: [LyricLine]] = [:]
    private var cacheOrder: [String] = []
    private var task: Task<Void, Never>?
    private let cacheLimit = 40

    /// `delay` — пауза перед запросом: при быстром листании треков запрос уходит
    /// только за тем, на котором остановились. В тестах ноль.
    init(
        fetcher: LyricsFetching = LRCLibFetcher(),
        enabled: Bool = ConfigStore.shared.lyrics,
        delay: Duration = .milliseconds(600),
        duration: @escaping @MainActor () -> TimeInterval
    ) {
        self.fetcher = fetcher
        self.isEnabled = enabled
        self.delay = delay
        self.duration = duration
    }

    var hasLyrics: Bool { !lines.isEmpty }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        ConfigStore.shared.lyrics = on
        if on { refresh() } else { cancel(); lines = []; loadedKey = nil }
    }

    /// Панель открыта на вкладке «Музыка» или нет.
    func setWanted(_ value: Bool) {
        guard value != wanted else { return }
        wanted = value
        if value { refresh() } else { task?.cancel(); task = nil }
    }

    func trackChanged(_ new: MediaController.Track?) {
        guard new?.key != track?.key else { return }
        track = new
        cancel()
        lines = []
        loadedKey = nil
        refresh()
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    private func refresh() {
        guard isEnabled, wanted, let track, loadedKey != track.key, task == nil else { return }
        if let cached = cache[track.key] {
            lines = cached
            loadedKey = track.key
            return
        }
        let key = track.key
        task = Task { [weak self, delay, fetcher] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.track?.key == key else { return }
            let query = LyricsQuery(
                title: track.title, artist: track.artist, album: track.album, duration: self.duration()
            )
            let raw = await fetcher.fetch(query)
            guard !Task.isCancelled, self.track?.key == key else { return }
            let parsed = raw.map(LRC.parse) ?? []
            // Текст из одной пустой строки — тоже «нет текста».
            let usable = parsed.contains { !$0.text.isEmpty } ? parsed : []
            self.remember(usable, for: key)
            self.lines = usable
            self.loadedKey = key
            self.task = nil
        }
    }

    private func remember(_ lines: [LyricLine], for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = lines
        while cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Строки, которые показать на этой секунде: звучащая и следующая.
    func visible(at position: TimeInterval) -> (current: String?, next: String?) {
        guard hasLyrics else { return (nil, nil) }
        guard let index = LRC.index(at: position, in: lines) else {
            // Вступление: первая строка ещё впереди.
            return (nil, lines.first.map(\.text))
        }
        let next = index + 1 < lines.count ? lines[index + 1].text : nil
        return (lines[index].text, next)
    }
}
