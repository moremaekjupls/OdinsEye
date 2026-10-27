import SwiftUI

/// Миндалевидный разрез глаза. `openness` от 0 (щель) до 1 (полностью открыт);
/// анимируется как число, поэтому веко движется плавно.
struct EyeOpening: Shape {
    var openness: Double

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let mid = rect.midY
        // Управляющая точка квадратичной кривой уходит вдвое дальше вершины.
        let lift = rect.height * CGFloat(max(0.04, min(1, openness)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: mid))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: mid), control: CGPoint(x: rect.midX, y: mid - lift))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: mid), control: CGPoint(x: rect.midX, y: mid + lift))
        path.closeSubpath()
        return path
    }
}

/// Глаз Одина: один глаз, который следит за Claude Code. Нарисован кодом,
/// без картинок; вместо него можно подложить свои (`AvatarSkins`).
struct OdinEyeView: View {
    var look: CGSize
    var openness: Double
    var pupil: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let iris = h * 0.68
            ZStack {
                EyeOpening(openness: openness)
                    .fill(Color.white.opacity(0.94))

                ZStack {
                    Circle().fill(tint)
                        .frame(width: iris, height: iris)
                    Circle().fill(Color.black)
                        .frame(width: iris * 0.46 * pupil, height: iris * 0.46 * pupil)
                    Circle().fill(Color.white.opacity(0.9))
                        .frame(width: iris * 0.16, height: iris * 0.16)
                        .offset(x: -iris * 0.16, y: -iris * 0.16)
                }
                .offset(x: look.width * w * 0.16, y: look.height * h * 0.12)
                .mask(EyeOpening(openness: openness))

                EyeOpening(openness: openness)
                    .stroke(tint.opacity(0.9), lineWidth: 1)
            }
            .frame(width: w, height: h)
        }
    }
}

/// То, что стоит в «ухе» рядом с чёлкой: глаз или своя картинка.
struct AvatarFace: View {
    @ObservedObject var model: AvatarModel

    var body: some View {
        Group {
            if let skin = model.skin {
                Image(nsImage: skin)
                    .resizable()
                    .scaledToFit()
            } else {
                OdinEyeView(look: model.look, openness: model.openness, pupil: model.pupil, tint: model.tint)
                    .frame(width: 24, height: 15)
            }
        }
        .scaleEffect(model.scale)
    }
}
