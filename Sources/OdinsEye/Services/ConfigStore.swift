import AppKit

/// Everything about the app that makes sense on somebody else's Mac, in one
/// file next to `snippets.json`.
///
/// Before this, the same handful of settings each kept their own place and
/// their own copy of "and what if the key isn't there yet". Harmless at four;
/// every new setting was the fifth spelling of the same question.
///
/// **What comes here.** What has meaning on another Mac. Shelf paths (content,
/// not configuration) stay in `UserDefaults` — by that rule.
///
/// **Migration.** No file yet → built once from the old `UserDefaults` keys
/// and written. The old keys are then left alone: rolling back to a build
/// before this one loses a few switches rather than this app carrying two
/// sources of truth for one release .
@MainActor
final class ConfigStore: ObservableObject {
    private struct KeepAwakeConfig: Codable, Equatable {
        /// `KeepAwake.Duration.rawValue`.
        var duration = "indefinite"
        /// Display too, or only the system.
        var display = true
    }

    private struct File: Codable, Equatable {
        var saveClipboardImages = true
        /// Тихие звуки Peeky (приветствие, запрос, «готово»).
        var sounds = true
        var privacy: [String] = []
        var hiddenTabs: [String] = []
        var keepAwake = KeepAwakeConfig()
        /// Тексты песен во вкладке «Музыка» (запрос в lrclib.net).
        var lyrics = true
        /// Панель и Peeky не попадают в запись и скриншоты экрана.
        var hideFromCapture = false
        /// Лёгкий отклик тачпада при открытии панели и смене вкладки.
        var haptics = true
        /// Панель из «жидкого стекла» (macOS 26+).
        var glass = true
        /// Фон вкладки «Музыка» берёт цвет обложки.
        var matchSongColor = false
        /// Не раскрывать панель наведением поверх приложения в полноэкранном режиме.
        var hideInFullscreen = false
        var glassTint = 0.6
        /// Затемнение стекла карточки на экране блокировки. Отдельно от панели:
        /// на блокировке под карточкой обои, а не рабочий стол.
        var lockGlassTint = 0.3
        var songColorStrength = 0.34
        var openDelay = 0.05
        /// Плашка у чёлки, когда включается или выключается Фокус.
        var focusOverlay = true
        /// Агент (Peeky и точки сессий) у чёлки.
        var showAgent = true
        /// Карточка музыки на экране блокировки. По умолчанию выключена и в
        /// профили не входит: профиль не должен включать её сам.
        var lockScreenPlayer = false
        /// Функцию выключил аварийный выход (после зависания или падения).
        var lockScreenTripped = false
        /// Профили, сохранённые пользователем. Готовые живут в коде.
        var profiles: [SettingsProfile] = []

        init() {}

