import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// This screen's share of the panel. Everything the pointer decides is
    /// here; everything shown is in `vm`, the same on every display.
    @ObservedObject var panel: PanelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { panel.isActive }
    private var size: CGSize { panel.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    /// Whether the shape is painted at all.
    ///
    /// Folded over the notch there is nothing to paint: the notch is a hole,
    /// and a hole is already black. The filled shape on top of it would be
    /// invisible — but only while what is behind it stays black. The window is
    /// `.stationary` and joins every space, so in Mission Control and
    /// mid-swipe between spaces the desktop shrinks away and a painted "notch"
    /// is left hanging in the air as a second, squarer notch.
    ///
    /// Asked of the body rather than of `isOpen`: folded, `bodySize` is the
    /// notch itself, so any future state that grows the folded strip paints
    /// itself without anyone remembering to come back here.
    private var paintsShape: Bool {
        size != panel.geometry.notchSize
    }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            .fill(paintsShape ? Color.black : Color.clear)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                header
                if isOpen {
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(isOpen ? Theme.openAnimation : Theme.closeAnimation, value: isOpen)
        .animation(Theme.paneAnimation, value: vm.tab)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            if isOpen {
                // Sentence case, like a window title — the one label in the
                // panel that says where you are.
                Text(vm.tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: panel.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if isOpen {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: panel.geometry.notchSize.height)
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName ?? "")
                    .font(.panelCaptionMedium)
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .snippets:
            counter(vm.snippets.items.count)
        case .currency:
            CurrencyRateDate(currencies: vm.currencies)
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.panelCaptionMedium.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm, panel: panel, tabs: vm.rail)
            panes
            PanelControls(vm: vm, keepAwake: vm.keepAwake, panel: panel)
        }
        .padding(.horizontal, 14)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(paneTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// With Reduce Motion on, panes cross-fade and nothing scales.
    private var paneTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(Theme.paneIn)
        }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.98))
                .animation(Theme.paneIn),
            removal: .opacity
                .combined(with: .scale(scale: 1.01))
                .animation(Theme.paneOut)
        )
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            MediaPane(media: vm.media)
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: panel.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard, privacy: vm.privacy)
        case .snippets:
            SnippetsPane(snippets: vm.snippets, privacy: vm.privacy, wantsKeyboard: $panel.wantsKeyboard)
        case .currency:
            CurrencyPane(currencies: vm.currencies, wantsKeyboard: $panel.wantsKeyboard)
        case .settings:
            SettingsPane(vm: vm, shelf: vm.shelf, screenshots: vm.screenshotFolder, keepAwake: vm.keepAwake)
        }
    }
}

/// Observes the store on its own: rate fetches must not redraw the whole panel
/// on every keystroke in the amount fields, so the date badge observes the
/// store on its own.
private struct CurrencyRateDate: View {
    @ObservedObject var currencies: CurrencyStore

    var body: some View {
        if let date = currencies.rateDate {
            Text(date)
                .font(.panelCaptionMedium.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var panel: PanelState
    let tabs: [NotchViewModel.Tab]

    @State private var hovered: NotchViewModel.Tab?

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { tab in
                Button {
                    panel.select(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: panel.geometry.railIconHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(fill(for: tab))
                        )
                        .foregroundStyle(vm.tab == tab ? Color.white : (hovered == tab ? Theme.secondary : Theme.tertiary))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                // Highlight, not growth: macOS marks the item under the pointer
                // with its background, and icons that swell on hover read as a
                // web page.
                .buttonStyle(.pressable)
                .help(tab.title)
                .onHover { inside in
                    if inside {
                        hovered = tab
                    } else if hovered == tab {
                        hovered = nil
                    }
                }
            }
        }
        .frame(width: 30)
        .frame(height: panel.geometry.standardContentHeight, alignment: .center)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            panel.select(hovered)
        }
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}

/// The panel's own switches, in the column the notes used to open: the pin
/// and "Не спать". Same size and look as a rail icon, but toggles rather than
/// tabs — lit while on.
private struct PanelControls: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var panel: PanelState
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            control(
                id: "pin",
                symbol: vm.isPinned ? "pin.fill" : "pin",
                isOn: vm.isPinned,
                help: vm.isPinned ? localized("Unpin Panel (Esc)") : localized("Pin Panel")
            ) {
                vm.isPinned.toggle()
            }

            control(
                id: "cup",
                symbol: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                isOn: keepAwake.isActive,
                help: localized("Keep Awake")
            ) {
                keepAwake.toggle()
            }
            .contextMenu { KeepAwakeMenu(keepAwake: keepAwake) }

            // Time left, under the cup. A minute is the finest step it shows,
            // so it is redrawn once a minute and not on every frame.
            if keepAwake.isActive {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(verbatim: keepAwake.remainingText(at: context.date) ?? "")
                        .font(.panelMini.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 30)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 30)
        .frame(height: panel.geometry.standardContentHeight, alignment: .top)
        .animation(Theme.contentAnimation, value: vm.isPinned)
        .animation(Theme.contentAnimation, value: keepAwake.isActive)
    }

    /// `id` rather than the symbol for hover: the symbol changes on click, and
    /// the highlight must not drop off the button still under the pointer.
    private func control(id: String, symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: panel.geometry.railIconHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? Theme.surfaceHover : (hovered == id ? Theme.surface : .clear))
                )
                .foregroundStyle(isOn ? Color.white : (hovered == id ? Theme.secondary : Theme.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.pressable)
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .help(help)
    }
}

/// Durations and the display option — the right-click menu of the cup, and
/// the same choices the menu bar offers.
struct KeepAwakeMenu: View {
    @ObservedObject var keepAwake: KeepAwake

    var body: some View {
        ForEach(KeepAwake.Duration.allCases) { duration in
            Button(duration.title) { keepAwake.start(duration) }
        }
        Divider()
        Toggle(localized("Keep Display On"), isOn: $keepAwake.keepsDisplayOn)
        if keepAwake.isActive {
            Divider()
            Button(localized("Turn Off")) { keepAwake.stop() }
        }
    }
}
