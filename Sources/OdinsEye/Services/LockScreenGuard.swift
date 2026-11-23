import Foundation

/// Аварийный выход для окна на экране блокировки: метка-«мёртвая рука».
///
/// Перед показом окна метка пишется на диск, после снятия окна при разблокировке
/// удаляется. Если Mac завис и его пришлось перезагрузить (или приложение упало),
/// метка остаётся. Следующий запуск видит её, выключает функцию сам и говорит об
/// этом в настройках. Включить её снова можно только вручную.
struct LockScreenGuard {
    let url: URL

    init(url: URL = Support.file("lockscreen.armed")) {
        self.url = url
    }

    var isArmed: Bool { FileManager.default.fileExists(atPath: url.path) }

    func arm() {
        try? Data("armed \(Date())\n".utf8).write(to: url, options: .atomic)
    }

    func disarm() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Когда окно показывается и где стоит. Чистые правила.
enum LockScreenPolicy {
    static func shows(enabled: Bool, available: Bool, locked: Bool, hasTrack: Bool) -> Bool {
        enabled && available && locked && hasTrack
    }

    /// Верх карточки: под системными часами и погодой.
    static let topFraction: CGFloat = 0.38
    /// Низ экрана принадлежит системе: поле пароля и Touch ID.
    static let reservedBottomFraction: CGFloat = 0.26
    static let cardSize = CGSize(width: 400, height: 176)

    /// Рамка карточки в координатах экрана: по центру под часами и целиком
    /// выше нижней зоны, даже на низком или узком экране.
    static func frame(on screen: CGRect) -> CGRect {
        let top = screen.maxY - screen.height * topFraction
        let floor = screen.minY + screen.height * reservedBottomFraction
        let height = min(cardSize.height, max(top - floor, 0))
        let width = min(cardSize.width, screen.width * 0.9)
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}
