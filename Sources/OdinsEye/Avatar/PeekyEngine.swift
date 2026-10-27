import AppKit
import SwiftUI

/// Кривые для твинов.
enum PeekyEase: Sendable {
    case out, inOut, back, linear

    func apply(_ t: Double) -> Double {
        switch self {
        case .linear: return t
        case .out: return 1 - pow(1 - t, 3)
        case .inOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .back:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        }
    }
}

/// Движок анимации Peeky.
///
/// Идея у Coucou та же: персонаж это набор живых чисел (масштаб, смещение,
/// наклон, раскрытие глаз, взгляд), которые в каждом кадре двигают к целям
/// настроения, а разовые реакции играют ключевыми кадрами поверх. Реализация
/// своя и под растровое тело: тело берётся из позы, а глаза, значки и частицы
/// рисуются здесь же.
///
/// Время приходит параметром (`now`), поэтому логику можно гонять в тестах без
/// экрана. Все обращения идут с главного потока: рисует его `Canvas`, а
/// настроение ставит `AvatarModel`.
final class PeekyEngine: @unchecked Sendable {
    enum Prop: CaseIterable { case sx, sy, ox, oy, tilt, spin, open, badge, gx, gy }
    struct Key { var to: Double; var ms: Double; var ease: PeekyEase = .out }

    private struct Tween {
        var from: Double
        var keys: [Key]
        var index = 0
        var started: Double
        var done: (() -> Void)?
    }

    struct Particle {
        enum Kind { case z, spark }
        var kind: Kind
        var x: Double, y: Double       // в сторонах тела, от левого верхнего угла
        var vx: Double, vy: Double
        var age: Double, life: Double
        var size: Double
    }

    let poses: [PeekyMood: PeekyPose]
    private(set) var mood: PeekyMood = .asleep
    private(set) var value: [Prop: Double] = [
        .sx: 1, .sy: 1, .ox: 0, .oy: 0, .tilt: 0, .spin: 0, .open: 0, .badge: 0, .gx: 0, .gy: 0,
    ]
    private var tweens: [Prop: Tween] = [:]
    private(set) var particles: [Particle] = []
    /// Время последнего кадра.
    private(set) var last: Double = 0
    private var nextBlink: Double = 0
    private var doubleBlinkAt: Double?
    private var nextZ: Double = 0
    private var sparksAt: Double?
    private var greetStart: Double?
    /// Приветствие: 0 с наклон и счастливые глаза, 0,25 с рука вверх, 1,55 с
    /// рука опущена, 1,85 с конец. Сроки по образцу сценария приветствия у Coucou.
    static let greetHandUp = 0.25, greetHandDown = 1.55, greetDuration = 1.85

    /// Куда смотрит курсор относительно Peeky, от -1 до 1. Ставит тот, кто
    /// знает, где Peeky на экране.
    var cursor: CGPoint = .zero

    init(poses: [PeekyMood: PeekyPose]) { self.poses = poses }

    // MARK: - Настроение и реакции

    func setMood(_ new: PeekyMood, now: Double) {
        guard new != mood else { return }
        let old = mood
        mood = new
        // «z» принадлежат сну: проснувшись, Peeky не должен таскать их за собой.
        if old == .asleep { particles.removeAll { $0.kind == .z } }

        // Значок выезжает заново: сперва сжимается, потом вырастает с перелётом.
        let badge = Self.target(for: new).badge
        if badge > 0 {
            anim(.badge, [Key(to: 0, ms: 90, ease: .inOut), Key(to: badge, ms: 280, ease: .back)], now: now, delay: 0.1)
        }

        switch new {
        case .done:
            // Кувырок за 950 мс, потом приземление и искры.
            anim(.spin, [Key(to: 2 * .pi, ms: 950, ease: .inOut)], now: now) { [self] in
                value[.spin] = 0
                squash(now: last)
            }
            sparksAt = now + 0.5
        case .waiting:
            // Подскок: «эй, мне нужно ваше решение».
            anim(.oy, [Key(to: -0.14, ms: 150), Key(to: 0, ms: 300, ease: .back)], now: now)
        case .awake where old == .asleep:
            squash(now: now, strong: true)
        default:
            squash(now: now)
        }
    }

