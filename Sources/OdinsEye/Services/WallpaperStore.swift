import AppKit
import AVFoundation
import Combine
import IOKit.ps

/// Когда видео-обоям играть. Отдельно от стора и без AppKit: это единственная
/// часть, где есть что проверять тестом, остальное — окна и плеер.
///
/// Окна при этом стоят, пока обои включены и видео выбрано: на паузе на экране
/// остаётся последний кадр, а не голый рабочий стол.
struct WallpaperPolicy: Equatable {
    var enabled = false
    var hasVideo = false
    var screensAsleep = false
    /// Сессия пользователя не на экране (быстрое переключение пользователей,
    /// экран блокировки после выхода).
    var sessionInactive = false
    var onBattery = false
    var pauseOnBattery = true
    var lowPowerMode = false
    /// Ни одно окно обоев не видно: рабочий стол закрыт полноэкранными окнами.
    var covered = false

    /// Есть ли что показывать вообще.
    var showsWindows: Bool { enabled && hasVideo }

    var shouldPlay: Bool {
        guard showsWindows else { return false }
        if screensAsleep || sessionInactive || covered { return false }
        if lowPowerMode { return false }
        if onBattery && pauseOnBattery { return false }
        return true
    }
}

/// Живые обои рабочего стола: одно видео по кругу, без звука, под значками.
///
/// Один плеер на все экраны — кадры декодируются один раз, а слоёв на него
/// столько же, сколько мониторов. Окно на каждый экран стоит на уровне окна
/// рабочего стола плюс один: выше системных обоев, ниже значков и всех
/// обычных окон. Клики окно пропускает.
///
/// Берёт процессор и батарею, поэтому играет только когда его видно и когда
/// это не жалко: на питании от батареи по умолчанию пауза, в режиме низкого
/// энергопотребления тоже, пока экран спит или рабочий стол закрыт
/// полноэкранным окном — тоже.
///
/// Экран блокировки отсюда недоступен: окно обычного приложения над ним не
/// поднимается без обходных путей через системные папки.
@MainActor
final class WallpaperStore: ObservableObject {
    /// Видео и переключатели лежат в `config.json`; здесь только их зеркало
    /// для панели.
    @Published private(set) var isEnabled: Bool
    @Published private(set) var videoPath: String?
    @Published private(set) var pauseOnBattery: Bool
    /// Почему выбранное видео не играет, одной строкой для панели.
    @Published private(set) var problem: String?
    /// Играет ли сейчас кадр. Для подписи в панели.
    @Published private(set) var isPlaying = false

    private var policy = WallpaperPolicy()
    private var running = false

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var power: PowerSourceWatcher?
    private var loadTask: Task<Void, Never>?

    init() {
        let config = ConfigStore.shared
        isEnabled = config.wallpaperEnabled
        videoPath = config.wallpaperVideoPath
        pauseOnBattery = config.wallpaperPauseOnBattery
    }

    var videoName: String? {
        videoPath.map { ($0 as NSString).lastPathComponent }
    }

    // MARK: - Жизненный цикл

    /// Вызывается, пока вкладка на рельсе. Убрали вкладку — `stop`: скрытая
    /// вкладка ничего не крутит.
    func start() {
        guard !running else { return }
        running = true
        policy.enabled = isEnabled
        policy.hasVideo = videoPath != nil
        policy.pauseOnBattery = pauseOnBattery
        policy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        observe()
        refreshPower()
        rebuild()
    }

    func stop() {
        guard running else { return }
        running = false
        loadTask?.cancel()
        loadTask = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers = []
        power?.stop()
        power = nil
        tearDownWindows()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
    }

