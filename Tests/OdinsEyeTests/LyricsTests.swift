import Foundation
import Testing
@testable import OdinsEye

/// Разбор LRC, выбор текста из ответа поиска и поведение стора. Сеть заменена
/// заглушкой: настоящий сервис в тестах не вызывается.
struct LRCTests {
    @Test func parsesTimestampsInHundredthsAndMilliseconds() {
        let lines = LRC.parse("[00:12.34] first\n[01:02.500]second\n[10:00]third")
        #expect(lines.map(\.text) == ["first", "second", "third"])
        #expect(abs(lines[0].time - 12.34) < 0.001)
        #expect(abs(lines[1].time - 62.5) < 0.001)
        #expect(lines[2].time == 600)
    }

    @Test func ignoresMetadataTagsAndPlainLines() {
        let lines = LRC.parse("[ar:Artist]\n[length: 03:00]\njust text\n[00:01.00] real")
        #expect(lines == [LyricLine(time: 1, text: "real")])
    }

    @Test func repeatedStampsMakeOneLinePerStampInTimeOrder() {
        let lines = LRC.parse("[00:30.00][00:10.00] chorus\n[00:20.00] verse")
        #expect(lines.map(\.text) == ["chorus", "verse", "chorus"])
        #expect(lines.map(\.time) == [10, 20, 30])
    }

    @Test func stripsWordLevelStampsAndKeepsEmptyBreaks() {
        let lines = LRC.parse("[00:05.00] <00:05.00>hel<00:05.40>lo\n[00:09.00]")
        #expect(lines[0].text == "hello")
        #expect(lines[1].text == "")
    }

    @Test func indexFindsTheLineThatIsSounding() {
        let lines = [LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b"), LyricLine(time: 20, text: "c")]
        #expect(LRC.index(at: 2, in: lines) == nil)
        #expect(LRC.index(at: 5, in: lines) == 0)
        #expect(LRC.index(at: 19.9, in: lines) == 1)
        #expect(LRC.index(at: 500, in: lines) == 2)
        #expect(LRC.index(at: 1, in: []) == nil)
    }
}

struct LyricsMatchTests {
    private func candidate(_ title: String, _ artist: String, _ duration: Double, _ lyrics: String? = "[00:01.00] x") -> LyricsMatch.Candidate {
        .init(trackName: title, artistName: artist, duration: duration, syncedLyrics: lyrics)
    }

    @Test func takesTheClosestDurationAmongMatchingTitles() {
        let query = LyricsQuery(title: "Put On A Smile", artist: "Bruno Mars", album: "", duration: 255)
        let result = LyricsMatch.best(from: [
            candidate("Put On A Smile", "Bruno Mars", 250, "[00:01.00] far"),
            candidate("Put On A Smile", "Bruno Mars", 255.4, "[00:01.00] near"),
        ], for: query)
        #expect(result == "[00:01.00] near")
    }

    @Test func refusesAnotherSongAnotherArtistOrAnotherLength() {
        let query = LyricsQuery(title: "Smile", artist: "Artist", album: "", duration: 200)
        #expect(LyricsMatch.best(from: [candidate("Smile Again", "Artist", 200)], for: query) == nil)
        #expect(LyricsMatch.best(from: [candidate("Smile", "Somebody Else", 200)], for: query) == nil)
        #expect(LyricsMatch.best(from: [candidate("Smile", "Artist", 260)], for: query) == nil)
        #expect(LyricsMatch.best(from: [candidate("Smile", "Artist", 200, nil)], for: query) == nil)
    }

    @Test func ignoresCaseAccentsAndPunctuation() {
        let query = LyricsQuery(title: "Beyoncé — Halo!", artist: "", album: "", duration: 0)
        #expect(LyricsMatch.best(from: [candidate("beyonce halo", "Anyone", 100)], for: query) != nil)
    }
}

private struct FakeFetcher: LyricsFetching {
    var reply: String?
    let counter: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func hit() { lock.withLock { value += 1 } }
    }

    func fetch(_ query: LyricsQuery) async -> String? {
        counter.hit()
        return reply
    }
}

@MainActor
struct LyricsStoreTests {
    private func track(_ key: String) -> MediaController.Track {
        .init(title: key, artist: "a", album: "", key: key)
    }

    private func store(reply: String?, enabled: Bool = true) -> (LyricsStore, FakeFetcher.Counter) {
        let counter = FakeFetcher.Counter()
        let store = LyricsStore(
            fetcher: FakeFetcher(reply: reply, counter: counter), enabled: enabled, delay: .zero, duration: { 100 }
        )
        return (store, counter)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func fetchesOnlyWhileWantedAndShowsTheLines() async {
        let (store, counter) = store(reply: "[00:01.00] hello\n[00:05.00] world")
        store.trackChanged(track("t1"))
        await settle()
        #expect(counter.count == 0)           // панель закрыта: сеть молчит
        #expect(!store.hasLyrics)

        store.setWanted(true)
        await settle()
        #expect(counter.count == 1)
        #expect(store.hasLyrics)
        let shown = store.visible(at: 2)
        #expect(shown.current == "hello")
        #expect(shown.next == "world")
    }

    @Test func aTrackIsAskedOnceThenRemembered() async {
        let (store, counter) = store(reply: "[00:01.00] hello")
        store.setWanted(true)
        store.trackChanged(track("t1"))
        await settle()
        store.trackChanged(track("t2"))
        await settle()
        store.trackChanged(track("t1"))
        await settle()
        #expect(counter.count == 2)
        #expect(store.hasLyrics)
    }

    @Test func noLyricsIsRememberedToo() async {
        let (store, counter) = store(reply: nil)
        store.setWanted(true)
        store.trackChanged(track("t1"))
        await settle()
        store.setWanted(false)
        store.setWanted(true)
        await settle()
        #expect(counter.count == 1)
        #expect(!store.hasLyrics)
    }

    @Test func disabledNeverAsks() async {
        let (store, counter) = store(reply: "[00:01.00] hello", enabled: false)
        store.setWanted(true)
        store.trackChanged(track("t1"))
        await settle()
        #expect(counter.count == 0)
        #expect(!store.hasLyrics)
    }

    @Test func introShowsNoCurrentLineYet() async {
        let (store, _) = store(reply: "[00:10.00] later")
        store.setWanted(true)
        store.trackChanged(track("t1"))
        await settle()
        let shown = store.visible(at: 1)
        #expect(shown.current == nil)
        #expect(shown.next == "later")
    }
}
