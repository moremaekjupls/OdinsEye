import AppKit
import Combine
import SwiftUI

/// Настроение аватара и его сценарий.
///
/// Анимация идёт только по событиям: смена настроения, вспышка взгляда на
/// каждое событие хука. Между ними ничего не анимируется, SwiftUI не
/// перерисовывает, процессор не занят. Это сознательное отличие от
/// маскота, который крутится на 60 кадрах всё время.
@MainActor
final class AvatarModel: ObservableObject {
    enum Mood: Equatable, Sendable {
        case asleep, thinking, working, waiting, done
    }

    // Что рисует глаз. Меняются внутри `withAnimation`.
    @Published private(set) var look: CGSize = .zero
    @Published private(set) var openness: Double = 0.22
    @Published private(set) var pupil: Double = 1
    @Published private(set) var scale: Double = 1

    @Published private(set) var mood: Mood = .asleep
    /// Есть ли вообще за кем следить: без сессий аватара нет.
    @Published private(set) var isPresent = false
    /// Основная панель раскрыта и закрывает собой место аватара.
    @Published private(set) var isCovered = false
    @Published private(set) var skin: NSImage?

    var isShown: Bool { isPresent && !isCovered }

    private let skins: AvatarSkins
    private var cancellables = Set<AnyCancellable>()
    private var script: Task<Void, Never>?
    private var glanceTask: Task<Void, Never>?
    private var lastGlance = Date.distantPast
    /// Не чаще одного взгляда за это время: событий может быть много в секунду,
    /// а каждая анимация стоит перерисовки на 60 кадрах.
    static let glanceInterval: TimeInterval = 1.5
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
            .sink { [weak self] _ in self?.glance() }
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

    static func tint(for mood: Mood) -> Color {
        switch mood {
        case .asleep: return Color(white: 0.55)
        case .thinking, .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        }
    }

    var tint: Color { Self.tint(for: mood) }

    // MARK: - Сценарий

    private func update(sessions: [AgentSession], hasPending: Bool) {
        guard let next = Self.mood(for: sessions, hasPending: hasPending) else {
            isPresent = false
            script?.cancel()
            glanceTask?.cancel()
            return
        }
        isPresent = true
        guard next != mood || skin == nil && skins.image(for: next) != nil else { return }
        mood = next
        skin = skins.image(for: next)
        play(next)
    }

    private func go(_ animation: Animation = .easeInOut(duration: 0.35), _ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(animation, change) }
    }

    private func play(_ mood: Mood) {
        script?.cancel()
        glanceTask?.cancel()
        switch mood {
        case .asleep:
            go(.easeInOut(duration: 0.6)) { openness = 0.22; look = .zero; pupil = 1; scale = 1 }
        case .thinking:
            go { openness = 0.85; pupil = 1; scale = 1 }
            guard !reduceMotion else { return }
            // Глаз обводит взглядом комнату и замирает, глядя вверх.
            script = Task {
                for x in [-0.8, 0.8, -0.8, 0.0] {
                    guard !Task.isCancelled else { return }
                    go(.easeInOut(duration: 0.45)) { look = CGSize(width: x, height: -0.2) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !Task.isCancelled else { return }
                go(.easeOut(duration: 0.3)) { look = CGSize(width: 0, height: -0.3) }
            }
        case .working:
            go { openness = 0.95; pupil = 0.9; look = .zero; scale = 1 }
        case .waiting:
            go(.spring(response: 0.3, dampingFraction: 0.7)) { openness = 1; pupil = 1.3; look = .zero }
            guard !reduceMotion else { return }
            script = Task {
                for _ in 0..<3 {
                    guard !Task.isCancelled else { return }
                    go(.easeOut(duration: 0.25)) { scale = 1.18 }
                    try? await Task.sleep(for: .milliseconds(300))
                    go(.easeIn(duration: 0.3)) { scale = 1 }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        case .done:
            go { scale = 1 }
            guard !reduceMotion else { go { openness = 0.9; pupil = 1; look = .zero }; return }
            // Моргнуть и открыться: «закончил».
            script = Task {
                go(.easeIn(duration: 0.08)) { openness = 0.05 }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                go(.easeOut(duration: 0.2)) { openness = 0.9; pupil = 1; look = .zero }
            }
        }
    }

    /// Короткий взгляд в сторону на каждое событие, пока агент работает.
    private func glance() {
        guard mood == .working, !reduceMotion,
              Date().timeIntervalSince(lastGlance) >= Self.glanceInterval else { return }
        lastGlance = Date()
        let directions = [CGSize(width: -0.8, height: 0), CGSize(width: 0.8, height: 0),
                          CGSize(width: 0, height: -0.7), CGSize(width: 0.5, height: 0.5)]
        glanceTask?.cancel()
        glanceTask = Task {
            go(.easeOut(duration: 0.15)) { look = directions.randomElement() ?? .zero }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            go(.easeInOut(duration: 0.3)) { look = .zero }
        }
    }
}