    // MARK: - Что пользователь меняет

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        ConfigStore.shared.wallpaperEnabled = on
        policy.enabled = on
        if running { rebuild() }
    }

    func setPauseOnBattery(_ on: Bool) {
        pauseOnBattery = on
        ConfigStore.shared.wallpaperPauseOnBattery = on
        policy.pauseOnBattery = on
        apply()
    }

    /// Окно выбора файла. Включает обои сразу: выбрал видео — хочет его видеть.
    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = localized("Choose Wallpaper Video")
        panel.message = localized("The video plays on the desktop, muted, on a loop.")
        panel.prompt = localized("Choose")
        panel.allowedContentTypes = [.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.use(video: url) }
        }
    }

    func use(video url: URL) {
        videoPath = url.path
        ConfigStore.shared.wallpaperVideoPath = url.path
        policy.hasVideo = true
        problem = nil
        if !isEnabled { setEnabled(true) } else if running { rebuild() }
    }

    func removeVideo() {
        videoPath = nil
        ConfigStore.shared.wallpaperVideoPath = nil
        policy.hasVideo = false
        problem = nil
        if isEnabled { setEnabled(false) } else if running { rebuild() }
    }

    // MARK: - Окна и плеер

    /// Собирает всё заново: окна по числу экранов и плеер под выбранный файл.
    /// Зовётся при смене видео, включении и смене набора экранов.
    private func rebuild() {
        loadTask?.cancel()
        guard policy.showsWindows, let path = videoPath else {
            tearDownWindows()
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            isPlaying = false
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            problem = localized("The video file is gone")
            tearDownWindows()
            isPlaying = false
            return
        }
        loadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }
            self?.finishRebuild(asset: asset, playable: playable)
        }
    }

    private func finishRebuild(asset: AVURLAsset, playable: Bool) {
        guard running, policy.showsWindows else { return }
        guard playable else {
            problem = localized("This file cannot be played")
            tearDownWindows()
            isPlaying = false
            return
        }
        problem = nil

        looper?.disableLooping()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        // Без этого обои держали бы дисплей включённым, как фильм.
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
        player = queue

        tearDownWindows()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let window = WallpaperWindow(screen: screen, player: queue)
            windows[id] = window
            window.orderFrontRegardless()
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCovered() }
            })
        }
        refreshCovered()
        apply()
    }

    private func tearDownWindows() {
        for window in windows.values { window.close() }
        windows = [:]
    }

    /// Обои закрыты, если ни одно из окон не видно. Одного закрытого экрана из
    /// нескольких мало: на втором они всё ещё нужны.
    private func refreshCovered() {
        let visible = windows.values.contains { $0.occlusionState.contains(.visible) }
        policy.covered = !windows.isEmpty && !visible
        apply()
    }

    /// Ставит плеер на паузу или в ход по текущему положению дел.
    private func apply() {
        guard let player else {
            isPlaying = false
            return
        }
        if policy.shouldPlay {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    // MARK: - Что слушаем

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (WallpaperStore) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }
        add(.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuild() }
        add(workspace, NSWorkspace.screensDidSleepNotification) { $0.policy.screensAsleep = true; $0.apply() }
        add(workspace, NSWorkspace.screensDidWakeNotification) { $0.policy.screensAsleep = false; $0.apply() }
        add(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.policy.sessionInactive = true; $0.apply() }
        add(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.policy.sessionInactive = false; $0.apply() }
        add(.default, .NSProcessInfoPowerStateDidChange) {
            $0.policy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.apply()
        }
        let watcher = PowerSourceWatcher { [weak self] in self?.refreshPower() }
        watcher.start()
        power = watcher
    }

    private func refreshPower() {
        policy.onBattery = PowerSourceWatcher.isOnBattery
        apply()
    }
}

// MARK: - Окно

/// Окно одного экрана: чёрное, без рамки, на уровне рабочего стола. Клики
/// пропускает, фокус не берёт, на всех рабочих столах стоит одно и то же.
private final class WallpaperWindow: NSWindow {
    init(screen: NSScreen, player: AVPlayer) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        canHide = false

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        contentView = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Питание

/// Сообщает, когда мак переключился между сетью и батареей. IOKit отдаёт это
/// только через источник на run loop, поэтому тут немного C.
private final class PowerSourceWatcher {
    private final class Box: @unchecked Sendable {
        let fire: @MainActor () -> Void
        init(_ fire: @escaping @MainActor () -> Void) { self.fire = fire }
    }

    private let box: Box
    private var source: CFRunLoopSource?
    private var retained: Unmanaged<Box>?

    init(onChange: @escaping @MainActor () -> Void) {
        box = Box(onChange)
    }

    func start() {
        let retained = Unmanaged.passRetained(box)
        self.retained = retained
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { box.fire() } }
        }, retained.toOpaque()) else {
            retained.release()
            self.retained = nil
            return
        }
        let source = created.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
        retained?.release()
        retained = nil
    }

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
