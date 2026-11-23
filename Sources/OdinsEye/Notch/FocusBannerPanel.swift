import AppKit
import SwiftUI

/// Плашка у чёлки, когда Фокус включается или выключается: значок режима
/// слева, имя справа. Отдельное прозрачное окно, как у острова Peeky: клики
/// пропускает и с основной панелью не связано.
private struct FocusBannerView: View {
    @ObservedObject var monitor: FocusStateMonitor
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let ear: CGFloat

    var body: some View {
        let shown = monitor.banner
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                .fill(Color.black)
                .frame(width: notchWidth + (shown == nil ? 0 : ear * 2), height: notchHeight)
            if let shown {
                HStack(spacing: 0) {
                    Image(systemName: NSImage(systemSymbolName: shown.mode.symbol, accessibilityDescription: nil) == nil
                          ? "moon.fill" : shown.mode.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(shown.isOn ? FocusFiles.color(named: shown.mode.tint) : Color.white.opacity(0.4))
                        .frame(width: ear)
                    Color.clear.frame(width: notchWidth)
                    Text(verbatim: shown.isOn ? shown.mode.name : localized("%@ Off", shown.mode.name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(shown.isOn ? 0.92 : 0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: ear - 6, alignment: .leading)
                        .padding(.leading, 6)
                }
                .frame(height: notchHeight)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(shown == nil ? 0 : 1)
        .id(shown?.id)
        .animation(Theme.openAnimation, value: shown == nil)
    }
}

@MainActor
final class FocusBannerPanel {
    private static let ear: CGFloat = 96
    private var panel: NotchPanel?

    init(geometry: NotchGeometry, monitor: FocusStateMonitor) {
        let margin: CGFloat = 8
        let size = CGSize(
            width: geometry.notchSize.width + Self.ear * 2 + margin * 2,
            height: geometry.notchSize.height + 8)
        let frame = CGRect(
            x: geometry.notchCenterX - size.width / 2,
            y: geometry.screen.frame.maxY - size.height,
            width: size.width, height: size.height)
        let panel = NotchPanel(contentRect: frame)
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: FocusBannerView(
            monitor: monitor, notchWidth: geometry.notchSize.width,
            notchHeight: geometry.notchSize.height, ear: Self.ear))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) { hosting.sizingOptions = [] }
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func teardown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
