import AVFoundation
import Foundation

/// Три тихих звука Peeky: приветствие, «нужно ваше решение», «готово».
/// Синтезированы в `assets/sounds/make_sounds.py`, чужих сэмплов нет. Звуки
/// выключаются в настройках; громкость низкая и не зависит от системной
/// только в меньшую сторону.
@MainActor
final class PeekySounds {
    enum Sound: String, CaseIterable {
        case hello, ask, done

        /// Не чаще: без этого серия коротких сессий превратилась бы в трель.
        var cooldown: TimeInterval {
            switch self {
            case .hello: return 1.5
            case .ask: return 0.5
            case .done: return 3
            }
        }
    }

    static let shared = PeekySounds()
    /// Тихо по умолчанию: это фон работы, а не уведомление.
    static let volume: Float = 0.25

    /// Громкость плеера. Меняется только в тестах, чтобы набор не звучал.
    var volume: Float = PeekySounds.volume
    var folder: URL? = Bundle.main.resourceURL?.appendingPathComponent("sounds", isDirectory: true)
    var isEnabled: () -> Bool = { ConfigStore.shared.sounds }

    /// Последний звук, который действительно пошёл на воспроизведение.
    private(set) var lastPlayed: Sound?
    private var players: [Sound: AVAudioPlayer] = [:]
    private var lastTime: [Sound: Date] = [:]

    func play(_ sound: Sound, now: Date = Date()) {
        guard isEnabled() else { return }
        if let last = lastTime[sound], now.timeIntervalSince(last) < sound.cooldown { return }
        guard let player = player(for: sound) else { return }
        lastTime[sound] = now
        lastPlayed = sound
        player.currentTime = 0
        player.volume = volume
        player.play()
    }

    /// Файл читается один раз; нет файла — звука нет, без ошибки.
    private func player(for sound: Sound) -> AVAudioPlayer? {
        if let cached = players[sound] { return cached }
        guard let url = folder?.appendingPathComponent(sound.rawValue + ".wav"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        player.prepareToPlay()
        players[sound] = player
        return player
    }
}
