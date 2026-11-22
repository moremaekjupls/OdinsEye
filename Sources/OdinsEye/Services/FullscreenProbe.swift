import AppKit

/// Есть ли на этом экране окно чужого приложения во весь экран. Нужно, чтобы
/// не раскрывать панель наведением поверх фильма или игры.
enum FullscreenProbe {
    /// Размеры окон на экране, у которых слой 0 (обычные окна приложений;
    /// Dock, меню и обои лежат в других слоях). Окно размером с экран и
    /// есть полноэкранное: развёрнутое по кнопке «зелёной» оставляет строку меню.
    static func isFullscreenAppOn(_ screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if covers(bounds: bounds, screenSize: screen.frame.size) { return true }
        }
        return false
    }

    /// Вынесено ради теста: окно считается полноэкранным, если его размер не
    /// меньше размера экрана (с запасом в точку на округление).
    static func covers(bounds: CGRect, screenSize: CGSize) -> Bool {
        bounds.width >= screenSize.width - 1 && bounds.height >= screenSize.height - 1
    }
}
