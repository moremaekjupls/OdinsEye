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

    static let cardSize = CGSize(width: 440, height: 168)
    /// Верхняя граница карточки: под системными часами.
    static let topFraction: CGFloat = 0.36
    /// Низ экрана принадлежит системе: поле пароля и Touch ID.
    static let reservedBottomFraction: CGFloat = 0.26

    /// Рамка карточки в координатах экрана: по центру, под часами, и целиком
    /// выше нижней зоны, даже на очень низком экране.
    static func frame(on screen: CGRect) -> CGRect {
        let top = screen.maxY - screen.height * topFraction
        let floor = screen.minY + screen.height * reservedBottomFraction
        let height = min(cardSize.height, max(top - floor, 0))
        return CGRect(
            x: screen.midX - cardSize.width / 2, y: top - height,
            width: cardSize.width, height: height)
    }
}
