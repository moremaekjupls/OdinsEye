import AppKit
import SwiftUI

/// Одна поверхность-стекло для всего приложения: панель в чёлке, карточка на
/// экране блокировки. Общая, чтобы стекло везде выглядело одинаково.
///
/// Из чего оно сделано, снизу вверх:
/// 1. Системное стекло (`glassEffect`, macOS 26) или материал: размытие и
///    насыщение того, что лежит за окном, как в самой macOS.
/// 2. Тёмный оттенок: текст на панели белый, и на светлых обоях без него он
///    не читается. Одна ручка: `tint`.
/// 3. Волосяная рамка с яркой верхней кромкой: свет цепляется за край, и
///    поверхность выглядит как предмет, а не как дыра в окне.
///
/// «Уменьшить прозрачность» в системных настройках отключает стекло: остаётся
/// плотная поверхность с той же рамкой, без размытия.
struct GlassSurface<S: Shape>: View {
    let shape: S
    /// Основа оттенка: чёрная или подмешанный цвет обложки.
    var color: Color = .black
    /// Насколько оттенок закрывает стекло, от 0 до 1.
    var tint: Double = 0.45
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Color(white: 0.11))
            } else {
                glass
                shape.fill(color.opacity(tint))
                // Блик: свет падает сверху слева и гаснет к середине. Чем стекло
                // прозрачнее, тем он заметнее, иначе прозрачное стекло плоское.
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16 * (1 - tint) + 0.04), .clear],
                        startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.5)))
                    .allowsHitTesting(false)
            }
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.42), Color.white.opacity(0.08), Color.white.opacity(0.14)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
    }

    /// `glassEffect` есть только в SDK macOS 26 (Swift 6.2 и новее). `#available`
    /// решает, что делать при запуске, но не спасает от ошибки компиляции на
    /// старом SDK, поэтому сам вызов закрыт ещё и проверкой компилятора. Раннер
    /// CI собирает старым Xcode и получает материал.
    @ViewBuilder
    private var glass: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
        #else
        shape.fill(.ultraThinMaterial)
        #endif
    }
}
