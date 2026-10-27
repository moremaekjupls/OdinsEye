import AppKit
import Foundation

/// Настроение Peeky. Не то же самое, что состояние сессии: к нему добавлены
/// «бодрствует» и «спит», которых у сессии нет.
enum PeekyMood: Equatable, Sendable {
    case asleep, awake, thinking, working, waiting, done
}

/// Одна поза: тело без глаз и то, где у неё лицо и глаза.
///
/// Глаза с картинок стёрты (`Scripts/` в `assets/peeky/prep.swift`), и рисует
/// их движок: иначе моргать, смотреть за курсором и менять выражение было бы
/// нечем. Координаты нормированы к стороне квадратной картинки, y сверху.
struct PeekyPose: @unchecked Sendable {
    let image: CGImage
    let faceCenter: CGPoint
    let faceWidth: CGFloat
    let faceHeight: CGFloat
    let eyeMid: CGPoint
    /// Расстояние между глазами.
    let eyeSeparation: CGFloat
    /// Наклон линии глаз: голова у поз склонена по-разному.
    let eyeAngle: CGFloat
}

enum PeekyAssets {
    /// Какой файл за какое настроение. У «бодрствует» и «работает» одно тело:
    /// различает их движение, а не поза.
    static func file(for mood: PeekyMood) -> String {
        switch mood {
        case .asleep: return "idle"
        case .awake, .working: return "working"
        case .thinking: return "thinking"
        case .waiting: return "waiting"
        case .done: return "done"
        }
    }

    /// Из `folder`: PNG по именам выше и `rig.json`. `nil`, если чего-то нет:
    /// без поз аватара нет вовсе.
    static func load(from folder: URL) -> [PeekyMood: PeekyPose]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("rig.json")),
              let rig = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return nil }
        var poses: [PeekyMood: PeekyPose] = [:]
        for mood in [PeekyMood.asleep, .awake, .thinking, .working, .waiting, .done] {
            let name = file(for: mood)
            guard let entry = rig[name], let pose = pose(named: name, entry: entry, in: folder) else { return nil }
            poses[mood] = pose
        }
        return poses
    }

    /// Рядом с приложением, в `Contents/Resources/peeky`.
    static func loadBundled() -> [PeekyMood: PeekyPose]? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("peeky", isDirectory: true) else { return nil }
        return load(from: url)
    }

    private static func pose(named name: String, entry: [String: Any], in folder: URL) -> PeekyPose? {
        let png = folder.appendingPathComponent(name + ".png")
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let face = entry["face"] as? [String: Double],
              let cx = face["cx"], let cy = face["cy"], let w = face["w"], let h = face["h"],
              let eyes = entry["eyes"] as? [[String: Double]], eyes.count == 2,
              let ax = eyes[0]["cx"], let ay = eyes[0]["cy"], let bx = eyes[1]["cx"], let by = eyes[1]["cy"]
        else { return nil }
        let dx = bx - ax, dy = by - ay
        // Наклон ограничен: у закрытых глаз-дуг центры могут разъехаться из-за формы.
        let angle = max(-0.35, min(0.35, atan2(dy, dx)))
        // Расстояние тоже: меньше трети лица глаза слипаются.
        let separation = max(w * 0.36, min(w * 0.6, (dx * dx + dy * dy).squareRoot()))
        return PeekyPose(
            image: image, faceCenter: CGPoint(x: cx, y: cy), faceWidth: w, faceHeight: h,
            eyeMid: CGPoint(x: (ax + bx) / 2, y: (ay + by) / 2),
            eyeSeparation: separation, eyeAngle: angle
        )
    }
}