        /// Every key optional, falling back to the default above. The
        /// synthesized decoder treats a key it does not find as a broken
        /// file, so the first setting added after release would have turned
        /// every existing `config.json` read-only in one go — the file written
        /// by the previous version simply does not have it. Keys this version
        /// no longer knows are ignored the same way.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = File()
            saveClipboardImages = try c.decodeIfPresent(Bool.self, forKey: .saveClipboardImages) ?? d.saveClipboardImages
            sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
            privacy = try c.decodeIfPresent([String].self, forKey: .privacy) ?? d.privacy
            hiddenTabs = try c.decodeIfPresent([String].self, forKey: .hiddenTabs) ?? d.hiddenTabs
            keepAwake = try c.decodeIfPresent(KeepAwakeConfig.self, forKey: .keepAwake) ?? d.keepAwake
            lyrics = try c.decodeIfPresent(Bool.self, forKey: .lyrics) ?? d.lyrics
            hideFromCapture = try c.decodeIfPresent(Bool.self, forKey: .hideFromCapture) ?? d.hideFromCapture
            haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
            glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? d.glass
            matchSongColor = try c.decodeIfPresent(Bool.self, forKey: .matchSongColor) ?? d.matchSongColor
            hideInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? d.hideInFullscreen
            glassTint = SettingsSnapshot.clamp(
                try c.decodeIfPresent(Double.self, forKey: .glassTint) ?? d.glassTint, SettingsSnapshot.glassTintRange)
            lockGlassTint = SettingsSnapshot.clamp(
                try c.decodeIfPresent(Double.self, forKey: .lockGlassTint) ?? d.lockGlassTint,
                SettingsSnapshot.glassTintRange)
            songColorStrength = SettingsSnapshot.clamp(
                try c.decodeIfPresent(Double.self, forKey: .songColorStrength) ?? d.songColorStrength,
                SettingsSnapshot.songColorRange)
            openDelay = SettingsSnapshot.clamp(
                try c.decodeIfPresent(Double.self, forKey: .openDelay) ?? d.openDelay, SettingsSnapshot.openDelayRange)
            focusOverlay = try c.decodeIfPresent(Bool.self, forKey: .focusOverlay) ?? d.focusOverlay
            showAgent = try c.decodeIfPresent(Bool.self, forKey: .showAgent) ?? d.showAgent
            lockScreenPlayer = try c.decodeIfPresent(Bool.self, forKey: .lockScreenPlayer) ?? d.lockScreenPlayer
            lockScreenTripped = try c.decodeIfPresent(Bool.self, forKey: .lockScreenTripped) ?? d.lockScreenTripped
            // Битый профиль не должен ронять весь файл: читается по одному.
            profiles = (try? c.decodeIfPresent([SettingsProfile].self, forKey: .profiles)) ?? d.profiles
        }
    }

    static let shared = ConfigStore(file: ConfigStore.file, migratesLegacy: true)

    /// `~/Library/Application Support/OdinsEye/config.json`.
    static let file = Support.file("config.json")

    /// True when the file exists but cannot be parsed — same meaning and the
    /// same consequence as `SnippetStore.fileBroken`: reading stays
    /// honest, and writing stops rather than paving over a hand edit gone
    /// wrong.
    @Published private(set) var fileBroken = false

    private var value: File
    private let fileURL: URL

    /// Свой файл нужен тестам и проверке E2E: настоящий `config.json` они не трогают.
    init(file: URL, migratesLegacy: Bool = false) {
        self.fileURL = file
        if let data = try? Data(contentsOf: file) {
            do {
                value = try JSONDecoder().decode(File.self, from: data)
            } catch {
                value = File()
                fileBroken = true
                NSLog("OdinsEye: config.json is not readable: \(error.localizedDescription)")
            }
        } else {
            // Nothing on disk yet, so nothing to protect — assembled from
            // whatever the old keys already say and written straight away.
            value = migratesLegacy ? Self.migrated() : File()
            write(value)
        }
        lastSaved = Self.dictionary(value)
    }

    // MARK: - Settings

    /// Off switch for people who copy images all day and do not want them
    /// kept. Defaults to on: the feature is the reason the folder exists.
    var saveClipboardImages: Bool {
        get { value.saveClipboardImages }
        set { value.saveClipboardImages = newValue; persist() }
    }

    /// Свои тихие звуки Peeky. Включены по умолчанию.
    var sounds: Bool {
        get { value.sounds }
        set { value.sounds = newValue; persist() }
    }


    /// Raw `PrivacyMode.Section` values. Kept as strings here rather than that
    /// type so this store does not need to know about it — the same reason
    /// `hiddenTabs` below is `[String]` and not `[NotchViewModel.Tab]`.
    var privacy: [String] {
        get { value.privacy }
        set { value.privacy = newValue; persist() }
    }

    /// Last chosen "Не спать" duration. Remembered, never resumed: the mode
    /// itself always starts off after a relaunch.
    var keepAwakeDuration: String {
        get { value.keepAwake.duration }
        set { value.keepAwake.duration = newValue; persist() }
    }

    /// Whether "Не спать" keeps the display on as well as the system.
    var keepAwakeDisplay: Bool {
        get { value.keepAwake.display }
        set { value.keepAwake.display = newValue; persist() }
    }

    /// Тексты песен. Включены по умолчанию; название, исполнитель, альбом и
    /// длительность трека уходят в lrclib.net, пока панель открыта на «Музыке».
    var lyrics: Bool {
        get { value.lyrics }
        set { value.lyrics = newValue; persist() }
    }

    var hideFromCapture: Bool {
        get { value.hideFromCapture }
        set { value.hideFromCapture = newValue; persist() }
    }

    var haptics: Bool {
        get { value.haptics }
        set { value.haptics = newValue; persist() }
    }

    var glass: Bool {
        get { value.glass }
        set { value.glass = newValue; persist() }
    }

    var matchSongColor: Bool {
        get { value.matchSongColor }
        set { value.matchSongColor = newValue; persist() }
    }

    var hideInFullscreen: Bool {
        get { value.hideInFullscreen }
        set { value.hideInFullscreen = newValue; persist() }
    }

    var lockScreenPlayer: Bool {
        get { value.lockScreenPlayer }
        set { value.lockScreenPlayer = newValue; persist() }
    }

    var lockScreenTripped: Bool {
        get { value.lockScreenTripped }
        set { value.lockScreenTripped = newValue; persist() }
    }

    var showAgent: Bool {
        get { value.showAgent }
        set { value.showAgent = newValue; persist() }
    }

    var focusOverlay: Bool {
        get { value.focusOverlay }
        set { value.focusOverlay = newValue; persist() }
    }

    var glassTint: Double {
        get { value.glassTint }
        set { value.glassTint = SettingsSnapshot.clamp(newValue, SettingsSnapshot.glassTintRange); persist() }
    }

    var lockGlassTint: Double {
        get { value.lockGlassTint }
        set { value.lockGlassTint = SettingsSnapshot.clamp(newValue, SettingsSnapshot.glassTintRange); persist() }
    }

    var songColorStrength: Double {
        get { value.songColorStrength }
        set { value.songColorStrength = SettingsSnapshot.clamp(newValue, SettingsSnapshot.songColorRange); persist() }
    }

    var openDelay: Double {
        get { value.openDelay }
        set { value.openDelay = SettingsSnapshot.clamp(newValue, SettingsSnapshot.openDelayRange); persist() }
    }

    // MARK: - Profiles

    var customProfiles: [SettingsProfile] { value.profiles }

    /// Текущие настройки целиком, как их хранит профиль.
    var snapshot: SettingsSnapshot {
        var s = SettingsSnapshot()
        s.sounds = value.sounds
        s.lyrics = value.lyrics
        s.haptics = value.haptics
        s.hideFromCapture = value.hideFromCapture
        s.glass = value.glass
        s.glassTint = value.glassTint
        s.lockGlassTint = value.lockGlassTint
        s.matchSongColor = value.matchSongColor
        s.songColorStrength = value.songColorStrength
        s.hideInFullscreen = value.hideInFullscreen
        s.openDelay = value.openDelay
        s.focusOverlay = value.focusOverlay
        s.showAgent = value.showAgent
        s.hiddenTabs = value.hiddenTabs.sorted()
        return s
    }

    /// Применяет всё, кроме вкладок и текстов песен: у тех есть работающие
    /// службы, их включает и выключает `NotchViewModel.apply`.
    func applyLook(_ s: SettingsSnapshot) {
        value.sounds = s.sounds
        value.haptics = s.haptics
        value.hideFromCapture = s.hideFromCapture
        value.glass = s.glass
        value.glassTint = s.glassTint
        value.lockGlassTint = s.lockGlassTint
        value.matchSongColor = s.matchSongColor
        value.songColorStrength = s.songColorStrength
        value.hideInFullscreen = s.hideInFullscreen
        value.openDelay = s.openDelay
        value.focusOverlay = s.focusOverlay
        value.showAgent = s.showAgent
        persist()
    }

    @discardableResult
    func addProfile(from settings: SettingsSnapshot) -> SettingsProfile {
        let name = SettingsProfile.nextName(existing: value.profiles.map(\.name))
        let profile = SettingsProfile(id: UUID().uuidString, name: name, settings: settings)
        value.profiles.append(profile)
        persist()
        return profile
    }

    func deleteProfile(id: String) {
        value.profiles.removeAll { $0.id == id }
        persist()
    }

    /// Tabs switched off in Settings, by `Tab.rawValue`. Kept as the set
    /// of what is off rather than what is on, so a tab added in a later
    /// version shows up for everyone instead of arriving hidden.
    var hiddenTabs: [String] {
        get { value.hiddenTabs }
        set { value.hiddenTabs = newValue; persist() }
    }

    // MARK: - Migration

    /// Reads the places these settings used to live. Each guard mirrors
    /// exactly what that setting's own `object(forKey:) != nil` check used to
    /// do, so a Mac with none of these keys set gets the same defaults as
    /// before and a Mac with some of them set keeps exactly those.
    private static func migrated() -> File {
        let defaults = UserDefaults.standard
        var file = File()
        if defaults.object(forKey: "saveClipboardImages") != nil {
            file.saveClipboardImages = defaults.bool(forKey: "saveClipboardImages")
        }
        if let sections = defaults.array(forKey: "privacyMode.sections") as? [String] {
            file.privacy = sections
        } else if defaults.bool(forKey: "privacyMode") {
            // The legacy switch covered everything or nothing — see
            // `PrivacyMode.init` before this store existed.
            file.privacy = ["clipboard", "snippets"]
        }
        if let hidden = defaults.stringArray(forKey: "hiddenTabs") {
            file.hiddenTabs = hidden
        }
        return file
    }

    // MARK: - Storage

    private func persist() {
        // Toggles in Settings read these properties through bindings; without
        // this, nothing tells SwiftUI the value moved.
        objectWillChange.send()
        mergeAndWrite()
    }

    /// Что лежало в файле, когда этот стор его читал или писал в последний раз.
    private var lastSaved: [String: Any] = [:]

    private static func dictionary(_ file: File) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Пишет в файл только то, что изменил этот экземпляр, поверх того, что в
    /// нём лежит сейчас. Стор читает файл один раз при запуске; если рядом
    /// работает второй экземпляр (установленное приложение и сборка из
    /// исходников, оба в автозапуске), запись целиком стирала его настройки
    /// старыми значениями. Ключи, которых эта версия не знает, тоже остаются.
    private func mergeAndWrite() {
        guard !fileBroken else { return }
        let mine = Self.dictionary(value)
        var disk: [String: Any]
        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            disk = object
        } else {
            disk = mine
        }
        for (key, new) in mine where !((lastSaved[key] as AnyObject?)?.isEqual(new) ?? false) {
            disk[key] = new
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: disk, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("OdinsEye: cannot write config.json: \(error.localizedDescription)")
            return
        }
        // Дальше стор живёт с тем, что получилось после слияния.
        if let merged = try? JSONDecoder().decode(File.self, from: data) { value = merged }
        lastSaved = Self.dictionary(value)
    }

    /// Pretty-printed, and slashes left alone — same reason as
    /// `snippets.json`: this file is meant to be opened, edited by hand, and
    /// handed to somebody else's Mac.
    private func write(_ file: File) {
        guard !fileBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("OdinsEye: cannot write config.json: \(error.localizedDescription)")
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            shared.write(shared.value)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
