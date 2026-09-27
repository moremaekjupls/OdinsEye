import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    /// Shown only while "Не спать" is on — see `installStatusItem`.
    private var statusItem: NSStatusItem?
    private var headerItem: NSMenuItem?
    private var keepAwakeDurationItems: [KeepAwake.Duration: NSMenuItem] = [:]
    private var keepAwakeDisplayItem: NSMenuItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
        // The cup is the mode itself: it appears when "Не спать" turns on,
        // whoever turned it on, and leaves when it ends.
        controller?.keepAwake?.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.statusItem?.isVisible = active }
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

    /// The app lives in the notch, not in the menu bar. The one thing worth a
    /// place there is a mode that changes how the Mac behaves while nobody is
    /// looking at the panel — "Не спать" — so the item exists only while it is
    /// on, as a cup, and its menu opens on that mode's controls.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: localized("Keep Awake"))
        image?.isTemplate = true
        item.button?.image = image
        item.isVisible = false

        let menu = NSMenu()
        menu.delegate = self
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

        menu.addItem(.separator())
        let open = NSMenuItem(title: localized("Open Panel"), action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(makePrivacyItem())

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// Sits in the menu because it is the one people reach for in a hurry,
    /// with the camera already running. "All" comes first and is what most
    /// people will ever touch; the sections below are for when that is too much.
    private func makePrivacyItem() -> NSMenuItem {
        let privacy = NSMenuItem(title: localized("Hide Contents"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let all = NSMenuItem(title: localized("All"), action: #selector(togglePrivacyAll), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        privacyAllItem = all
        submenu.addItem(.separator())

        for section in PrivacyMode.Section.allCases {
            let entry = NSMenuItem(title: section.title, action: #selector(togglePrivacySection(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = section.rawValue
            submenu.addItem(entry)
            privacySectionItems[section] = entry
        }
        privacy.submenu = submenu
        privacyItem = privacy
        return privacy
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshKeepAwakeItems()
        refreshPrivacyItems()
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

    @objc private func togglePanel() {
        controller?.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePrivacyAll(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy else { return }
        // Anything short of everything means "turn the rest on too"; only a
        // full house turns them all off.
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
    /// covered, a dash when some are.
    private func refreshPrivacyItems() {
        guard let privacy = controller?.privacy else { return }
        privacyItem?.state = privacy.coversAll ? .on : (privacy.coversAny ? .mixed : .off)
        privacyAllItem?.state = privacy.coversAll ? .on : .off
        for (section, entry) in privacySectionItems {
            entry.state = privacy.covers(section) ? .on : .off
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
