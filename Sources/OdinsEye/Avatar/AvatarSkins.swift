import AppKit

/// Свои картинки аватара: файлы в
/// `~/Library/Application Support/OdinsEye/avatar/`, по одному на настроение.
/// Нет файла для настроения — берётся `idle.png`; нет и его — аватара нет.
/// Картинка подхватывается при следующей смене настроения, перезапуск не нужен.
@MainActor
final class AvatarSkins {
    /// Имя файла без расширения для каждого настроения.
    static func fileName(for mood: AvatarModel.Mood) -> String {
        switch mood {
        case .asleep: return "idle"
        case .thinking: return "thinking"
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        }
    }

    private let folder: URL
    private var cache: [String: (stamp: Date, image: NSImage)] = [:]

    /// `folder` задаётся в тестах; по умолчанию — папка приложения.
    init(folder: URL? = nil) {
        self.folder = folder ?? Support.directory("avatar")
        writeReadme()
    }

    func image(for mood: AvatarModel.Mood) -> NSImage? {
        let url = folder.appendingPathComponent(Self.fileName(for: mood) + ".png")
        guard let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else {
            cache[url.path] = nil
            return nil
        }
        if let hit = cache[url.path], hit.stamp == stamp { return hit.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url.path] = (stamp, image)
        return image
    }

    /// Перезаписывается при каждом запуске: это наш файл, и список имён в нём
    /// должен совпадать с кодом.
    private func writeReadme() {
        let readme = folder.appendingPathComponent("README.txt")
        let text = """
        Свой аватар для Odin's Eye.

        Положите сюда PNG с прозрачным фоном (квадрат 256x256 или больше):
          idle.png      обязательный: сессии есть, агент ничего не делает.
                        Без него аватара нет вообще.
          thinking.png  Claude думает
          working.png   Claude работает с инструментами
          waiting.png   Claude ждёт вашего решения
          done.png      Claude закончил (горит пять секунды)

        Нет файла для настроения: берётся idle.png. Одной idle.png хватает,
        настроения тогда различаются движением: покачивание, прыжки, пульс.
        Картинка подхватывается при следующей смене настроения.
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }
}
