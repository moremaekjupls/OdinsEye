import AppKit
import ServiceManagement
import SwiftUI

/// Отдельное окно настроек: открывается из значка в строке меню, а не из
/// панели в чёлке. Слева боковая панель со страницами по группам, справа
/// карточки с переключателями.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(vm: NotchViewModel) {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsRoot(vm: vm))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = localized("Settings")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.minSize = NSSize(width: 700, height: 480)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Pages

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, media, lockScreen, appearance, behavior, focus, tabs, privacy, caffeine, screenshots, configuration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return localized("General")
        case .media: return localized("Media")
        case .lockScreen: return localized("Lock Screen")
        case .appearance: return localized("Appearance")
        case .behavior: return localized("Behavior")
        case .focus: return localized("Focus")
        case .tabs: return localized("Tabs")
        case .privacy: return localized("Privacy")
        case .caffeine: return localized("Caffeine")
        case .screenshots: return localized("Screenshots")
        case .configuration: return localized("Configuration")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .media: return "play.fill"
        case .lockScreen: return "lock.fill"
        case .appearance: return "square.stack.3d.up"
        case .behavior: return "hand.tap"
        case .focus: return "moon.fill"
        case .tabs: return "sidebar.right"
        case .privacy: return "eye.slash"
        case .caffeine: return "cup.and.saucer"
        case .screenshots: return "photo.on.rectangle"
        case .configuration: return "doc.text"
        }
    }

    /// Группы боковой панели; у «Общих» заголовка нет.
    static let groups: [(title: String?, pages: [SettingsPage])] = [
        (nil, [.general]),
        (localized("Music"), [.media, .lockScreen]),
        (localized("Notch"), [.appearance, .behavior, .focus, .tabs, .privacy]),
        (localized("Extras"), [.caffeine, .screenshots]),
        (localized("Odin's Eye"), [.configuration]),
    ]
}

// MARK: - Root

private struct SettingsRoot: View {
    @ObservedObject var vm: NotchViewModel
    @State private var page: SettingsPage = .general
    @State private var query = ""

    private var matches: [SettingsPage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
                .background(Color.black.opacity(0.18))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsPageView(page: page, vm: vm)
                }
                .padding(.horizontal, 28)
                .padding(.top, 44)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WindowBackdrop())
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField(localized("Search"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .padding(.bottom, 10)

                ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                    let pages = group.pages.filter(matches.contains)
                    if !pages.isEmpty {
                        if let title = group.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 10)
                                .padding(.top, 14)
                                .padding(.bottom, 2)
                        }
                        ForEach(pages) { item in sidebarRow(item) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 44)
            .padding(.bottom, 16)
        }
    }

    private func sidebarRow(_ item: SettingsPage) -> some View {
        let selected = item == page
        return Button { page = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.14)))
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.12) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Размытая подложка окна: сквозь неё видны обои, как в системных настройках.
private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // «Уменьшить прозрачность»: плотная подложка без размытия обоев.
        view.material = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .windowBackground : .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 16)
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }
}

/// Ползунок прозрачности стекла, как «Liquid Glass» в системных настройках:
/// слева прозрачное, справа затемнённое. Значок на каждом конце показывает край.
private struct GlassLevelRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Image(systemName: "square.on.square")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Slider(value: $value, in: SettingsSnapshot.glassTintRange).frame(width: 190)
            Image(systemName: "square.on.square.fill")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: "%.0f%%", (1 - value / SettingsSnapshot.glassTintRange.upperBound) * 100))
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            Slider(value: $value, in: range).frame(width: 190)
            Text(verbatim: format(value))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 24)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }
}

private struct ActionRow: View {
    let title: String
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

private struct PageTitle: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.symbol).font(.system(size: 20, weight: .semibold))
            Text(page.title).font(.system(size: 26, weight: .bold))
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Page content

