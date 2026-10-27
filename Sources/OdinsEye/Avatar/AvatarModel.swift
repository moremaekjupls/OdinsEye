import AppKit
import Combine
import SwiftUI

/// Мост между сессиями Claude Code и Peeky: по состояниям и событиям ставит
/// настроение и толкает движок. Сама анимация в `PeekyEngine`.
@MainActor
final class AvatarModel: ObservableObject {
    typealias Mood = PeekyMood

    /// `nil`, если картинок нет: тогда аватара нет вовсе.
    let engine: PeekyEngine?

    @Published private(set) var mood: PeekyMood = .asleep
    /// Есть ли вообще за кем следить: без сессий «ухо» пустое.
    @Published private(set) var isPresent = false
    /// Основная панель раскрыта и закрывает собой «ухо».
    @Published private(set) var isCovered = false
    /// Состояния первых четырёх сессий: точки в правом «ухе».
    @Published private(set) var dots: [AgentSession.State] = []

    /// Где Peeky на экране, для взгляда за курсором: в «ухе» и в панели.
    var earAnchor: CGPoint = .zero
    var panelAnchor: CGPoint = .zero

    /// Через сколько без событий бодрствующий Peeky засыпает.
    static let defaultDozeAfter: TimeInterval = 120
    private let dozeAfter: TimeInterval

    var isShown: Bool { isPresent && !isCovered && engine != nil }

    private var cancellables = Set<AnyCancellable>()
    private var dozeTask: Task<Void, Never>?
    private var isDozing = false
    private var sessions: [AgentSession] = []
    private var hasPending = false

    init(
        store: AgentSessionStore, poses: [PeekyMood: PeekyPose]? = PeekyAssets.loadBundled(),
        dozeAfter: TimeInterval = AvatarModel.defaultDozeAfter
    ) {
        engine = poses.map(PeekyEngine.init(poses:))
        self.dozeAfter = dozeAfter

        // Значения берём из самого события: `@Published` сообщает до
        // присваивания, и чтение свойства стора из замыкания дало бы старое.
        Publishers.CombineLatest(store.$sessions, store.$pending)
            .sink { [weak self] sessions, pending in
                self?.update(sessions: sessions, hasPending: !pending.isEmpty)
            }
            .store(in: &cancellables)
        store.events
            .sink { [weak self] _ in self?.eventArrived() }
            .store(in: &cancellables)
    }

    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
    }

    /// Настроение по худшему состоянию среди сессий. Ожидающий запрос
    /// разрешения важнее любого состояния.
    static func mood(for sessions: [AgentSession], hasPending: Bool) -> PeekyMood? {
        guard !sessions.isEmpty || hasPending else { return nil }
        if hasPending { return .waiting }
        switch sessions.map(\.state).max() {
        case .waiting: return .waiting
        case .working: return .working
        case .thinking: return .thinking
        case .finished: return .done
        default: return .awake
        }
    }

    private func update(sessions: [AgentSession], hasPending: Bool) {
        self.sessions = sessions
        self.hasPending = hasPending
        guard let next = Self.mood(for: sessions, hasPending: hasPending) else {
            isPresent = false
            dots = []
            dozeTask?.cancel()
            isDozing = false
            apply(.asleep)
            return
        }
        isPresent = true
        dots = sessions.prefix(4).map(\.state)
        if next != .awake { isDozing = false }
        apply(next == .awake && isDozing ? .asleep : next)
        if next == .awake, !isDozing { scheduleDoze() }
    }

    /// Любое событие будит Peeky и толкает его.
    private func eventArrived() {
        if isDozing {
            isDozing = false
            update(sessions: sessions, hasPending: hasPending)
        }
        engine?.poke(now: CACurrentMediaTime())
        if mood == .awake { scheduleDoze() }
    }

    private func apply(_ next: PeekyMood) {
        guard next != mood else { return }
        mood = next
        engine?.setMood(next, now: CACurrentMediaTime())
    }

    private func scheduleDoze() {
        dozeTask?.cancel()
        dozeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.dozeAfter ?? Self.defaultDozeAfter))
            guard !Task.isCancelled, let self, self.mood == .awake else { return }
            self.isDozing = true
            self.apply(.asleep)
        }
    }
}
