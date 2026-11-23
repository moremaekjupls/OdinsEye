import AppKit
import SwiftUI

/// Проверка «снаружи внутри»: настоящее приложение выполняет сценарий над собой
/// и пишет отчёт. Запускается только флагом `--e2e <отчёт.json>` и только вместе
/// с `ODINSEYE_SUPPORT_DIR`, то есть на временных данных (`Scripts/e2e.sh`).
///
/// Зачем внутри процесса: клики снаружи требуют доступа к универсальному
/// доступу, а события, отправленные прямо окну (`NSWindow.sendEvent`), идут тем же
/// путём, что и мышь, и права не просят. Это не команда по сокету агента:
/// другой процесс до неё не дотянется.
@MainActor
enum E2E {
    private struct Check: Encodable { let name: String; let ok: Bool; let detail: String }
    private static var checks: [Check] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append(Check(name: name, ok: ok, detail: detail))
        NSLog("OdinsEye e2e: %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
    }

    static func run(vm: NotchViewModel, reportPath: String) {
        guard ProcessInfo.processInfo.environment["ODINSEYE_SUPPORT_DIR"] != nil else {
            NSLog("OdinsEye e2e: refusing to run without ODINSEYE_SUPPORT_DIR")
            exit(2)
        }
        Task { @MainActor in
            await scenario(vm: vm)
            let data = (try? JSONEncoder().encode(checks)) ?? Data()
            try? data.write(to: URL(fileURLWithPath: reportPath))
            exit(checks.allSatisfy(\.ok) ? 0 : 1)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Нажатие левой кнопкой в точке окна: те же события, что даёт мышь.
    private static func click(_ window: NSWindow, at point: CGPoint) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            await sleep(0.08)
        }
    }

    private static func shot(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = Support.folder
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("e2e-\(name).png"))
    }

    private static func scenario(vm: NotchViewModel) async {
        let config = ConfigStore.shared

        // 1. Ползунки пишутся на диск и не зависят друг от друга.
        config.glassTint = 0.15
        config.lockGlassTint = 0.7
        let disk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: ConfigStore.file))) as? [String: Any]
        check("tint reaches disk", (disk?["glassTint"] as? Double).map { abs($0 - 0.15) < 0.001 } ?? false)
        check("lock tint independent", (disk?["lockGlassTint"] as? Double).map { abs($0 - 0.7) < 0.001 } ?? false)

        // 2. Второй стор на тот же файл (как второй экземпляр) не стирает ползунок.
        let other = ConfigStore(file: ConfigStore.file)
        other.sounds = false
        let again = ConfigStore(file: ConfigStore.file)
        check("second writer keeps tint", abs(again.glassTint - 0.15) < 0.001 && again.sounds == false)

        // 3. Агент: переключатель прячет остров и записывается.
        vm.avatar.setEnabled(false)
        check("agent hidden", !vm.avatar.isEnabled && !vm.avatar.isPresent && config.showAgent == false)
        vm.avatar.setEnabled(true)
        check("agent flag back", vm.avatar.isEnabled && config.showAgent == true)

        // 4. Раскладка блокировки: обложка над плеером, всё выше зоны пароля.
        vm.lockScreen.showPreview()
        await sleep(0.6)
        guard let window = vm.lockScreen.previewWindow, let layout = vm.lockScreen.layout else {
            check("preview window exists", false); return
        }
        check("starts as player only", near(window.frame, layout.collapsedFrame), "\(window.frame)")
        check("cover fits", layout.coverSide >= LockScreenPolicy.minCover, "cover \(layout.coverSide)")
        shot(window, "player")

        // Нажатие на маленькую обложку выдвигает большую, второе нажатие убирает.
        await click(window, at: CGPoint(x: 20 + 23, y: window.frame.height - 14 - 23))
        await sleep(0.7)
        check("tap shows big cover", vm.lockScreen.cover.expanded && near(window.frame, layout.frame), "\(window.frame)")
        shot(window, "cover")
        await click(window, at: CGPoint(x: window.frame.width / 2, y: window.frame.height - 40))
        await sleep(1.2)
        check("tap hides big cover", !vm.lockScreen.cover.expanded && near(window.frame, layout.collapsedFrame), "\(window.frame)")
    }
}
