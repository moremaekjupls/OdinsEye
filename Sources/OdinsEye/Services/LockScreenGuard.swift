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

    /// Верх раскладки: под системными часами и датой.
    static let topFraction: CGFloat = 0.32
    /// Низ экрана принадлежит системе: поле пароля и Touch ID.
    static let reservedBottomFraction: CGFloat = 0.26
    /// Плеер: высота таблетки, зазор до обложки, ширина колонки, предел обложки.
    static let playerHeight: CGFloat = 128
    static let gap: CGFloat = 14
    static let columnWidth: CGFloat = 360
    static let maxCover: CGFloat = 340
    /// Обложка меньше этого не показывается: на низком экране остаётся один плеер.
    static let minCover: CGFloat = 110

    /// Что где стоит: окно, сторона обложки (0, если не помещается) и высота плеера.
    struct Layout: Equatable {
        var frame: CGRect
        var coverSide: CGFloat
        var playerHeight: CGFloat

        /// Окно, пока обложка скрыта: один плеер на месте верха раскладки.
        var collapsedFrame: CGRect {
            CGRect(x: frame.minX, y: frame.maxY - playerHeight, width: frame.width, height: playerHeight)
        }
    }

    /// Раскладка в координатах экрана: колонка по центру под часами, обложка над
    /// плеером, всё целиком выше нижней зоны, даже на низком или узком экране.
    /// Обложка занимает то, что остаётся от плеера, но не больше `maxCover`.
    static func layout(on screen: CGRect) -> Layout {
        let top = screen.maxY - screen.height * topFraction
        let floor = screen.minY + screen.height * reservedBottomFraction
        let available = max(top - floor, 0)
        let width = min(columnWidth, screen.width * 0.9)
        let player = min(playerHeight, available)
        var cover = min(maxCover, width, available - player - gap)
        if cover < minCover { cover = 0 }
        let height = cover > 0 ? cover + gap + player : player
        let frame = CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
        return Layout(frame: frame, coverSide: cover, playerHeight: player)
    }
}
