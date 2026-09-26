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
        var privacy: [String] = []
        var hiddenTabs: [String] = []
        var keepAwake = KeepAwakeConfig()

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
            privacy = try c.decodeIfPresent([String].self, forKey: .privacy) ?? d.privacy
            hiddenTabs = try c.decodeIfPresent([String].self, forKey: .hiddenTabs) ?? d.hiddenTabs
            keepAwake = try c.decodeIfPresent(KeepAwakeConfig.self, forKey: .keepAwake) ?? d.keepAwake
        }
    }

    static let shared = ConfigStore()

    /// `~/Library/Application Support/OdinsEye/config.json`.
    static let file = Support.file("config.json")

    /// True when the file exists but cannot be parsed — same meaning and the
    /// same consequence as `SnippetStore.fileBroken`: reading stays
    /// honest, and writing stops rather than paving over a hand edit gone
    /// wrong.
    @Published private(set) var fileBroken = false

    private var value: File

    private init() {
        if let data = try? Data(contentsOf: Self.file) {
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
            value = Self.migrated()
            write(value)
        }
    }

    // MARK: - Settings

    /// Off switch for people who copy images all day and do not want them
    /// kept. Defaults to on: the feature is the reason the folder exists.
    var saveClipboardImages: Bool {
        get { value.saveClipboardImages }
        set { value.saveClipboardImages = newValue; persist() }
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
        write(value)
    }

    /// Pretty-printed, and slashes left alone — same reason as
    /// `snippets.json`: this file is meant to be opened, edited by hand, and
    /// handed to somebody else's Mac.
    private func write(_ file: File) {
        guard !fileBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(file).write(to: Self.file, options: .atomic)
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
