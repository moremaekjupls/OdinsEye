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
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var activity: NSObjectProtocol?

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
        let wanted = LockScreenPolicy.shows(
            enabled: isEnabled, available: isAvailable, locked: isLocked, hasTrack: media.track != nil)
        if wanted {
            if panel == nil { show() }
        } else {
            hide()
        }
    }

    private func rebuildIfShown() {
        guard panel != nil else { return }
        lockLog.notice("screen parameters changed, rebuilding")
        hide()
        refresh()
    }

    private func show() {
        guard let screen = screen(), let space = SkyLightSpace() else { return }
        // Метка первой: если дальше что-то пойдёт не так, она останется.
        guardMark.arm()
        let frame = LockScreenPolicy.frame(on: screen.frame)
        let panel = LockCardPanel(contentRect: frame)
        let hosting = NSHostingView(rootView: LockPlayerView(media: media, lyrics: lyrics))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        space.open()
        space.delegate(panel)
        self.space = space
        self.panel = panel
        beginActivity()
        lockLog.notice("show: frame=\(NSStringFromRect(frame), privacy: .public)")
    }

    private func hide() {
        if let panel, let space {
            space.undelegate(panel)
            space.close()
            panel.orderOut(nil)
            panel.contentView = nil
        }
        let hadPanel = panel != nil
        panel = nil
        space = nil
        endActivity()
        // Метка стирается последней, после того как окно снято.
        if hadPanel { guardMark.disarm(); lockLog.notice("hide: window removed, mark cleared") }
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

/// Не берёт ни клавиатуру, ни мышь: всё, что на блокировке нажимается, остаётся системным.
private final class LockCardPanel: NSPanel {
    init(contentRect: NSRect) {
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
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
