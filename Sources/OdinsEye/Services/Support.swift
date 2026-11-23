import Foundation

/// `~/Library/Application Support/OdinsEye` — where everything the app keeps of
/// its own lives.
///
/// One place for the path, because four stores were each spelling out the same
/// three lines: find the support directory, append the app's name, make sure it
/// exists. Identical every time, and the kind of thing that stays identical
/// only until one copy is edited and the others are not.
enum Support {
    /// The folder itself, created on first use. Repeated calls are cheap —
    /// `createDirectory` with `withIntermediateDirectories` is content to find
    /// the folder already there.
    static let folder: URL = {
        let fm = FileManager.default
        // `ODINSEYE_SUPPORT_DIR` уводит всё, что приложение хранит, в другую папку:
        // так проверка E2E и предпросмотр не трогают настоящий config.json и сокет.
        let url: URL
        if let override = ProcessInfo.processInfo.environment["ODINSEYE_SUPPORT_DIR"], !override.isEmpty {
            url = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OdinsEye", isDirectory: true)
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A file inside it, with the folder guaranteed to exist by the time the
    /// path is handed back — which is the only reason this is a function and
    /// not string concatenation at the call site.
    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A subfolder inside it, created the same way.
    static func directory(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Один экземпляр на папку данных. Два экземпляра (установленное приложение и
/// сборка из исходников, оба в автозапуске) держат каждый свою копию настроек и
/// отбирают друг у друга сокет агента. Замок снимается сам, когда процесс умирает.
enum SingleInstance {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let fd = open(Support.file("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }
}
