import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var caffeineItem: NSMenuItem?
    private var headerItem: NSMenuItem?
    private var keepAwakeDurationItems: [KeepAwake.Duration: NSMenuItem] = [:]
    private var keepAwakeDisplayItem: NSMenuItem?
    private let settingsWindow = SettingsWindowController()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
        // `OdinsEye --settings`: opens the window at launch, for checking it
        // without hunting for the menu bar icon.
        if CommandLine.arguments.contains("--settings") { openSettings() }
        // The icon turns into a cup while "Не спать" is on, whoever turned it
        // on, so the mode is visible without opening anything.
        controller?.keepAwake?.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.showKeepAwake(active) }
            }
            .store(in: &cancellables)
    }

    /// Releases the "Не спать" assertion and writes the clipboard history.
    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
    }

    /// Launching OdinsEye.app again while it runs — from Finder, Spotlight or
    /// Launchpad — opens the panel. There is no Dock icon and, most of the
    /// time, no menu bar icon, so this is the gesture that is always there.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.toggle()
        return true
    }

    // MARK: - Menu bar item

    /// The one place outside the notch: Settings, Caffeine and Quit. The
    /// panel itself stays about what is glanced at; configuration and the
    /// mode that changes how the Mac behaves live here.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusImage(awake: false)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let settings = NSMenuItem(title: localized("Settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let caffeine = NSMenuItem(title: localized("Caffeine"), action: nil, keyEquivalent: "")
        caffeine.submenu = makeCaffeineMenu()
        menu.addItem(caffeine)
        caffeineItem = caffeine

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func statusImage(awake: Bool) -> NSImage? {
        let name = awake ? "cup.and.saucer.fill" : "eye"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Odin's Eye")
        image?.isTemplate = true
        return image
    }

    private func showKeepAwake(_ active: Bool) {
        statusItem?.button?.image = statusImage(awake: active)
    }

    private func makeCaffeineMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // "Не спать — 1:23", filled in when the menu opens.
        let header = NSMenuItem(title: localized("Keep Awake"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        headerItem = header

        // Picking the duration that is running turns it off, so the tick is
        // also the off switch; picking another restarts the clock with it.
        for duration in KeepAwake.Duration.allCases {
            let entry = NSMenuItem(title: duration.title, action: #selector(pickKeepAwake(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = duration.rawValue
            menu.addItem(entry)
            keepAwakeDurationItems[duration] = entry
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: localized("Keep Display On"), action: #selector(toggleKeepAwakeDisplay), keyEquivalent: "")
        display.target = self
        menu.addItem(display)
        keepAwakeDisplayItem = display
        let off = NSMenuItem(title: localized("Turn Off"), action: #selector(turnOffKeepAwake), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        return menu
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshKeepAwakeItems()
    }

    // MARK: - Keep awake

    @objc private func pickKeepAwake(_ sender: NSMenuItem) {
        guard let keepAwake = controller?.keepAwake,
              let raw = sender.representedObject as? String,
              let duration = KeepAwake.Duration(rawValue: raw) else { return }
        if keepAwake.isActive, keepAwake.duration == duration {
            keepAwake.stop()
        } else {
            keepAwake.start(duration)
        }
    }

    @objc private func toggleKeepAwakeDisplay() {
        controller?.keepAwake?.keepsDisplayOn.toggle()
    }

    @objc private func turnOffKeepAwake() {
        controller?.keepAwake?.stop()
    }

    private func refreshKeepAwakeItems() {
        guard let keepAwake = controller?.keepAwake else { return }
        if let left = keepAwake.remainingText() {
            headerItem?.title = localized("Keep Awake — %@", left)
        } else {
            headerItem?.title = localized("Keep Awake")
        }
        for (duration, entry) in keepAwakeDurationItems {
            entry.state = keepAwake.isActive && keepAwake.duration == duration ? .on : .off
        }
        keepAwakeDisplayItem?.state = keepAwake.keepsDisplayOn ? .on : .off
    }

    // MARK: - Panel, privacy, quit

    @objc private func openSettings() {
        guard let vm = controller?.viewModel else { return }
        settingsWindow.show(vm: vm)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
