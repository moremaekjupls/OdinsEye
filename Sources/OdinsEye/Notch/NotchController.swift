import AppKit
import Combine

/// Owns the one shared `NotchViewModel` — the tab, the data, the running
/// services — and the panel on the display with the notch, if one is attached.
/// Displays come and go far more often than the app relaunches, so the model
/// outlives every reconfiguration; only the window is rebuilt, and only when
/// the notch actually moved, appeared or went away.
@MainActor
final class NotchController {
    private var vm: NotchViewModel?
    private var panel: NotchScreenPanel?

    func install() {
        let vm = NotchViewModel()
        self.vm = vm
        vm.start()
        rebuild()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        onWorkspace(NSWorkspace.activeSpaceDidChangeNotification) { $0.activeSpaceChanged() }
        onWorkspace(NSWorkspace.screensDidSleepNotification) { $0.screensSlept() }
        onWorkspace(NSWorkspace.screensDidWakeNotification) { $0.screensWoke() }
    }

    /// Sleeping, waking and changing desktop are facts about the session, not
    /// about one display.
    private func onWorkspace(_ name: Notification.Name, _ body: @escaping @MainActor (NotchScreenPanel) -> Void) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return }
                body(panel)
            }
        }
    }

    func teardown() {
        vm?.stop()
        panel?.teardown()
        panel = nil
    }

    /// From the menu bar. With no notch on screen — lid closed, external
    /// monitor only — there is no panel to open, and the item does nothing.
    func toggle() {
        panel?.toggle()
    }

    /// What the menu bar switches. Handed out rather than wrapped: the menu
    /// reads and writes them directly, and a controller method per switch
    /// would only forward.
    var privacy: PrivacyMode? { vm?.privacy }
    var keepAwake: KeepAwake? { vm?.keepAwake }

    // MARK: - Display

    /// Builds the panel for the notched display, keeps it if the notch has not
    /// moved, and tears it down when the notch is gone. A screen-parameter
    /// notification fires for plenty of reasons that leave the notch exactly
    /// where it was, and rebuilding on those would throw away the open state.
    private func rebuild() {
        guard let vm else { return }
        let geometry = NotchGeometry.notched()
        if let panel, let geometry, panel.geometry.displayID == geometry.displayID,
           panel.geometry.matches(geometry) {
            panel.setFrame(geometry.windowFrame)
            return
        }
        panel?.teardown()
        panel = nil
        // The panel is gone; so is anything it was holding open.
        vm.isPinned = false
        if let geometry {
            let next = NotchScreenPanel(geometry: geometry, vm: vm)
            next.state.onChange = { [weak self] in self?.refreshShared() }
            panel = next
        }
        refreshShared()
    }

    // MARK: - Shared state

    /// Recomputes everything the shared model knows about the panel: whether
    /// anything is showing and whether anything is being typed into.
    private func refreshShared() {
        guard let vm else { return }
        let active = panel?.state.isActive ?? false
        vm.isTyping = panel?.state.wantsKeyboard ?? false
        guard active != vm.isPanelActive else { return }
        vm.setPanelActive(active)
        guard !active else { return }
        // Whatever was uncovered by hand goes back under cover with the panel.
        // The next hover is the one nobody planned, and it must not open onto
        // a row somebody revealed ten minutes ago.
        vm.privacy.coverEverything()
    }
}
