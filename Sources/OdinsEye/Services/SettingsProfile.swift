import Foundation

/// Всё, что профиль умеет переключать разом: оформление, поведение, звуки,
/// и по желанию набор вкладок. Чистая структура без файлов и окон, поэтому
/// её можно проверять тестами.
struct SettingsSnapshot: Codable, Equatable, Sendable {
    var sounds = true
    var lyrics = true
    var haptics = true
    var hideFromCapture = false
    var glass = true
    /// Насколько стекло затемнено: 0 почти прозрачное, 1 почти чёрное.
    var glassTint = 0.6
    /// То же для карточки на экране блокировки.
    var lockGlassTint = 0.3
    var matchSongColor = false
    /// Сколько цвета обложки подмешивается к чёрному фону.
    var songColorStrength = 0.34
    var hideInFullscreen = false
    /// Секунды, которые курсор стоит на чёлке до раскрытия панели.
    var openDelay = 0.05
    var focusOverlay = true
    var showAgent = true
    /// Выключенные вкладки по `Tab.rawValue`. nil значит «не трогать вкладки»:
    /// встроенный профиль «Обычный» не должен возвращать вкладку, которую
    /// человек убрал сам.
    var hiddenTabs: [String]?

    static let glassTintRange = 0.0...0.9
    static let songColorRange = 0.1...0.6
    static let openDelayRange = 0.0...0.5

    init() {}

    /// Каждый ключ необязателен: профиль, сохранённый прошлой версией, не
    /// должен ломаться от появления новой настройки. Значения вне диапазона
    /// подрезаются, чтобы правка файла руками не давала невидимую панель.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsSnapshot()
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        lyrics = try c.decodeIfPresent(Bool.self, forKey: .lyrics) ?? d.lyrics
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        hideFromCapture = try c.decodeIfPresent(Bool.self, forKey: .hideFromCapture) ?? d.hideFromCapture
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? d.glass
        glassTint = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .glassTint) ?? d.glassTint, Self.glassTintRange)
        lockGlassTint = Self.clamp(
            try c.decodeIfPresent(Double.self, forKey: .lockGlassTint) ?? d.lockGlassTint, Self.glassTintRange)
        matchSongColor = try c.decodeIfPresent(Bool.self, forKey: .matchSongColor) ?? d.matchSongColor
        songColorStrength = Self.clamp(
            try c.decodeIfPresent(Double.self, forKey: .songColorStrength) ?? d.songColorStrength, Self.songColorRange)
        hideInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? d.hideInFullscreen
        openDelay = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .openDelay) ?? d.openDelay, Self.openDelayRange)
        focusOverlay = try c.decodeIfPresent(Bool.self, forKey: .focusOverlay) ?? d.focusOverlay
        showAgent = try c.decodeIfPresent(Bool.self, forKey: .showAgent) ?? d.showAgent
        hiddenTabs = try c.decodeIfPresent([String].self, forKey: .hiddenTabs)
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Совпадают ли настройки. Вкладки сравниваются, только если профиль их задаёт.
    func matches(current: SettingsSnapshot) -> Bool {
        var mine = self
        var theirs = current
        if mine.hiddenTabs == nil {
            theirs.hiddenTabs = nil
        } else {
            mine.hiddenTabs = mine.hiddenTabs?.sorted()
            theirs.hiddenTabs = theirs.hiddenTabs?.sorted()
        }
        // Слайдеры отдают значения с шумом в последнем знаке.
        return mine.close(to: theirs)
    }

    private func close(to o: SettingsSnapshot) -> Bool {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
        return sounds == o.sounds && lyrics == o.lyrics && haptics == o.haptics
            && hideFromCapture == o.hideFromCapture && glass == o.glass
            && near(glassTint, o.glassTint) && near(lockGlassTint, o.lockGlassTint) && matchSongColor == o.matchSongColor
            && near(songColorStrength, o.songColorStrength)
            && hideInFullscreen == o.hideInFullscreen && near(openDelay, o.openDelay)
            && focusOverlay == o.focusOverlay && showAgent == o.showAgent
            && hiddenTabs == o.hiddenTabs
    }
}

struct SettingsProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var settings: SettingsSnapshot

    var isBuiltIn: Bool { id.hasPrefix(Self.builtInPrefix) }
    static let builtInPrefix = "builtin."

    /// Готовые профили живут в коде, а не в файле: их нельзя испортить и
    /// они обновляются вместе с приложением.
    static var builtIn: [SettingsProfile] {
        var normal = SettingsSnapshot()
        normal.hiddenTabs = nil

        var quiet = normal
        quiet.sounds = false
        quiet.haptics = false

        var presentation = normal
        presentation.sounds = false
        presentation.haptics = false
        presentation.hideFromCapture = true
        presentation.hideInFullscreen = true
        presentation.showAgent = false
        presentation.hiddenTabs = ["agents", "clipboard", "shelf", "snippets"]

        var glass = normal
        glass.glass = true
        glass.glassTint = 0.5
        glass.matchSongColor = true

        return [
            SettingsProfile(id: builtInPrefix + "default", name: localized("Default"), settings: normal),
            SettingsProfile(id: builtInPrefix + "quiet", name: localized("Quiet"), settings: quiet),
            SettingsProfile(id: builtInPrefix + "presentation", name: localized("Presentation"), settings: presentation),
            SettingsProfile(id: builtInPrefix + "glass", name: localized("Glass"), settings: glass),
        ]
    }

    /// «Профиль 1», «Профиль 2»: первый свободный номер.
    static func nextName(existing: [String]) -> String {
        var n = 1
        while existing.contains(localized("Profile %d", n)) { n += 1 }
        return localized("Profile %d", n)
    }
}
