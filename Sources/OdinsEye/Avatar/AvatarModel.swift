import AppKit
import Combine
import SwiftUI

/// Настроение аватара и его движения.
///
/// Аватар это картинка пользователя (`AvatarSkins`); модель оживляет её:
/// качание, подпрыгивание, пульс. Анимация идёт только по событиям: смена
/// настроения и вспышка на каждое событие хука. Между ними ничего не
/// анимируется, SwiftUI не перерисовывает, процессор не занят.
@MainActor
final class AvatarModel: ObservableObject {
    enum Mood: Equatable, Sendable {
        case asleep, thinking, working, waiting, done
    }

    // Что делает картинка. Меняются внутри `withAnimation`.
    @Published private(set) var scale: Double = 1
    @Published private(set) var tilt: Double = 0
    @Published private(set) var lift: Double = 0
    @Published private(set) var dim: Double = 0.6

    @Published private(set) var mood: Mood = .asleep
    /// Есть ли вообще за кем следить: без сессий аватара нет.
    @Published private(set) var isPresent = false
    /// Основная панель раскрыта и закрывает собой место аватара.
    @Published private(set) var isCovered = false
    @Published private(set) var skin: NSImage?

    /// Без картинки пользователя аватара нет: нарисованного запасного нет.
    var isShown: Bool { isPresent && !isCovered && skin != nil }

    private let skins: AvatarSkins
    private var cancellables = Set<AnyCancellable>()
    private var script: Task<Void, Never>?
    private var bounceTask: Task<Void, Never>?
    private var lastBounce = Date.distantPast
    /// Не чаще одного подпрыгивания за это время: событий может быть много в
    /// секунду, а каждая анимация стоит перерисовки на 60 кадрах.
    static let bounceInterval: TimeInterval = 1.5
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(store: AgentSessionStore, skins: AvatarSkins? = nil) {
        self.skins = skins ?? AvatarSkins()

        // Значения берём из самого события: `@Published` сообщает до
        // присваивания, и чтение свойства стора из замыкания дало бы старое.
        Publishers.CombineLatest(store.$sessions, store.$pending)
            .sink { [weak self] sessions, pending in
                self?.update(sessions: sessions, hasPending: !pending.isEmpty)
            }
            .store(in: &cancellables)
        store.events
            .sink { [weak self] _ in self?.bounce() }
            .store(in: &cancellables)
    }

    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
    }

    /// Настроение по худшему состоянию среди сессий. Ожидающий запрос
    /// разрешения важнее любого состояния.
    static func mood(for sessions: [AgentSession], hasPending: Bool) -> Mood? {
        guard !sessions.isEmpty || hasPending else { return nil }
        if hasPending { return .waiting }
        switch sessions.map(\.state).max() {
        case .waiting: return .waiting
        case .working: return .working
        case .thinking: return .thinking
        case .finished: return .done
        default: return .asleep
        }
    }

    // MARK: - Сценарий

    /// Картинка настроения; нет своей — берётся `idle`, так что одного файла
    /// хватает на все.
    private func resolveSkin(for mood: Mood) -> NSImage? {
        skins.image(for: mood) ?? skins.image(for: .asleep)
    }

    private func update(sessions: [AgentSession], hasPending: Bool) {
        guard let next = Self.mood(for: sessions, hasPending: hasPending) else {
            isPresent = false
            script?.cancel()
            bounceTask?.cancel()
            return
        }
        isPresent = true
        let image = resolveSkin(for: next)
        guard next != mood || (skin == nil) != (image == nil) else { return }
        mood = next
        skin = image
        play(next)
    }

    private func go(_ animation: Animation = .easeInOut(duration: 0.35), _ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(animation, change) }
    }

    private func play(_ mood: Mood) {
        script?.cancel()
        bounceTask?.cancel()
        switch mood {
        case .asleep:
            go(.easeInOut(duration: 0.6)) { scale = 1; tilt = 0; lift = 0; dim = 0.6 }
        case .thinking:
            go { scale = 1; lift = 0; dim = 1 }
            guard !reduceMotion else { return }
            // Покачивает головой и замирает.
            script = Task {
                for angle in [-8.0, 8.0, -8.0, 0.0] {
                    guard !Task.isCancelled else { return }
                    go(.easeInOut(duration: 0.45)) { tilt = angle }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        case .working:
            go { scale = 1; tilt = 0; lift = 0; dim = 1 }
        case .waiting:
            go(.spring(response: 0.3, dampingFraction: 0.7)) { tilt = 0; lift = 0; dim = 1 }
            guard !reduceMotion else { return }
            script = Task {
                for _ in 0..<3 {
                    guard !Task.isCancelled else { return }
                    go(.easeOut(duration: 0.25)) { scale = 1.2 }
                    try? await Task.sleep(for: .milliseconds(300))
                    go(.easeIn(duration: 0.3)) { scale = 1 }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        case .done:
            go { tilt = 0; lift = 0; dim = 1 }
            guard !reduceMotion else { return }
            // Хлопок: подпрыгнул и встал на место.
            script = Task {
                go(.easeOut(duration: 0.15)) { scale = 1.3; lift = -3 }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                go(.spring(response: 0.35, dampingFraction: 0.5)) { scale = 1; lift = 0 }
            }
        }
    }

    /// Короткий прыжок на каждое событие, пока агент работает.
    private func bounce() {
        guard mood == .working, !reduceMotion,
              Date().timeIntervalSince(lastBounce) >= Self.bounceInterval else { return }
        lastBounce = Date()
        bounceTask?.cancel()
        bounceTask = Task {
            go(.easeOut(duration: 0.12)) { lift = -3; scale = 1.08 }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            go(.spring(response: 0.3, dampingFraction: 0.6)) { lift = 0; scale = 1 }
        }
    }
}
