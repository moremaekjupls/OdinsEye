import AppKit
import SwiftUI

/// Peeky на слоях Core Animation.
///
/// Первая версия рисовала кадры в SwiftUI `Canvas`, и на тридцати кадрах это
/// стоило около 10% процессора: профиль показал, что мой код занимает доли
/// процента, а всё остальное это сборка сцены SwiftUI и проход через Metal на
/// каждом кадре. Здесь сцена собрана один раз из слоёв, а кадр это смена
/// нескольких свойств (положение, поворот, масштаб, путь глаза). Композицию
/// делает системный сервер, приложение почти ничего не рисует.
@MainActor
final class PeekyLayerView: NSView {
    let engine: PeekyEngine
    var bodySide: CGFloat? { didSet { needsLayout = true } }
    var bottomInset: CGFloat? { didSet { needsLayout = true } }
    /// Где Peeky на экране (центр): от этого зависит, куда он смотрит за курсором.
    var screenAnchor: CGPoint = .zero
    var isRunning = false { didSet { if isRunning != oldValue { refreshLink() } } }

    // Сцена. `rig` стоит на «полу» и сплющивается и наклоняется вокруг ног;
    // внутри него `spin` кувыркается вокруг центра.
    private let rig = CALayer()
    private let spin = CALayer()
    private let body = CALayer()
    private let eyeBox = CALayer()
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private let dots = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let alert = CAShapeLayer()
    private let alertMark = CATextLayer()
    private var pool: [CALayer] = []
    private static let poolSize = 8

    private var link: CADisplayLink?
    private var shownMood: PeekyMood?
    private var linkRate: Double = 0
    private var bodyRect = CGRect.zero

    init(engine: PeekyEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        buildScene()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Сверху вниз, как в SwiftUI: так формулы поз остаются теми же.
    override var isFlipped: Bool { true }
    /// Клики проходят сквозь: Peeky только показывает.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Сцена

    private func buildScene() {
        guard let root = layer else { return }
        rig.addSublayer(spin)
        spin.addSublayer(body)
        spin.addSublayer(eyeBox)
        for eye in eyes { eyeBox.addSublayer(eye) }
        root.addSublayer(rig)
        for dot in dots { root.addSublayer(dot) }
        root.addSublayer(alert)
        alert.addSublayer(alertMark)
        body.magnificationFilter = .trilinear
        body.minificationFilter = .trilinear
        alertMark.string = "!"
        alertMark.alignmentMode = .center
        alertMark.foregroundColor = NSColor.white.cgColor
        for _ in 0..<Self.poolSize {
            let p = CALayer(); p.isHidden = true
            root.addSublayer(p); pool.append(p)
        }
        for dot in dots { dot.isHidden = true }
        alert.isHidden = true
    }

    override func layout() {
        super.layout()
        let side = bodySide ?? min(bounds.width, bounds.height) * 0.94
        let floor = bottomInset ?? bounds.height * 0.03
        bodyRect = CGRect(x: (bounds.width - side) / 2, y: bounds.height - side - floor, width: side, height: side)
        withoutAnimation {
            rig.bounds = CGRect(origin: .zero, size: bodyRect.size)
            spin.frame = rig.bounds
            body.frame = rig.bounds
            // Ось внизу тела: сплющиваясь, Peeky остаётся стоять на месте.
            rig.anchorPoint = CGPoint(x: 0.5, y: 0.96)
            spin.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            spin.position = CGPoint(x: side / 2, y: side / 2)
        }
        shownMood = nil
        apply()
    }

    // MARK: - Кадр

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        if window != nil { refreshLink() }
    }

    private func refreshLink() {
        guard window != nil else { return }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = !isRunning
        setRate(engine.fps)
    }