    /// Приветствие взмахом, когда курсор остановился у «уха». Не трогает того,
    /// кто сейчас просит решения или кувыркается. Возвращает, началось ли оно.
    @discardableResult
    func greet(now: Double) -> Bool {
        guard mood != .waiting, mood != .done else { return false }
        if let start = greetStart, now - start < Self.greetDuration + 2 { return false }
        greetStart = now
        // Присел и подпрыгнул: «привет!»
        anim(.oy, [Key(to: 0.03, ms: 80), Key(to: -0.07, ms: 150), Key(to: 0, ms: 250, ease: .back)], now: now)
        return true
    }

    /// Секунды с начала приветствия; `nil`, если его нет.
    var greetPhase: Double? {
        guard let start = greetStart, last >= start, last - start < Self.greetDuration else { return nil }
        return last - start
    }

    /// Какое тело показывать: на время взмаха это поза с поднятой рукой.
    var displayMood: PeekyMood {
        if let g = greetPhase, g >= Self.greetHandUp, g < Self.greetHandDown { return .waiting }
        return mood
    }

    /// Событие хука: короткий толчок и взгляд в сторону.
    func poke(now: Double) {
        guard mood == .working || mood == .thinking else { return }
        if tweens[.sy] == nil {
            anim(.sy, [Key(to: 0.94, ms: 60), Key(to: 1, ms: 120)], now: now)
            anim(.sx, [Key(to: 1.04, ms: 60), Key(to: 1, ms: 120)], now: now)
        }
        if tweens[.gx] == nil {
            let jump = Double.random(in: -0.9...0.9)
            anim(.gx, [Key(to: jump, ms: 90), Key(to: 0, ms: 260, ease: .inOut)], now: now)
        }
    }

    private func squash(now: Double, strong: Bool = false) {
        let (y0, x0) = strong ? (0.78, 1.16) : (0.9, 1.08)
        anim(.sy, [Key(to: y0, ms: 70), Key(to: 1.08, ms: 130), Key(to: 1, ms: 170)], now: now)
        anim(.sx, [Key(to: x0, ms: 70), Key(to: 0.95, ms: 130), Key(to: 1, ms: 170)], now: now)
    }

    // MARK: - Твины

    private func anim(_ prop: Prop, _ keys: [Key], now: Double, delay: Double = 0, done: (() -> Void)? = nil) {
        tweens[prop] = Tween(from: value[prop] ?? 0, keys: keys, started: now + delay, done: done)
    }

    private func advanceTweens(now: Double) {
        for (prop, var tween) in tweens {
            guard now >= tween.started else { continue }
            var finished = false
            while !finished {
                let key = tween.keys[tween.index]
                let elapsed = (now - tween.started) * 1000
                let k = key.ms <= 0 ? 1 : min(1, elapsed / key.ms)
                value[prop] = tween.from + (key.to - tween.from) * key.ease.apply(k)
                if k < 1 { break }
                // Ключ отыгран: следующий начинается с этого же значения и с
                // остатка времени, чтобы длинный кадр не растягивал анимацию.
                tween.from = key.to
                tween.started += key.ms / 1000
                tween.index += 1
                if tween.index >= tween.keys.count { finished = true }
            }
            if finished {
                tweens[prop] = nil
                tween.done?()
            } else {
                tweens[prop] = tween
            }
        }
    }

    // MARK: - Цели настроения

    struct Target {
        var open = 1.0, gx = 0.0, gy = 0.0, tilt = 0.0, badge = 0.0
        var breathe = 0.015, breatheRate = 1.2, bob = 0.0
    }

    static func target(for mood: PeekyMood) -> Target {
        switch mood {
        case .asleep: return Target(open: 0, badge: 0, breathe: 0.035, breatheRate: 1.8)
        case .awake, .done: return Target()
        case .thinking: return Target(badge: 1)
        case .working: return Target(badge: 1)
        case .waiting: return Target(badge: 1)
        }
    }

