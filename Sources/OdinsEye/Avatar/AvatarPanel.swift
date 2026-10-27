import AppKit
import Combine
import SwiftUI

/// Остров вокруг чёлки: по «ушку» с каждой стороны. Слева живёт Peeky, справа
/// точки сессий (как сетка агентов у Coucou, но по-своему: цвет точки это
/// состояние сессии). Чёлка посередине физически вырезана и ничего не рисует.
private struct AvatarIsland: View {
    @ObservedObject var model: AvatarModel
    let layout: AvatarPanel.Layout

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Чёрные «ушки»: продолжение чёлки.
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: Theme.collapsedBottomRadius,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
            )
            .fill(Color.black)
            .frame(width: layout.ear, height: layout.notchHeight)
            .offset(x: layout.margin)
            .opacity(model.isShown ? 1 : 0)

            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: Theme.collapsedBottomRadius, topTrailingRadius: 0, style: .continuous
            )
            .fill(Color.black)
            .frame(width: layout.ear, height: layout.notchHeight)
            .offset(x: layout.margin + layout.ear + layout.notchWidth)
            .opacity(model.isShown ? 1 : 0)

            // Peeky: холст выше полосы, чтобы он мог выпрыгнуть вниз.
            if let engine = model.engine {
                PeekyView(
                    engine: engine, screenAnchor: model.earAnchor, isRunning: model.isShown,
                    bodySide: 30, bottomInset: layout.overflow + 1
                )
                .frame(width: layout.ear + layout.margin * 2, height: layout.notchHeight + layout.overflow)
                .opacity(model.isShown ? 1 : 0)
            }

            dots
                .frame(width: layout.ear, height: layout.notchHeight)
                .offset(x: layout.margin + layout.ear + layout.notchWidth)
                .opacity(model.isShown ? 1 : 0)
        }
        .frame(width: layout.windowWidth, height: layout.notchHeight + layout.overflow, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: model.isShown)
    }

    /// Сетка 2×2: по точке на сессию, цвет по состоянию.
    private var dots: some View {
        let states = model.dots
        return LazyVGrid(columns: [GridItem(.fixed(9), spacing: 5), GridItem(.fixed(9), spacing: 5)], spacing: 5) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Circle().fill(state.color).frame(width: 9, height: 9)
            }
        }
        .frame(width: 23)
    }
}

/// Отдельное прозрачное окно вокруг чёлки. Клики пропускает: ничего под ним не
/// должно перестать нажиматься, а раскрытием панели по-прежнему управляет
/// только курсор у чёлки. Основной панели оно не касается совсем: её тонкая
/// логика наведения и сворачивания осталась как была.
///
/// Окно стоит всегда, а прячется прозрачностью: показ и скрытие окна дёргали
/// бы порядок окон. Без сессий оно пустое, и ничего не рисует.
@MainActor
final class AvatarPanel {
    struct Layout {
        let notchWidth: CGFloat
        let notchHeight: CGFloat
        /// Ширина «ушка».
        static let earWidth: CGFloat = 48
        var ear: CGFloat { Self.earWidth }
        /// Поле снаружи «ушек»: Peeky может выйти за них.
        let margin: CGFloat = 14
        /// Сколько окно выступает вниз за полосу меню.
        let overflow: CGFloat = 34

        var windowWidth: CGFloat { margin * 2 + ear * 2 + notchWidth }
    }

    private var panel: NotchPanel?

    init(geometry: NotchGeometry, model: AvatarModel) {
        let layout = Layout(notchWidth: geometry.notchSize.width, notchHeight: geometry.notchSize.height)
        let size = CGSize(width: layout.windowWidth, height: layout.notchHeight + layout.overflow)
        let frame = CGRect(
            x: geometry.notchCenterX - size.width / 2,
            y: geometry.screen.frame.maxY - size.height,
            width: size.width, height: size.height
        )
        // Центр Peeky в «ухе» и в панели: на экране y растёт вверх.
        let top = geometry.screen.frame.maxY
        model.earAnchor = CGPoint(x: frame.minX + layout.margin + layout.ear / 2, y: top - layout.notchHeight + 15)
        model.panelAnchor = CGPoint(x: geometry.notchCenterX - 200, y: top - 120)

        let panel = NotchPanel(contentRect: frame)
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: AvatarIsland(model: model, layout: layout))
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