    private func setRate(_ fps: Double) {
        guard fps != linkRate else { return }
        linkRate = fps
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: Float(fps), preferred: Float(fps))
    }

    @objc private func tick(_ sender: CADisplayLink) {
        engine.cursor = Self.gaze(from: screenAnchor)
        engine.update(now: CACurrentMediaTime())
        apply()
        setRate(engine.fps)
    }

    /// Курсор относительно якоря, от -1 до 1; дальше 260 пт не уходит.
    static func gaze(from anchor: CGPoint) -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: max(-1, min(1, (m.x - anchor.x) / 260)), y: max(-1, min(1, -(m.y - anchor.y) / 260)))
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Перенести состояние движка на слои.
    func apply() {
        guard let pose = engine.poses[engine.displayMood], bodyRect.width > 0 else { return }
        let v = engine.value
        let side = bodyRect.width
        withoutAnimation {
            if shownMood != engine.displayMood {
                shownMood = engine.displayMood
                body.contents = pose.image
            }
            // rig: положение «пола» плюс смещение, наклон и сплющивание вокруг ног.
            rig.position = CGPoint(x: bodyRect.midX + (v[.ox] ?? 0) * side,
                                   y: bodyRect.minY + side * 0.96 + (v[.oy] ?? 0) * side)
            let squash = CGAffineTransform(scaleX: v[.sx] ?? 1, y: v[.sy] ?? 1)
            rig.setAffineTransform(squash.concatenating(CGAffineTransform(rotationAngle: v[.tilt] ?? 0)))
            spin.setAffineTransform(CGAffineTransform(rotationAngle: v[.spin] ?? 0))

            placeEyes(pose: pose, side: side)
            placeBadge(pose: pose, side: side, scale: v[.badge] ?? 0)
            placeParticles(side: side)
        }
    }

    // MARK: - Глаза

    private func placeEyes(pose: PeekyPose, side: CGFloat) {
        let open = max(0.06, min(1, engine.value[.open] ?? 1))
        let gx = engine.value[.gx] ?? 0, gy = engine.value[.gy] ?? 0
        let ew = pose.faceWidth * side * 0.20
        let eh = pose.faceWidth * side * 0.27
        eyeBox.position = CGPoint(x: pose.eyeMid.x * side, y: pose.eyeMid.y * side)
        eyeBox.bounds = .zero
        eyeBox.setAffineTransform(CGAffineTransform(rotationAngle: pose.eyeAngle))
        let shift = CGPoint(x: gx * pose.faceWidth * side * 0.10, y: gy * pose.faceHeight * side * 0.09)
        for (i, eye) in eyes.enumerated() {
            let sign: CGFloat = i == 0 ? -1 : 1
            eye.position = CGPoint(x: sign * pose.eyeSeparation * side / 2 + shift.x, y: shift.y)
            shape(eye, width: ew, height: eh, open: open)
        }
    }

    private func shape(_ eye: CAShapeLayer, width w: CGFloat, height h: CGFloat, open: Double) {
        let white = NSColor.white.withAlphaComponent(0.96).cgColor
        let path = CGMutablePath()
        switch engine.eyeStyle {
        case .pill:
            let eh = h * CGFloat(open)
            path.addRoundedRect(in: CGRect(x: -w / 2, y: -eh / 2, width: w, height: eh),
                                cornerWidth: min(w, eh) / 2, cornerHeight: min(w, eh) / 2)
            eye.fillColor = white; eye.strokeColor = nil
        case .round:
            let ew = w * 1.25, eh = h * 1.2 * CGFloat(open)
            path.addEllipse(in: CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh))
            eye.fillColor = white; eye.strokeColor = nil
        case .arc:
            // Дуга вверх: радость.
            path.move(to: CGPoint(x: -w * 0.55, y: h * 0.18))
            path.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.18), control: CGPoint(x: 0, y: -h * 0.62))
            style(eye, stroke: white, width: w * 0.26)
        case .sleepy:
            // Дуга вниз: закрытые глаза.
            path.move(to: CGPoint(x: -w * 0.55, y: -h * 0.05))
            path.addQuadCurve(to: CGPoint(x: w * 0.55, y: -h * 0.05), control: CGPoint(x: 0, y: h * 0.42))
            style(eye, stroke: white, width: w * 0.22)
        }
        eye.path = path
    }

    private func style(_ eye: CAShapeLayer, stroke: CGColor, width: CGFloat) {
        eye.fillColor = nil; eye.strokeColor = stroke
        eye.lineWidth = width; eye.lineCap = .round
    }

    // MARK: - Значок и частицы

    private func placeBadge(pose: PeekyPose, side: CGFloat, scale: Double) {
        // На маленьком теле значок не разобрать: за состояние отвечают глаза и точки справа.
        let visible = side >= 60 && scale > 0.01 && engine.greetPhase == nil
        let mood = engine.mood
        let center = CGPoint(x: bodyRect.minX + (pose.faceCenter.x + pose.faceWidth * 0.46) * side,
                             y: bodyRect.minY + (pose.faceCenter.y - pose.faceHeight * 0.58) * side)
        let tint = Self.cgTint(for: mood)
        let s = CGFloat(scale)
        let showDots = visible && (mood == .thinking || mood == .working)
        let showAlert = visible && mood == .waiting
        for (i, dot) in dots.enumerated() {
            dot.isHidden = !showDots
            guard showDots else { continue }
            let phase = 0.5 + 0.5 * sin(engine.last * 6 - Double(i) * 0.9)
            let r = side * 0.026 * s * CGFloat(0.7 + 0.5 * phase)
            dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            dot.fillColor = tint
            dot.position = CGPoint(x: center.x + CGFloat(i - 1) * side * 0.07, y: center.y)
        }
        alert.isHidden = !showAlert
        if showAlert {
            let r = side * 0.075 * s
            alert.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            alert.fillColor = tint
            alert.position = center
            alertMark.fontSize = r * 1.5
            alertMark.frame = CGRect(x: -r, y: -r * 0.78, width: r * 2, height: r * 2)
            alertMark.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    private func placeParticles(side: CGFloat) {
        let live = engine.particles.filter { $0.age >= 0 }
        for (i, slot) in pool.enumerated() {
            guard i < live.count, !(live[i].kind == .z && side < 40) else { slot.isHidden = true; continue }
            let p = live[i]
            let k = p.age / p.life
            // Появляется за первую пятую жизни, потом гаснет.
            let alpha = k < 0.2 ? k / 0.2 : max(0, 1 - (k - 0.2) / 0.8)
            let size = side * p.size * (1 + 0.4 * k)
            slot.isHidden = false
            slot.opacity = Float(alpha)
            slot.position = CGPoint(x: bodyRect.minX + p.x * side, y: bodyRect.minY + p.y * side)
            configure(slot, kind: p.kind, size: size)
        }
    }

    /// Слой пула становится «z» или искрой.
    private func configure(_ slot: CALayer, kind: PeekyEngine.Particle.Kind, size: CGFloat) {
        slot.sublayers?.forEach { $0.removeFromSuperlayer() }
        slot.contents = nil
        switch kind {
        case .z:
            let t = CATextLayer()
            t.string = "z"; t.fontSize = size; t.alignmentMode = .center
            t.font = NSFont.systemFont(ofSize: size, weight: .heavy)
            t.foregroundColor = NSColor(white: 0.8, alpha: 1).cgColor
            t.contentsScale = window?.backingScaleFactor ?? 2
            t.frame = CGRect(x: -size, y: -size * 0.6, width: size * 2, height: size * 1.4)
            slot.addSublayer(t)
        case .spark:
            let star = CAShapeLayer()
            let path = CGMutablePath()
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let r = i % 2 == 0 ? size : size * 0.35
                let q = CGPoint(x: CGFloat(cos(a)) * r, y: CGFloat(sin(a)) * r)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
            star.path = path
            star.fillColor = NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).cgColor
            slot.addSublayer(star)
        }
    }

    static func cgTint(for mood: PeekyMood) -> CGColor {
        switch mood {
        case .waiting: return NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1).cgColor
        case .done: return NSColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1).cgColor
        case .asleep: return NSColor(white: 0.58, alpha: 1).cgColor
        default: return NSColor(red: 0.23, green: 0.62, blue: 1.0, alpha: 1).cgColor
        }
    }
}

/// Peeky в SwiftUI: тонкая обёртка, сама анимация идёт в слоях.
struct PeekyView: NSViewRepresentable {
    let engine: PeekyEngine
    let screenAnchor: CGPoint
    var isRunning: Bool
    var bodySide: CGFloat?
    var bottomInset: CGFloat?

    func makeNSView(context: Context) -> PeekyLayerView { PeekyLayerView(engine: engine) }

    func updateNSView(_ view: PeekyLayerView, context: Context) {
        view.screenAnchor = screenAnchor
        view.bodySide = bodySide
        view.bottomInset = bottomInset
        view.isRunning = isRunning
    }
}