private struct SettingsPageView: View {
    let page: SettingsPage
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var keepAwake: KeepAwake
    @ObservedObject private var privacy: PrivacyMode
    @ObservedObject private var focusMonitor: FocusStateMonitor
    @ObservedObject private var avatar: AvatarModel

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var watchScreenshotFolder = false
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)

    init(page: SettingsPage, vm: NotchViewModel) {
        self.page = page
        self.vm = vm
        self.keepAwake = vm.keepAwake
        self.privacy = vm.privacy
        self.focusMonitor = vm.focus
        self.avatar = vm.avatar
    }

    var body: some View {
        PageTitle(page: page)
        switch page {
        case .general: general
        case .media: media
        case .lockScreen: lockScreenPage
        case .appearance: appearance
        case .behavior: behavior
        case .focus: focusPage
        case .tabs: tabs
        case .privacy: privacyPage
        case .caffeine: caffeine
        case .screenshots: screenshots
        case .configuration: configuration
        }
    }

    private func flag(_ keyPath: ReferenceWritableKeyPath<ConfigStore, Bool>) -> Binding<Bool> {
        Binding(get: { config[keyPath: keyPath] }, set: { config[keyPath: keyPath] = $0 })
    }

    private func number(_ keyPath: ReferenceWritableKeyPath<ConfigStore, Double>) -> Binding<Double> {
        Binding(get: { config[keyPath: keyPath] }, set: { config[keyPath: keyPath] = $0 })
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        VStack(spacing: 4) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            }
            Text("Odin's Eye").font(.system(size: 20, weight: .bold))
            Text(verbatim: Bundle.main.shortVersion).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)

        Card(localized("Profiles")) {
            profileRow
            RowDivider()
            ActionRow(title: localized("Save Current as Profile")) { config.addProfile(from: config.snapshot) }
        }

        Card {
            ToggleRow(title: localized("Launch at Login"), isOn: launchAtLoginBinding)
        }

        Card(localized("Visibility")) {
            ToggleRow(title: localized("Hide in Fullscreen"), isOn: flag(\.hideInFullscreen))
            RowDivider()
            ToggleRow(title: localized("Hide from Screen Capture"), isOn: flag(\.hideFromCapture))
        }
    }

    /// Включён тот профиль, с которым настройки совпадают сейчас: отдельного
    /// «текущего профиля» не хранится, поэтому он не расходится с тем, что
    /// человек потом подкрутил руками.
    private var profileRow: some View {
        let current = config.snapshot
        let profiles = SettingsProfile.builtIn + config.customProfiles
        let activeID = profiles.first { $0.settings.matches(current: current) }?.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(profiles) { profile in
                    let selected = profile.id == activeID
                    Button { vm.apply(profile) } label: {
                        Text(verbatim: profile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : 0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !profile.isBuiltIn {
                            Button(localized("Delete Profile"), role: .destructive) { config.deleteProfile(id: profile.id) }
                        }
                    }
                }
                if activeID == nil {
                    Text(localized("Custom")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 4)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 48)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("OdinsEye: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    // MARK: Media

    @ViewBuilder private var media: some View {
        Card(localized("Lyrics")) {
            ToggleRow(
                title: localized("Song Lyrics"),
                isOn: Binding(get: { vm.lyrics.isEnabled }, set: { vm.lyrics.setEnabled($0) })
            )
        }
        Card(localized("Color")) {
            ToggleRow(title: localized("Match Song Color"), isOn: flag(\.matchSongColor))
            if config.matchSongColor {
                RowDivider()
                SliderRow(
                    title: localized("Color Strength"), value: number(\.songColorStrength),
                    range: SettingsSnapshot.songColorRange)
            }
        }
    }

    // MARK: Lock Screen

    @ViewBuilder private var lockScreenPage: some View {
        if config.lockScreenTripped {
            Card {
                Text(localized("Turned off automatically: the last session ended while the card was on the lock screen (a hang, a restart or a crash). Turn it on again only if you want to try once more."))
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Card {
            ToggleRow(
                title: localized("Music on Lock Screen"),
                isOn: Binding(get: { vm.lockScreen.isEnabled }, set: { vm.lockScreen.setEnabled($0) })
            )
            .disabled(!vm.lockScreen.isAvailable)
        }
        if #available(macOS 26.0, *) {
            Card(localized("Glass")) {
                GlassLevelRow(title: localized("Player"), value: number(\.lockGlassTint))
            }
        }
        Card(localized("Status")) {
            Text(vm.lockScreen.isAvailable
                 ? localized("Shows the cover and a small player under the system clock while the Mac is locked: previous, play or pause, next and, for Apple Music, a heart. Only the buttons take clicks, nothing takes the keyboard, and the password field stays the system's.")
                 : localized("Unavailable: this macOS does not provide what the card needs."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            RowDivider()
            Text(localized("It uses private macOS functions and may stop working after an update. If the Mac ever hangs with it on, hold the power button: after the restart the card turns itself off."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Appearance

    @ViewBuilder private var appearance: some View {
        if #available(macOS 26.0, *) {
            Card(localized("Glass")) {
                ToggleRow(title: localized("Glass Panel"), isOn: flag(\.glass))
                if config.glass {
                    RowDivider()
                    GlassLevelRow(title: localized("Notch Panel"), value: number(\.glassTint))
                }
            }
        } else {
            Text(localized("The glass panel needs macOS 26 or later."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    // MARK: Behavior

    @ViewBuilder private var behavior: some View {
        Card(localized("Panel")) {
            SliderRow(
                title: localized("Open Delay"), value: number(\.openDelay), range: SettingsSnapshot.openDelayRange,
                format: { String(format: "%.2f s", $0) })
        }
        Card(localized("Agent")) {
            ToggleRow(
                title: localized("Show Agent in Notch"),
                isOn: Binding(get: { avatar.isEnabled }, set: { avatar.setEnabled($0) }))
        }
        Card(localized("Feedback")) {
            ToggleRow(title: localized("Haptic Touch"), isOn: flag(\.haptics))
            RowDivider()
            ToggleRow(title: localized("Peeky Sounds"), isOn: flag(\.sounds))
        }
    }

    // MARK: Focus

    @ViewBuilder private var focusPage: some View {
        Card {
            ToggleRow(title: localized("Focus Overlay"), isOn: flag(\.focusOverlay))
        }
        Card(localized("Status")) {
            HStack {
                Text(focusStatus).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            if focusMonitor.availability == .unreadable {
                RowDivider()
                ActionRow(title: localized("Open Full Disk Access Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var focusStatus: String {
        switch focusMonitor.availability {
        case .unknown: return localized("Checking…")
        case .unreadable: return localized("Can't read Focus state. Allow Odin's Eye in Full Disk Access.")
        case .ok:
            if let mode = focusMonitor.active { return localized("Focus is on: %@", mode.name) }
            return localized("No Focus is on")
        }
    }

    // MARK: Tabs

    @ViewBuilder private var tabs: some View {
        Card(localized("Show in Panel")) {
            let hideable = NotchViewModel.Tab.rail.filter(\.canHide)
            ForEach(Array(hideable.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { RowDivider() }
                ToggleRow(
                    title: tab.title,
                    isOn: Binding(get: { vm.isVisible(tab) }, set: { vm.setVisible(tab, $0) })
                )
            }
        }
    }

    // MARK: Privacy

    @ViewBuilder private var privacyPage: some View {
        Card(localized("Hide Contents")) {
            ToggleRow(
                title: localized("All"),
                isOn: Binding(get: { privacy.coversAll }, set: { privacy.setCoveringAll($0) })
            )
            ForEach(PrivacyMode.Section.allCases) { section in
                RowDivider()
                ToggleRow(
                    title: section.title,
                    isOn: Binding(get: { privacy.covers(section) }, set: { privacy.setCovering(section, $0) })
                )
            }
        }
    }

    // MARK: Caffeine

    @ViewBuilder private var caffeine: some View {
        Card {
            ToggleRow(
                title: keepAwakeTitle,
                isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { on in on ? keepAwake.start(keepAwake.duration) : keepAwake.stop() }
                )
            )
        }
        Card(localized("Duration")) {
            HStack(spacing: 6) {
                ForEach(KeepAwake.Duration.allCases) { duration in
                    let selected = keepAwake.duration == duration
                    Button {
                        if keepAwake.isActive { keepAwake.start(duration) } else { keepAwake.duration = duration }
                    } label: {
                        Text(verbatim: duration.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : 0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            RowDivider()
            ToggleRow(title: localized("Keep Display On"), isOn: $keepAwake.keepsDisplayOn)
        }
    }

    private var keepAwakeTitle: String {
        guard let left = keepAwake.remainingText() else { return localized("Keep Awake") }
        return localized("Keep Awake — %@", left)
    }

    // MARK: Screenshots

    @ViewBuilder private var screenshots: some View {
        Card {
            ToggleRow(
                title: localized("Save Clipboard Screenshots"),
                isOn: Binding(
                    get: { saveClipboardImages },
                    set: { saveClipboardImages = $0; NotchViewModel.saveClipboardImagesEnabled = $0 }
                )
            )
            RowDivider()
            ToggleRow(title: localized("Watch Screenshots Folder"), isOn: watchScreenshotFolderBinding)
        }
        .onAppear {
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            watchScreenshotFolder = vm.screenshotFolder.isEnabled
            refreshUsage()
        }
        Card {
            ActionRow(title: localized("Show Screenshots Folder")) { ScreenshotVault.reveal() }
            RowDivider()
            ActionRow(title: clearTitle, destructive: true, disabled: screenshotUsage.files == 0) {
                ScreenshotVault.clear()
                vm.shelf.load()
                vm.shelf.refreshFromDisk()
                refreshUsage()
            }
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    /// Включение идёт через панель выбора папки: само согласие даёт
    /// `requestAccess`, поэтому переключатель следует за результатом.
    private var watchScreenshotFolderBinding: Binding<Bool> {
        Binding(
            get: { watchScreenshotFolder },
            set: { wants in
                if wants {
                    vm.screenshotFolder.requestAccess { granted in watchScreenshotFolder = granted }
                } else {
                    vm.screenshotFolder.disable()
                    watchScreenshotFolder = false
                }
            }
        )
    }

    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: Configuration

    @ViewBuilder private var configuration: some View {
        Card {
            if config.fileBroken {
                ActionRow(title: localized("config.json is broken — click to open; nothing is overwritten")) {
                    ConfigStore.reveal()
                }
                RowDivider()
            }
            ActionRow(title: localized("Show Config File")) { ConfigStore.reveal() }
            RowDivider()
            ActionRow(title: localized("Show Snippets File")) { vm.snippets.reveal() }
        }
        Card {
            ActionRow(title: localized("Reset to Defaults"), destructive: true) {
                if let normal = SettingsProfile.builtIn.first { vm.apply(normal) }
            }
        }
    }
}
