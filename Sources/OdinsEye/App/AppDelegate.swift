import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]
    private var keepAwakeItem: NSMenuItem?
    private var keepAwakeDurationItems: [KeepAwake.Duration: NSMenuItem] = [:]
    private var keepAwakeDisplayItem: NSMenuItem?
    private var keepAwakeOffItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
        // The icon says whether "Не спать" is on, whoever switched it.
        controller?.keepAwake?.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.updateStatusIcon(keepingAwake: active) }
            }
            .store(in: &cancellables)
    }

    /// Releases the "Не спать" assertion and writes the clipboard history.
    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
    }

    /// Reopen is the one gesture left once the icon is hidden: launching
    /// OdinsEye.app again from Finder or Spotlight while it is already running.
    /// `LSUIElement` gives it no Dock icon and no window to raise, but this
    /// delegate method still fires — it is how the icon comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        return true
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        updateStatusIcon(keepingAwake: false)
        // Lets the icon be ⌘-dragged off the bar, the way any status item can
        // be; `autosaveName` is what makes AppKit remember that across
        // relaunches on its own, the same mechanism the explicit switch in
        // Settings uses through `AppDelegate.isMenuBarIconVisible` below.
        item.behavior = .removalAllowed
        item.autosaveName = "OdinsEyeMenuBarIcon"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Odin's Eye \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // Sits next to the panel switch rather than in the Settings tab: it
        // changes what the panel shows, and it is the one people look for in a
        // hurry, with the camera already running.
        //
        // A submenu rather than a plain switch, because the tabs hold different
        // things and not everyone wants all of them covered. "All" comes first
        // and is what most people will ever touch; the sections below it are
        // for the case where that is too much.
        let privacy = NSMenuItem(title: localized("Hide Contents"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let all = NSMenuItem(title: localized("All"), action: #selector(togglePrivacyAll), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        privacyAllItem = all
        submenu.addItem(.separator())

        for section in PrivacyMode.Section.allCases {
            let item = NSMenuItem(
                title: section.title,
                action: #selector(togglePrivacySection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = section.rawValue
            submenu.addItem(item)
            privacySectionItems[section] = item
        }

        privacy.submenu = submenu
        menu.addItem(privacy)
        privacyItem = privacy

        menu.addItem(makeKeepAwakeItem())

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    /// The raven while idle — one of Odin's two, Huginn and Muninn — and a
    /// cup while "Не спать" holds the Mac awake.
    private func updateStatusIcon(keepingAwake: Bool) {
        let image = keepingAwake
            ? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: localized("Keep Awake"))
            : Self.ravenImage
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// `MenuBarIcon.pdf` from the bundle, vector at 18 pt. Run straight from
    /// SwiftPM there is no bundle to find it in, so a system bird stands in.
    private static let ravenImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "Odin's Eye"
            return image
        }
        return NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Odin's Eye")
    }()

    // MARK: - Keep awake

    /// "Не спать" ▸ Бессрочно / 1 ч / 2 ч / 4 ч · Не гасить экран · Выключить.
    /// Picking the duration that is already running turns it off, so the tick
    /// is also the off switch.
    private func makeKeepAwakeItem() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("Keep Awake"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for duration in KeepAwake.Duration.allCases {
            let item = NSMenuItem(title: duration.title, action: #selector(pickKeepAwake(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration.rawValue
            submenu.addItem(item)
            keepAwakeDurationItems[duration] = item
        }
        submenu.addItem(.separator())
        let display = NSMenuItem(title: localized("Keep Display On"), action: #selector(toggleKeepAwakeDisplay), keyEquivalent: "")
        display.target = self
        submenu.addItem(display)
        keepAwakeDisplayItem = display
        let off = NSMenuItem(title: localized("Turn Off"), action: #selector(turnOffKeepAwake), keyEquivalent: "")
        off.target = self
        submenu.addItem(off)
        keepAwakeOffItem = off
        parent.submenu = submenu
        keepAwakeItem = parent
        return parent
    }

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
        guard let keepAwake = controller?.keepAwake else { return }
        keepAwake.keepsDisplayOn.toggle()
    }

    @objc private func turnOffKeepAwake() {
        controller?.keepAwake?.stop()
    }

    private func refreshKeepAwakeItems() {
        guard let keepAwake = controller?.keepAwake else { return }
        if let left = keepAwake.remainingText() {
            keepAwakeItem?.title = localized("Keep Awake — %@", left)
            keepAwakeItem?.state = .on
        } else {
            keepAwakeItem?.title = localized("Keep Awake")
            keepAwakeItem?.state = .off
        }
        for (duration, item) in keepAwakeDurationItems {
            item.state = keepAwake.isActive && keepAwake.duration == duration ? .on : .off
        }
        keepAwakeDisplayItem?.state = keepAwake.keepsDisplayOn ? .on : .off
        keepAwakeOffItem?.isEnabled = keepAwake.isActive
    }

    @objc private func togglePanel() {
        controller?.toggle()
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPrivacyItems()
        refreshKeepAwakeItems()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePrivacyAll(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy else { return }
        // Anything short of everything means "turn the rest on too"; only a
        // full house turns them all off. One press, and no state where the
        // item says All while half the sections are open.
        privacy.setCoveringAll(!privacy.coversAll)
        refreshPrivacyItems()
    }

    @objc private func togglePrivacySection(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy,
              let raw = sender.representedObject as? String,
              let section = PrivacyMode.Section(rawValue: raw) else { return }
        privacy.setCovering(section, !privacy.covers(section))
        refreshPrivacyItems()
    }

    /// The parent item carries the summary: a tick when every section is
    /// covered, a dash when some are. Without it the state is a submenu away,
    /// and this is the one switch worth reading at a glance.
    private func refreshPrivacyItems() {
        guard let privacy = controller?.privacy else { return }
        privacyItem?.state = privacy.coversAll ? .on : (privacy.coversAny ? .mixed : .off)
        privacyAllItem?.state = privacy.coversAll ? .on : .off
        for (section, item) in privacySectionItems {
            item.state = privacy.covers(section) ? .on : .off
        }
    }
}

extension AppDelegate {
    /// Whether the status item shows at all. Reachable from the Settings tab
    /// through the one `AppDelegate` the app has, rather than
    /// threading a reference through the view hierarchy for a single switch.
    ///
    /// Nothing to migrate to `config.json`: AppKit already persists this
    /// through `autosaveName`, which is also what a ⌘-drag off the bar updates
    /// — the two paths to the same off state agree because they are the same
    /// state.
    @MainActor
    static var isMenuBarIconVisible: Bool {
        get { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible ?? true }
        set { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible = newValue }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

