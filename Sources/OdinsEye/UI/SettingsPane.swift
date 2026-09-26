import SwiftUI
import ServiceManagement

/// What used to live in the status bar menu, minus the two items that belong
/// there: opening the panel and hiding its contents are both things people
/// reach for in a hurry, often without wanting to open the panel at all — the
/// rest is configuration, read rarely, and reads better as a tab like any
/// other than as a menu that grows a new row per feature.
struct SettingsPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    let screenshots: ScreenshotFolderWatcher
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject private var config = ConfigStore.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var menuBarIconVisible = AppDelegate.isMenuBarIconVisible
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var watchScreenshotFolder = false
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    // Off means the same thing a ⌘-drag off the bar does —
                    // both go through `AppDelegate.isMenuBarIconVisible`, so
                    // whichever one somebody used, this switch shows it.
                    toggleRow(
                        symbol: "bird.fill",
                        title: localized("Show Menu Bar Icon"),
                        isOn: menuBarIconVisibleBinding
                    )
                }

                // The rail is for what gets a glance between other things.
                // A tab used once a month is not banned from it, but it lives
                // there only as long as whoever never uses it can take it off —
                // and off means quiet too: its background stops with the icon.
                section(localized("Show in Panel")) {
                    ForEach(NotchViewModel.Tab.rail) { tab in
                        if tab.canHide {
                            toggleRow(symbol: tab.symbol, title: tab.title, isOn: visibilityBinding(tab))
                        }
                    }
                }

                // Same switch as the cup in the panel and the menu bar item:
                // here with its options spelled out.
                section(localized("Keep Awake")) {
                    toggleRow(
                        symbol: "cup.and.saucer",
                        title: keepAwakeTitle,
                        isOn: Binding(
                            get: { keepAwake.isActive },
                            set: { on in on ? keepAwake.start(keepAwake.duration) : keepAwake.stop() }
                        )
                    )
                    durationRow
                    toggleRow(
                        symbol: "display",
                        title: localized("Keep Display On"),
                        isOn: $keepAwake.keepsDisplayOn
                    )
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    toggleRow(
                        symbol: "eye",
                        title: localized("Watch Screenshots Folder"),
                        isOn: watchScreenshotFolderBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        ScreenshotVault.reveal()
                    }
                    actionRow(
                        symbol: "trash",
                        title: clearTitle,
                        disabled: screenshotUsage.files == 0
                    ) {
                        ScreenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
                    }
                }

                section(localized("Snippets")) {
                    actionRow(symbol: "doc.text", title: localized("Show Snippets File")) {
                        vm.snippets.reveal()
                    }
                }

                // What lives in this file is one file: everything
                // above that makes sense on another Mac, in one place instead
                // of five.
                section(localized("Configuration")) {
                    if config.fileBroken { configBrokenNotice }
                    actionRow(symbol: "gearshape", title: localized("Show Config File")) {
                        ConfigStore.reveal()
                    }
                }

                // The one door left once the menu bar icon is gone: a
                // status item is not required to hide it any more, so quitting
                // must not require one either. Last on purpose — leaving is
                // not something to meet on the way to a switch.
                section(localized("Odin's Eye")) {
                    actionRow(symbol: "power", title: localized("Quit Odin's Eye")) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            // Also flipped by a ⌘-drag off the bar, not only by the switch
            // below it — re-read for the same reason as the rest of this block.
            menuBarIconVisible = AppDelegate.isMenuBarIconVisible
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            watchScreenshotFolder = screenshots.isEnabled
            refreshUsage()
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("OdinsEye: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var menuBarIconVisibleBinding: Binding<Bool> {
        Binding(
            get: { menuBarIconVisible },
            set: { wants in
                menuBarIconVisible = wants
                AppDelegate.isMenuBarIconVisible = wants
            }
        )
    }

    private func visibilityBinding(_ tab: NotchViewModel.Tab) -> Binding<Bool> {
        Binding(
            get: { vm.isVisible(tab) },
            set: { wants in vm.setVisible(tab, wants) }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                NotchViewModel.saveClipboardImagesEnabled = wants
            }
        )
    }

    /// "Keep Awake", with the time left while it runs.
    private var keepAwakeTitle: String {
        guard let left = keepAwake.remainingText() else { return localized("Keep Awake") }
        return localized("Keep Awake — %@", left)
    }

    /// The four durations as chips. Picking one while on restarts the clock
    /// with it; while off, it is only remembered for the next start.
    private var durationRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Spacer(minLength: 8)
            ForEach(KeepAwake.Duration.allCases) { duration in
                let selected = keepAwake.duration == duration
                Button {
                    if keepAwake.isActive { keepAwake.start(duration) } else { keepAwake.duration = duration }
                } label: {
                    Text(verbatim: duration.shortTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Theme.secondary)
                        .frame(width: 34, height: 18)
                        .background(
                            Capsule().fill(selected ? Theme.surfaceHover : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(duration.title)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// Turning off is instant. Turning on goes through the Open panel first —
    /// `requestAccess` is itself the consent, so the switch only follows what
    /// actually happened once the panel closes, not the click that opened it.
    private var watchScreenshotFolderBinding: Binding<Bool> {
        Binding(
            get: { watchScreenshotFolder },
            set: { wants in
                if wants {
                    screenshots.requestAccess { granted in watchScreenshotFolder = granted }
                } else {
                    screenshots.disable()
                    watchScreenshotFolder = false
                }
            }
        )
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on.
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// The refusal to write over a broken file is only honest if it is
    /// said out loud — same reasoning as `SnippetsPane.brokenNotice`.
    private var configBrokenNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.85))
            Text(localized("config.json is broken — click to open; nothing is overwritten"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { ConfigStore.reveal() }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func actionRow(
        symbol: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
