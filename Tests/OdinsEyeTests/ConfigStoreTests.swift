import Foundation
import Testing
@testable import OdinsEye

/// Тесты на `ConfigStore`: то, что человек выставил в настройках, не должно
/// возвращаться к старому. Каждый тест работает со своим файлом во временной
/// папке; настоящий `config.json` не читается и не пишется.
@MainActor
struct ConfigStoreTests {
    private static func tempFile() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("odinseye-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("config.json")
    }

    /// Баг, который дошёл до Дамира: два экземпляра приложения (установленное и
    /// сборка из исходников, оба в автозапуске) держат по своей копии файла, и
    /// второй, записав свою настройку, стирал ползунок, который сдвинул первый.
    @Test func twoStoresOnOneFileDoNotEraseEachOther() throws {
        let file = try Self.tempFile()
        let a = ConfigStore(file: file)
        let b = ConfigStore(file: file)
        a.glassTint = 0.1
        b.sounds = false
        let c = ConfigStore(file: file)
        #expect(c.glassTint == 0.1)
        #expect(c.sounds == false)
    }

    /// Ползунок шлёт запись на каждом кадре перетаскивания: в файле остаётся последнее.
    @Test func dragKeepsTheLastValue() throws {
        let file = try Self.tempFile()
        let store = ConfigStore(file: file)
        for i in 0...300 { store.glassTint = 0.9 - Double(i) * 0.003 }
        let expected = store.glassTint
        #expect(ConfigStore(file: file).glassTint == expected)
    }

    /// Ключ, которого эта версия не знает (его записала более новая), переживает запись.
    @Test func unknownKeysSurviveAWrite() throws {
        let file = try Self.tempFile()
        try Data(#"{"glassTint":0.5,"futureSetting":{"a":1}}"#.utf8).write(to: file)
        let store = ConfigStore(file: file)
        store.sounds = false
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(raw.contains("futureSetting"))
    }

    /// Прозрачность плеера и панели независимы.
    @Test func lockAndPanelTintAreIndependent() throws {
        let store = ConfigStore(file: try Self.tempFile())
        store.glassTint = 0.2
        store.lockGlassTint = 0.7
        #expect(store.glassTint == 0.2 && store.lockGlassTint == 0.7)
    }

    /// «Сбросить настройки» применяет профиль «Обычный». Он должен совпадать с
    /// тем, что получает свежая установка, иначе сброс молча меняет вид (стекло
    /// включено по умолчанию, а профиль его выключал).
    @Test func defaultProfileMatchesAFreshInstall() throws {
        let fresh = ConfigStore(file: try Self.tempFile())
        let normal = SettingsProfile.builtIn[0].settings
        #expect(normal.matches(current: fresh.snapshot))
    }

    /// Сброс возвращает и прозрачность плеера, не только панели.
    @Test func resetRestoresBothTints() throws {
        let store = ConfigStore(file: try Self.tempFile())
        store.glassTint = 0.1
        store.lockGlassTint = 0.8
        store.applyLook(SettingsProfile.builtIn[0].settings)
        #expect(abs(store.glassTint - 0.6) < 0.001 && abs(store.lockGlassTint - 0.3) < 0.001)
    }
}
