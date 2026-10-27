import AppKit
import Combine
import SwiftUI

/// Лицо аватара: картинка пользователя с движениями из модели.
struct AvatarFace: View {
    @ObservedObject var model: AvatarModel

    var body: some View {
        if let skin = model.skin {
            Image(nsImage: skin)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .opacity(model.dim)
                .rotationEffect(.degrees(model.tilt))
                .offset(y: model.lift)
                .scaleEffect(model.scale)
        }
    }
}

/// Выступ слева от чёлки, в котором живёт аватар: продолжение чёлки, чёрное,
/// с закруглением снизу слева.
private struct AvatarEar: View {
    @ObservedObject var model: AvatarModel
    let size: CGSize

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: Theme.collapsedBottomRadius,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
            )
            .fill(Color.black)
            AvatarFace(model: model)
                .padding(.leading, 2)
        }
        .frame(width: size.width, height: size.height)
        .opacity(model.isShown ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: model.isShown)
    }
}

/// Отдельное прозрачное окно слева от чёлки. Клики пропускает: ничего под ним
/// не должно перестать нажиматься, а раскрытием панели по-прежнему управляет
/// только курсор у чёлки. Основной панели оно не касается совсем: её тонкая
/// логика наведения и сворачивания осталась как была.
///
/// Окно стоит всегда, а прячется прозрачностью: показ и скрытие окна дёргали
/// бы порядок окон. Без сессий оно пустое и ничего не рисует.
@MainActor
final class AvatarPanel {
    /// Ширина выступа: картинка 26 пт плюс поля.
    static let earWidth: CGFloat = 36

    private var panel: NotchPanel?

    init(geometry: NotchGeometry, model: AvatarModel) {
        let size = CGSize(width: Self.earWidth, height: geometry.notchSize.height)
        // Внахлёст на пункт с чёлкой, чтобы между ними не мелькал шов.
        let frame = CGRect(
            x: geometry.notchCenterX - geometry.notchSize.width / 2 - size.width + 1,
            y: geometry.screen.frame.maxY - size.height,
            width: size.width, height: size.height
        )
        let panel = NotchPanel(contentRect: frame)
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: AvatarEar(model: model, size: size))
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
