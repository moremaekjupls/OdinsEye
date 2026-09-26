import SwiftUI

enum Theme {
    // MARK: Motion
    //
    // Opening follows the pointer with a touch of life; closing gets out of the
    // way faster and without overshoot — the exit is never slower than the
    // entrance. Everything else uses one strong ease-out: it starts moving the
    // frame it is asked to, which is what makes a change feel answered.

    static let openAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let closeAnimation = Animation.spring(response: 0.22, dampingFraction: 1)
    static let contentAnimation = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    static let paneIn = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22).delay(0.03)
    static let paneOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.1)
    static let artworkAnimation = Animation.easeOut(duration: 0.28)
    /// Press feedback: on the way down, so the control answers before release.
    static let press = Animation.easeOut(duration: 0.1)
    /// Switches settle without bouncing, like NSSwitch.
    static let toggle = Animation.spring(response: 0.25, dampingFraction: 1)

    // MARK: Shape

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    // MARK: Colour
    //
    // The panel is always dark, so these are the dark label and fill colours
    // of macOS, slightly lifted: the panel sits on pure black, where the
    // system values read a step dimmer than on a window background.

    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.38)
    static let surface = Color.white.opacity(0.08)
    static let surfaceHover = Color.white.opacity(0.14)
    static let surfacePressed = Color.white.opacity(0.2)
    static let hairline = Color.white.opacity(0.10)
}

// MARK: - Type
//
// One scale for the whole panel, never below 10 pt — the smallest size macOS
// itself sets text in. SF Pro picks its optical size and tracking from the
// point size, so no tracking is set by hand.

extension Font {
    /// Track title.
    static let panelTitle = Font.system(size: 16, weight: .semibold)
    /// Row text: clipboard entries, snippets, settings rows.
    static let panelBody = Font.system(size: 12)
    static let panelBodyMedium = Font.system(size: 12, weight: .medium)
    /// Secondary lines, footers, empty states.
    static let panelCaption = Font.system(size: 11)
    static let panelCaptionMedium = Font.system(size: 11, weight: .medium)
    /// Counters and the smallest labels.
    static let panelMini = Font.system(size: 10, weight: .medium)
    /// Glyphs inside row buttons.
    static let panelGlyph = Font.system(size: 10, weight: .semibold)
}

// MARK: - Buttons

/// Press feedback for plain buttons: a hair smaller and dimmer the moment the
/// button goes down, back on release.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Text button that lives in a footer or beside a field — "Clear", "Done".
/// A plate appears under the pointer, the way macOS toolbar buttons do, so it
/// is visibly a button before it is clicked.
struct PlateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlateButton(configuration: configuration)
    }

    private struct PlateButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.panelCaptionMedium)
                .foregroundStyle(hovering && isEnabled ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(
                        configuration.isPressed ? Theme.surfacePressed
                            : (hovering && isEnabled ? Theme.surfaceHover : Color.clear)
                    )
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(Theme.press, value: configuration.isPressed)
                .animation(Theme.contentAnimation, value: hovering)
                .pointerStyle(.default)
        }
    }
}

extension ButtonStyle where Self == PlateButtonStyle {
    static var plate: PlateButtonStyle { PlateButtonStyle() }
}

/// A glyph button inside a row: a 20 pt target instead of the bare glyph, a
/// plate under the pointer, press feedback, and a tooltip.
struct RowIconButton: View {
    let symbol: String
    var help: String?
    var tint: Color = Theme.secondary
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.panelGlyph)
                .foregroundStyle(disabled ? Theme.tertiary : (hovering ? Theme.primary : tint))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering && !disabled ? Theme.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .pointerStyle(.default)
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
        .modifier(OptionalHelp(text: help))
    }
}

/// `.help` only when there is something to say.
struct OptionalHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// Round transport button for the player. The small ones get a plate under
/// the pointer; the prominent one brightens. All of them give on press.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        NotchButton(configuration: configuration, size: size, prominent: prominent)
    }

    private struct NotchButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var fill: Color {
            let lit = hovering && isEnabled
            if prominent {
                return configuration.isPressed ? Theme.surfacePressed : (lit ? Color.white.opacity(0.18) : Theme.surfaceHover)
            }
            return configuration.isPressed ? Theme.surfaceHover : (lit ? Theme.surface : Color.clear)
        }

        var body: some View {
            configuration.label
                .font(.system(size: prominent ? 17 : 13, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Theme.press, value: configuration.isPressed)
                .animation(Theme.contentAnimation, value: hovering)
        }
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }
}

/// Drawn rather than `NSSwitch`-backed: the panel is a non-activating window
/// that almost never becomes key (that is what keeps hovering it from
/// stealing focus from whatever app was in front), and `NSSwitch` renders its
/// on-state in gray rather than accent blue whenever its window is not key.
/// Proportions, knob shadow and the unbouncing settle follow NSSwitch.
struct NotchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.white.opacity(0.16))
                .overlay(Capsule().strokeBorder(Color.white.opacity(configuration.isOn ? 0 : 0.08), lineWidth: 0.5))
                .frame(width: 28, height: 16)
                .overlay(
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .frame(width: 13, height: 13)
                        .offset(x: configuration.isOn ? 6 : -6)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .animation(Theme.toggle, value: configuration.isOn)
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
