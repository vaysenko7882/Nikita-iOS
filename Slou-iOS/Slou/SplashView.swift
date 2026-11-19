import SwiftUI

/// Заставка: буквы «слоу» падают каплями, приземляются, сплющиваются и слипаются друг с другом,
/// по слову проходит волна — и заставка растворяется прямо в такой же живой логотип на главной сайта.
struct SplashView: View {
    let start: Date
    let leaving: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            ZStack {
                Theme.paper
                Canvas { context, size in
                    let frame = LetterShapes.frame
                    let fit = min(size.width * 0.78 / frame.width, size.height * 0.24 / frame.height)
                    let originX = (size.width - frame.width * fit) / 2 - frame.minX * fit
                    let originY = size.height * 0.43 - frame.height * fit / 2 - frame.minY * fit
                    // «липкость»: размываем буквы и обрезаем по порогу — соседние капли сливаются
                    context.addFilter(.alphaThreshold(min: 0.5, color: Theme.ink))
                    context.addFilter(.blur(radius: max(3, 7 * fit)))
                    context.drawLayer { layer in
                        for i in 0..<LetterShapes.count {
                            let pose = SplashMotion.pose(i, t: t)
                            let a = LetterShapes.anchors[i]
                            var tr = CGAffineTransform(translationX: originX, y: originY).scaledBy(x: fit, y: fit)
                            tr = tr.translatedBy(x: a.x + CGFloat(pose.dx), y: a.y + CGFloat(pose.dy))
                            tr = tr.rotated(by: CGFloat(pose.rot))
                            tr = tr.scaledBy(x: CGFloat(pose.sx), y: CGFloat(pose.sy))
                            tr = tr.translatedBy(x: -a.x, y: -a.y)
                            layer.fill(LetterShapes.path(i).applying(tr), with: .color(.white), style: FillStyle(eoFill: true))
                        }
                    }
                }
                VStack(spacing: 10) {
                    Spacer()
                    Text("кино вдвоём, секунда в секунду")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.dim)
                        .opacity(clamp((t - 1.05) / 0.5))
                    Text("подключаемся к серверу…")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.dim.opacity(0.7))
                        .opacity(clamp((t - 4.0) / 0.6))
                    Spacer().frame(height: 72)
                }
            }
        }
        .scaleEffect(leaving ? 1.05 : 1)
        .animation(.easeIn(duration: 0.55), value: leaving)
        .onAppear(perform: scheduleTaps)
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Каждая буква приземляется с лёгким толчком в руку
    private func scheduleTaps() {
        for i in 0..<LetterShapes.count {
            let at = SplashMotion.landing(i)
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                Haptics.shared.play(i == LetterShapes.count - 1 ? "medium" : "soft")
            }
        }
    }
}

/// Движение букв считается прямо от времени — без состояния, поэтому кадры всегда ровные
enum SplashMotion {
    struct Pose {
        var dx = 0.0
        var dy = 0.0
        var sx = 1.0
        var sy = 1.0
        var rot = 0.0
    }

    static let delay = 0.2
    static let gap = 0.11
    static let fall = 0.46
    static let drop = 560.0

    static func landing(_ i: Int) -> Double { delay + Double(i) * gap + fall }

    static func pose(_ i: Int, t: Double) -> Pose {
        var p = Pose()
        let begin = delay + Double(i) * gap
        let local = t - begin
        if local < 0 {
            p.dy = -drop - 400
            return p
        }
        if local < fall {
            let k = local / fall
            p.dy = -drop * (1 - k * k)
            p.sx = 0.86
            p.sy = 1.18
            p.rot = (i % 2 == 0 ? -1.0 : 1.0) * 0.08 * (1 - k)
            return p
        }
        let s = local - fall
        // приземление: сплющилась, отпружинила, подпрыгнула и успокоилась
        let squash = 0.34 * exp(-s * 7.0) * cos(s * 24.0)
        p.sx = 1 + squash * 0.9
        p.sy = 1 - squash
        p.dy = -30 * exp(-s * 6.0) * abs(sin(s * 12.0))
        // волна по слову после того, как приземлилась последняя буква
        let wave = t - (landing(LetterShapes.count - 1) + 0.4) - Double(i) * 0.085
        if wave > 0 && wave < 0.6 {
            let w = sin(wave / 0.6 * Double.pi)
            p.dy -= 24 * w
            p.sy += 0.07 * w
            p.sx -= 0.045 * w
        }
        return p
    }
}