    /// Куда тянутся живые числа в этом кадре.
    private func targets(now t: Double) -> [Prop: Double] {
        var target = Self.target(for: mood)
        let cx = Double(cursor.x), cy = Double(cursor.y)
        switch mood {
        case .asleep:
            target.gx = 0; target.gy = 0.2; target.tilt = 0.03
        case .awake:
            target.gx = cx * 0.7; target.gy = cy * 0.5
        case .thinking:
            // Смотрит вверх и вправо, взгляд чуть блуждает.
            target.gx = 0.5 + 0.12 * sin(t * 0.9); target.gy = -0.55; target.tilt = -0.10
        case .working:
            // Глаза ходят слева направо: просматривает файлы.
            target.gx = 0.6 * sin(t * 1.6); target.gy = -0.06; target.bob = 0.012 * sin(t * 5)
        case .waiting:
            // Смотрит на вас, большие глаза, мелкие прыжки.
            target.gx = cx * 0.25; target.gy = cy * 0.2; target.bob = -abs(sin(t * 5.2)) * 0.05
        case .done:
            target.gx = cx * 0.3; target.gy = cy * 0.25
        }
        if let g = greetPhase {
            // Качает головой с частотой 1,2 Гц и смотрит прямо; значок убран.
            target.tilt = -0.06 + 0.07 * sin(2 * .pi * 1.2 * g)
            target.gx = 0; target.gy = 0; target.badge = 0
            if mood == .asleep { target.open = 1 }
        }
        let breathe = target.breathe * sin(target.breatheRate * t)
        return [
            .open: target.open, .gx: target.gx, .gy: target.gy, .tilt: target.tilt, .badge: target.badge,
            .sy: 1 + breathe, .sx: 1 - breathe * 0.57, .oy: target.bob,
        ]
    }

    // MARK: - Кадр

    func update(now: Double) {
        let dt = last == 0 ? 1.0 / 30 : min(max(now - last, 0), 0.1)
        last = now
        advanceTweens(now: now)

        // Гладкое приближение, не зависящее от частоты кадров. Свойство,
        // которое сейчас ведёт твин, не трогаем.
        for (prop, goal) in targets(now: now) where tweens[prop] == nil {
            let k: Double = prop == .gx || prop == .gy ? 0.0025 : 0.0008
            value[prop, default: 0] += (goal - (value[prop] ?? 0)) * (1 - pow(k, dt))
        }

        // Моргание: раз в 2,2–5,4 с, в 22% случаев дважды подряд.
        let awake = mood != .asleep && mood != .done && greetPhase == nil
        if awake, tweens[.open] == nil {
            if let at = doubleBlinkAt, now >= at {
                doubleBlinkAt = nil
                blink(now: now)
            } else if now >= nextBlink {
                nextBlink = now + 2.2 + Double.random(in: 0...3.2)
                blink(now: now)
                if Double.random(in: 0..<1) < 0.22 { doubleBlinkAt = now + 0.23 }
            }
        }

        spawnParticles(now: now, dt: dt)
        particles = particles.compactMap { var p = $0
            p.age += dt; p.x += p.vx * dt; p.y += p.vy * dt
            return p.age < p.life ? p : nil }
    }

    private func blink(now: Double) {
        anim(.open, [Key(to: 0.06, ms: 70, ease: .inOut), Key(to: 1, ms: 130)], now: now)
    }

    private func spawnParticles(now: Double, dt: Double) {
        guard let pose = poses[mood] else { return }
        let head = CGPoint(x: pose.faceCenter.x + pose.faceWidth * 0.40, y: pose.faceCenter.y - pose.faceHeight * 0.50)
        if mood == .asleep, now >= nextZ {
            nextZ = now + 1.3
            particles.append(Particle(kind: .z, x: head.x, y: head.y, vx: 0.04, vy: -0.10,
                                      age: 0, life: 1.6, size: 0.13))
        }
        if let at = sparksAt, now >= at {
            sparksAt = nil
            for i in 0..<5 {
                let angle = -Double.pi / 2 + (Double(i) - 2) * 0.55
                particles.append(Particle(kind: .spark, x: pose.faceCenter.x, y: pose.faceCenter.y - pose.faceHeight * 0.3,
                                          vx: cos(angle) * 0.22, vy: sin(angle) * 0.22,
                                          age: -Double(i) * 0.05, life: 0.9, size: 0.07))
            }
        }
    }

    // MARK: - Выражение глаз

    enum EyeStyle { case pill, round, arc, sleepy }

    var eyeStyle: EyeStyle {
        if greetPhase != nil { return .arc }
        switch mood {
        case .asleep: return .sleepy
        case .done: return .arc
        case .waiting: return .round
        default: return .pill
        }
    }

    /// Кадров в секунду: во сне хватает десяти (дыхание и «z»), за работой
    /// тридцать. Читается при перестроении вида, то есть при смене настроения.
    var fps: Double { mood == .asleep && tweens.isEmpty ? 10 : 30 }
}
