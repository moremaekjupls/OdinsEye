import AppKit

/// Окно над настоящим экраном блокировки.
///
/// Публичного способа у macOS нет. Рабочий путь знают давно: закрытый оконный
/// сервер SkyLight, в нём создаётся отдельное пространство с абсолютным
/// уровнем, на котором система рисует Центр уведомлений на блокировке, и окно
/// кладётся в это пространство. Способ взят из открытых проектов под лицензией
/// MIT: [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) и
/// [jonnyoo/glance](https://github.com/jonnyoo/glance), см. `NOTICE.md`.
///
/// Риск: это закрытые функции Apple. Обновление macOS может их убрать, тогда
/// `make()` вернёт nil и приложение останется обычным.
///
/// Пространство живёт только пока экран заблокирован: `open()` при блокировке,
/// `close()` сразу после разблокировки. Ничего не остаётся в оконном сервере.
@MainActor
final class SkyLightSpace {
    /// Уровень, на котором система рисует Центр уведомлений при блокировке.
    /// Выше не поднимаем: чем выше, тем больше шансов закрыть системное.
    static let lockScreenLevel: Int32 = 400

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpacesCall = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private typealias SpaceDestroy = @convention(c) (Int32, Int32) -> Int32

    private let mainConnection: MainConnectionID
    private let create: SpaceCreate
    private let setLevel: SpaceSetAbsoluteLevel
    private let show: SpacesCall
    private let hide: SpacesCall
    private let add: SpaceAddWindowsAndRemoveFromSpaces
    private let remove: RemoveWindowsFromSpaces
    private let destroy: SpaceDestroy

    private var connection: Int32 = 0
    private var space: Int32?

    /// nil, если фреймворк или любая из нужных функций не нашлась.
    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let a = dlsym(handle, "SLSMainConnectionID"),
              let b = dlsym(handle, "SLSSpaceCreate"),
              let c = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let d = dlsym(handle, "SLSShowSpaces"),
              let e = dlsym(handle, "SLSHideSpaces"),
              let f = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
              let g = dlsym(handle, "SLSRemoveWindowsFromSpaces"),
              let h = dlsym(handle, "SLSSpaceDestroy")
        else { return nil }
        mainConnection = unsafeBitCast(a, to: MainConnectionID.self)
        create = unsafeBitCast(b, to: SpaceCreate.self)
        setLevel = unsafeBitCast(c, to: SpaceSetAbsoluteLevel.self)
        show = unsafeBitCast(d, to: SpacesCall.self)
        hide = unsafeBitCast(e, to: SpacesCall.self)
        add = unsafeBitCast(f, to: SpaceAddWindowsAndRemoveFromSpaces.self)
        remove = unsafeBitCast(g, to: RemoveWindowsFromSpaces.self)
        destroy = unsafeBitCast(h, to: SpaceDestroy.self)
    }

    var isOpen: Bool { space != nil }

    /// Создаёт и показывает пространство. Вызывается на блокировке.
    func open() {
        guard space == nil else { return }
        connection = mainConnection()
        // Флаг 1 обязателен: с другим значением Finder рисует в это пространство
        // значки рабочего стола.
        let id = create(connection, 1, 0)
        _ = setLevel(connection, id, Self.lockScreenLevel)
        _ = show(connection, [id] as CFArray)
        space = id
    }

    /// Кладёт окно в пространство. Только пока экран заблокирован.
    func delegate(_ window: NSWindow) {
        guard let space else { return }
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
    }

    /// Возвращает окно в обычное состояние.
    func undelegate(_ window: NSWindow) {
        guard let space else { return }
        _ = remove(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }

    /// Прячет и удаляет пространство. Вызывается сразу после разблокировки.
    func close() {
        guard let space else { return }
        _ = hide(connection, [space] as CFArray)
        _ = destroy(connection, space)
        self.space = nil
    }
}
