import AppKit
import Combine
import SwiftUI

/// Режим Фокуса: имя, значок и цвет, как они записаны в настройках macOS.
struct FocusMode: Equatable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var tint: String
}

/// Разбор файлов Фокуса. Чистые функции без обращения к диску: файлы лежат в
/// `~/Library/DoNotDisturb/DB/`, формат не документирован, поэтому читаем
/// осторожно и ничего не считаем обязательным.
enum FocusFiles {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)

    /// Все режимы по идентификатору.
    static func modes(from data: Data) -> [String: FocusMode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["data"] as? [[String: Any]] else { return [:] }
        var result: [String: FocusMode] = [:]
        for block in blocks {
            guard let configs = block["modeConfigurations"] as? [String: Any] else { continue }
            for (id, value) in configs {
                guard let mode = (value as? [String: Any])?["mode"] as? [String: Any] else { continue }
                let name = mode["name"] as? String ?? id
                let symbol = mode["symbolImageName"] as? String
                    ?? mode["symbolDescriptorImageName"] as? String ?? "moon.fill"
                result[id] = FocusMode(id: id, name: name, symbol: symbol, tint: mode["tintColorName"] as? String ?? "")
            }
        }
        return result
    }

    /// Идентификатор включённого сейчас режима или nil, если Фокус выключен.
    /// Ищется только среди действующих записей (`storeAssertionRecords`):
    /// записи об отмене лежат рядом и режимом не являются.
    static func activeModeID(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["data"] as? [[String: Any]] else { return nil }
        for block in blocks {
            guard let records = block["storeAssertionRecords"] as? [Any] else { continue }
            for record in records {
                if let id = find("assertionDetailsModeIdentifier", in: record) { return id }
            }
        }
        return nil
    }

    private static func find(_ key: String, in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] as? String { return found }
            for child in dict.values { if let found = find(key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = find(key, in: child) { return found } }
        }
        return nil
    }

    static func color(named name: String) -> Color {
        switch name {
        case "systemIndigoColor": return .indigo
        case "systemOrangeColor": return .orange
        case "systemGreenColor": return .green
        case "systemTealColor": return .teal
        case "systemPurpleColor": return .purple
        case "systemMintColor": return .mint
        case "systemBlueColor": return .blue
        case "systemRedColor": return .red
        case "systemPinkColor": return .pink
        case "systemYellowColor": return .yellow
        case "systemCyanColor": return .cyan
        case "systemBrownColor": return .brown
        default: return .white
        }
    }
}

/// Следит за Фокусом и объявляет, когда режим включился или выключился.
///
/// Читает те же файлы, что и сама macOS, без закрытого API и без окон над
/// системными экранами. Если доступа к папке нет (ей может требоваться
/// «Полный доступ к диску»), `availability` говорит об этом, и настройки
/// объясняют, что делать, а не молчат.
@MainActor
final class FocusStateMonitor: ObservableObject {
    enum Availability { case unknown, ok, unreadable }

    struct Banner: Equatable, Identifiable {
        let id = UUID()
        let mode: FocusMode
        let isOn: Bool
    }

    @Published private(set) var active: FocusMode?
    @Published private(set) var availability = Availability.unknown
    @Published private(set) var banner: Banner?

    /// Можно ли сейчас показать баннер: панель открыта поверх, значит нет.
    var canShowBanner: () -> Bool = { true }

    private var modes: [String: FocusMode] = [:]
    private var activeID: String?
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        refresh(announce: false)
        watchDirectory()
        // Папку смотрит и сторож, но файлы подменяются целиком, и событие
        // иногда не приходит: раз в несколько секунд перечитываем два файла.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(announce: true) }
        }
    }

    func stop() {
        started = false
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        hideTask?.cancel()
    }

    private func watchDirectory() {
        let fd = open(FocusFiles.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh(announce: true) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func refresh(announce: Bool) {
        let assertions = FocusFiles.directory.appendingPathComponent("Assertions.json")
        guard let data = try? Data(contentsOf: assertions) else {
            availability = .unreadable
            return
        }
        availability = .ok
        if let config = try? Data(contentsOf: FocusFiles.directory.appendingPathComponent("ModeConfigurations.json")) {
            modes = FocusFiles.modes(from: config)
        }
        let id = FocusFiles.activeModeID(from: data)
        guard id != activeID else { return }
        let previousID = activeID
        activeID = id
        active = id.map { modes[$0] ?? FocusMode(id: $0, name: $0, symbol: "moon.fill", tint: "") }
        guard announce, ConfigStore.shared.focusOverlay, canShowBanner() else { return }
        if let id {
            show(Banner(mode: active ?? FocusMode(id: id, name: id, symbol: "moon.fill", tint: ""), isOn: true))
        } else if let previousID {
            show(Banner(mode: modes[previousID] ?? FocusMode(id: previousID, name: previousID, symbol: "moon.fill", tint: ""), isOn: false))
        }
    }

    private func show(_ next: Banner) {
        hideTask?.cancel()
        withAnimation(Theme.openAnimation) { banner = next }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.closeAnimation) { self?.banner = nil }
        }
    }
}
