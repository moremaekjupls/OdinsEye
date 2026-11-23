import AppKit
import Combine
import os
import SwiftUI

private let lockLog = Logger(subsystem: "com.moremaekjupls.odinseye", category: "lockscreen")

/// Карточка «сейчас играет» на экране блокировки: обложка, название, исполнитель,
/// звучащая строка текста. Только показ.
///
/// Первая версия намеренно мала. Окно не ловит мышь, не становится key, не
/// занимает низ экрана, не держит дисплей включённым и не вызывает
/// `NSApp.activate`: пароль и Touch ID остаются полностью системными. Кнопок нет.
/// Окно живёт в отдельном пространстве SkyLight (см. `SkyLightSpace`) только
/// пока экран заблокирован.
///
/// Перед показом пишется метка `LockScreenGuard`, после снятия окна стирается.
@MainActor
final class LockScreenPlayer: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isEnabled: Bool
    let isAvailable: Bool

    private let media: MediaController
    private let lyrics: LyricsStore
    private let guardMark: LockScreenGuard
    private let screen: () -> NSScreen?
    private var space: SkyLightSpace?
    private var watcher: LockScreenWatcher?
    private var panels: [NSPanel] = []
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var activity: NSObjectProtocol?
    /// Раскрытая обложка: окно растёт под неё и сжимается обратно.
    let cover = LockCoverState()
    private(set) var cardFrame: CGRect = .zero
    private var screenFrame: CGRect = .zero

    /// Зовётся при каждой смене блокировки: тексту песни нужно загружаться,
    /// пока панель закрыта.
    var onLockChange: ((Bool) -> Void)?

    init(
        media: MediaController, lyrics: LyricsStore, enabled: Bool = ConfigStore.shared.lockScreenPlayer,
        guardMark: LockScreenGuard = LockScreenGuard(), screen: @escaping () -> NSScreen?
    ) {
        self.media = media
        self.lyrics = lyrics
        self.isEnabled = enabled
        self.guardMark = guardMark
        self.screen = screen
        self.isAvailable = SkyLightSpace() != nil
        cover.$expanded
            .dropFirst()
            .removeDuplicates()
            // @Published сообщает до записи значения: окно меняет размер на следующем
            // обороте, иначе вид перерисуется ещё со старым состоянием.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in MainActor.assumeIsolated { self?.resizeForCover(expanded) } }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        let watcher = LockScreenWatcher { [weak self] locked in self?.lockChanged(locked) }
        watcher.start()
        self.watcher = watcher
        media.$track
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildIfShown() } }
            .store(in: &cancellables)
        // Дисплей и система засыпают прямо на блокировке. Окна и пространство
        // снимаются до сна (метка при этом стирается, потому что окна сняты) и
        // ставятся заново после пробуждения, если экран всё ещё заблокирован.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.sleeping() } }
                .store(in: &cancellables)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.woke() } }
                .store(in: &cancellables)
        }
    }

    /// Выход из приложения: окно снимается, метка стирается.
    func stop() {
        started = false
        watcher?.stop()
        watcher = nil
        cancellables.removeAll()
        hide()
        isLocked = false
        endActivity()
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        ConfigStore.shared.lockScreenPlayer = on
        if on { ConfigStore.shared.lockScreenTripped = false }
        refresh()
    }

    private func lockChanged(_ locked: Bool) {
        lockLog.notice("system says locked=\(locked, privacy: .public) was=\(self.isLocked, privacy: .public)")
        guard locked != isLocked else { return }
        isLocked = locked
        onLockChange?(locked)
        refresh()
    }

    private func refresh() {
        let wanted = !isAsleep && LockScreenPolicy.shows(
            enabled: isEnabled, available: isAvailable, locked: isLocked, hasTrack: media.track != nil)
        if wanted {
            if panels.isEmpty { show() }
        } else {
            hide()
        }
    }

    /// Пока дисплей или система спят, окна не нужны.
    private var isAsleep = false

    private func sleeping() {
        lockLog.notice("sleep: taking the windows down")
        isAsleep = true
        hide()
    }

    private func woke() {
        lockLog.notice("wake: locked=\(self.isLocked, privacy: .public)")
        isAsleep = false
        // Система ещё поднимает экран блокировки: даём ей секунду, чтобы окно
        // не встало раньше неё.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func rebuildIfShown() {
        guard !panels.isEmpty else { return }
        lockLog.notice("screen parameters changed, rebuilding")
        hide()
        refresh()
    }

    private func show() {
        guard let screen = screen(), let space = SkyLightSpace() else { return }
        // Метка первой: если дальше что-то пойдёт не так, она останется.
        guardMark.arm()
        let frame = LockScreenPolicy.frame(on: screen.frame)
        // Одно окно: карточка с кнопками. Ничего больше на блокировке не рисуется.
        cover.expanded = false
        cardFrame = frame
        screenFrame = screen.frame
        let card = LockWindow(contentRect: frame, interactive: true)
        let host = FirstMouseHostingView(
            rootView: LockControlsView(media: media, lyrics: lyrics, cover: cover, cardHeight: frame.height))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        card.contentView = host
        card.setFrame(frame, display: false)
        card.orderFrontRegardless()
        space.open()
        space.delegate(card)
        self.space = space
        self.panels = [card]
        beginActivity()
        lockLog.notice("show: card=\(NSStringFromRect(frame), privacy: .public)")
    }

    /// `OdinsEye --lock-preview`: та же карточка обычным окном посреди экрана,
    /// без SkyLight и без метки. Нужна, чтобы смотреть дизайн, не блокируя Mac.
    func showPreview() {
        guard let screen = screen() else { return }
        let size = LockScreenPolicy.cardSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        cover.expanded = false
        cardFrame = frame
        screenFrame = screen.frame
        let card = LockWindow(contentRect: frame, interactive: true)
        let host = FirstMouseHostingView(
            rootView: LockControlsView(media: media, lyrics: lyrics, cover: cover, cardHeight: frame.height))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        card.contentView = host
        card.level = .floating
        card.setFrame(frame, display: false)
        card.orderFrontRegardless()
        previewWindow = card
        // `--lock-cover`: сразу с раскрытой обложкой, чтобы смотреть её без мыши.
        if CommandLine.arguments.contains("--lock-cover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { self?.cover.expanded = true } }
            }
        }
    }

    private(set) var previewWindow: NSPanel?

    /// Раскрытие растит окно сразу (оно прозрачное, пустое место не видно), а
    /// сжатие ждёт, пока обложка вернётся в карточку: иначе её обрежет окно.
    private func resizeForCover(_ expanded: Bool) {
        guard let window = panels.first ?? previewWindow, cardFrame != .zero else { return }
        if expanded {
            window.setFrame(LockScreenPolicy.coverFrame(from: cardFrame, on: screenFrame), display: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
                MainActor.assumeIsolated {
                    guard let self, let window, !self.cover.expanded else { return }
                    window.setFrame(self.cardFrame, display: true)
                }
            }
        }
    }

    private func hide() {
        cover.expanded = false
        if let space {
            for panel in panels { space.undelegate(panel) }
            space.close()
        }
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        let hadPanels = !panels.isEmpty
        panels = []
        space = nil
        endActivity()
        // Метка стирается последней, после того как окна сняты.
        if hadPanels { guardMark.disarm(); lockLog.notice("hide: windows removed, mark cleared") }
    }

    /// На блокировке у приложения нет окон в фокусе, и система его усыпляет:
    /// текст песни пошёл бы с опозданием. Это не удержание дисплея.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Odin's Eye lock screen card")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Принимает первое нажатие сразу: приложение не активно, и без этого оно
/// ушло бы на активацию.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Не берёт клавиатуру никогда, а мышь только если это окно с кнопками: всё,
/// что на блокировке вводится, остаётся системным.
private final class LockWindow: NSPanel {
    init(contentRect: NSRect, interactive: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .darkAqua)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = !interactive
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
