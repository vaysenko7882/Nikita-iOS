import SwiftUI

/// Десять игр битвы за корону, в порядке, в котором они идут. У каждой — свой шрифт,
/// своя палитра и своя афиша перед первым раундом.
struct GameInfo: Identifiable {
    let id: String
    let title: String
    let color: Color
    /// Длина раунда, с
    let duration: Double
    let rules: [String]
    /// Шрифт игры: им набраны афиша, отсчёт и надписи
    let font: GFont
    let ink: Color
    let make: (GameContext) -> ArcadeGame

    func rule(_ r: Int) -> String { rules[min(rules.count - 1, max(0, r))] }

    /// Заголовок афиши в стиле игры
    func titleStyle(_ size: CGFloat, width: CGFloat) -> LabelStyle {
        switch id {
        case "box": return L(.inter, size * 1.25, Color(hex: 0xffd23f)).outline(Color(hex: 0x1a0a08), 10).deep(Color(hex: 0x7c0b10), 8).squeeze(0.82).fit(width)
        case "race": return L(.tektur, size * 1.05, .white).slant(-0.24).halo(Color(hex: 0xff2e88), 22).fit(width)
        case "mines": return L(.mono, size * 0.9, Color(hex: 0x39ff88)).halo(Color(hex: 0x39ff88), 18).spaced(4).fit(width)
        case "duel": return L(.serif, size, Color(hex: 0xffe9b0)).outline(Color(hex: 0x2a0e04), 10).deep(Color(hex: 0x8f2f12), 7).fit(width)
        case "slice": return L(.plex, size, Color(hex: 0x14100c)).fit(width)
        case "goal": return L(.inter, size * 1.15, Color(hex: 0xc6ff3d)).outline(Color(hex: 0x06210f), 10).deep(Color(hex: 0x0a3b18), 7).squeeze(0.72).fit(width)
        case "range": return L(.arsenal, size * 1.2, Color(hex: 0xffcf40)).outline(Color(hex: 0x3a1206), 9).spaced(6).fit(width)
        case "arm": return L(.poiret, size * 0.95, Color(hex: 0xffd1e8)).halo(Color(hex: 0xff4fa3), 26).fit(width)
        case "hoop": return L(.pixel, size, Color(hex: 0xff8a1f)).outline(Color(hex: 0x2a0e02), 9).deep(Color(hex: 0x5a1e02), 5).fit(width)
        default: return L(.jura, size * 1.1, .white).spaced(8).fit(width)
        }
    }
}

enum Arcade {
    static let games: [GameInfo] = [
        GameInfo(id: "box", title: "Бокс", color: Color(hex: 0xff3b2f), duration: 10,
                 rules: ["Бей касанием, когда он раскрылся. Свайпом в сторону уходи от замаха", "Он бьёт чаще и делает обманки", "Чемпион. Ни одной ошибки"],
                 font: .inter, ink: Color(hex: 0xf4ead8), make: { BoxGame($0) }),
        GameInfo(id: "race", title: "Гонка", color: Color(hex: 0xff3cac), duration: 10,
                 rules: ["Наклоняй телефон или веди пальцем. Не врезайся, лови стрелки-ускорители", "Машин больше", "Час пик на трассе. Жми"],
                 font: .tektur, ink: .white, make: { RaceGame($0) }),
        GameInfo(id: "mines", title: "Минёр", color: Color(hex: 0x39ff88), duration: 13,
                 rules: ["Радар покажет мины на миг. Запомни и веди пальцем к выходу. Цифры — сколько мин рядом", "Мин больше, радар быстрее", "Поле почти сплошь заминировано"],
                 font: .mono, ink: Color(hex: 0xeaffef), make: { MinesGame($0) }),
        GameInfo(id: "duel", title: "Дуэль", color: Color(hex: 0xff7b2e), duration: 6.2,
                 rules: ["Жди «DRAW!» и стреляй первым. Раньше — позор", "Ворона тоже умеет пугать", "Последняя пуля в барабане"],
                 font: .serif, ink: Color(hex: 0xf3dfb4), make: { ShowdownGame($0) }),
        GameInfo(id: "slice", title: "Самурай", color: Color(hex: 0xe2402f), duration: 9,
                 rules: ["Режь фрукты взмахом пальца. Бомбы не трогай", "Фруктов больше, бомбы чаще", "Путь меча. Комбо решают"],
                 font: .plex, ink: Color(hex: 0x14100c), make: { SamuraiGame($0) }),
        GameInfo(id: "goal", title: "Пенальти", color: Color(hex: 0xc6ff3d), duration: 11.5,
                 rules: ["Свайпни от мяча туда, куда бить. Сильнее — выше. Дуга закручивает", "Вратарь читает удары", "Вратарь — стена. Только в девятку"],
                 font: .inter, ink: .white, make: { GoalGame($0) }),
        GameInfo(id: "range", title: "Тир", color: Color(hex: 0xffcf40), duration: 9.5,
                 rules: ["Стреляй по уткам и мишеням. Зайца не трогать", "Утки шустрее", "Звезда стоит тридцать"],
                 font: .arsenal, ink: Color(hex: 0xfff6c8), make: { RangeGame($0) }),
        GameInfo(id: "arm", title: "Армрестлинг", color: Color(hex: 0xff4fa3), duration: 7.5,
                 rules: ["Жми как можно чаще — можно двумя пальцами — и дожми руку к столу", "Он не сдаётся", "Финальный зажим. Не отпускай"],
                 font: .poiret, ink: Color(hex: 0xffd1e8), make: { ArmGame($0) }),
        GameInfo(id: "hoop", title: "Баскет", color: Color(hex: 0xff8a1f), duration: 10,
                 rules: ["Свайпни мяч вверх в кольцо. Три подряд — огонь, очки ×2", "Кольцо поехало", "Кольцо носится как бешеное"],
                 font: .pixel, ink: .white, make: { HoopGame($0) }),
        GameInfo(id: "beat", title: "Ритм", color: Color(hex: 0x7d5cff), duration: 11,
                 rules: ["Тапай по дорожке, когда нота на линии. Попал — играет музыка", "Темп выше", "Аккорды. Двумя пальцами"],
                 font: .jura, ink: .white, make: { BeatGame($0) })
    ]
}

/// Фон афиши: у каждой игры свой мир. t — секунды с появления, для лёгкого движения
enum PosterArt {
    static func draw(_ id: String, _ g: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let full = Path(CGRect(origin: .zero, size: size))
        switch id {
        case "box":
            g.fill(full, with: radial(G([(0, Color(hex: 0x5a1612)), (0.55, Color(hex: 0x27100f)), (1, Color(hex: 0x0d0506))]), P(w / 2, h * 0.35), 0, h * 0.8))
            for (i, col) in [Color(hex: 0xe8352c), Color(hex: 0xf4ead8), Color(hex: 0x2a4fd6)].enumerated() {
                var rope = Path()
                let y = h * (0.66 + CGFloat(i) * 0.06)
                rope.move(to: P(-10, y))
                rope.addQuadCurve(to: P(w + 10, y), control: P(w / 2, y + 22))
                g.strokeColor(rope, col, 6)
            }
            let bulb = CGFloat((t * 1.7).truncatingRemainder(dividingBy: 1))
            g.fill(Shape2.circle(P(w * bulb, h * 0.16), 50), with: radial(G([(0, Color.white.opacity(0.35)), (1, Color.white.opacity(0))]), P(w * bulb, h * 0.16), 0, 50))
        case "race":
            let hz = h * 0.56
            g.fill(Path(CGRect(x: 0, y: 0, width: w, height: hz)), with: linear(G([(0, Color(hex: 0x12032b)), (0.6, Color(hex: 0x3b0a5e)), (1, Color(hex: 0xff2e88))]), P(0, 0), P(0, hz)))
            let r = w * 0.3
            g.fill(Shape2.circle(P(w / 2, hz - r * 0.3), r), with: linear(G([(0, Color(hex: 0xffe66b)), (0.55, Color(hex: 0xff6a3d)), (1, Color(hex: 0xff1f8e))]), P(0, hz - r * 1.3), P(0, hz + r * 0.7)))
            var bands = Path()
            for i in 0..<6 { bands.addRect(CGRect(x: w / 2 - r, y: hz - r * 0.3 + r * (0.1 + CGFloat(i) * 0.16), width: r * 2, height: 2 + CGFloat(i) * 1.6)) }
            g.fillColor(bands, Color(hex: 0x3b0a5e))
            g.fillColor(Path(CGRect(x: 0, y: hz, width: w, height: h - hz)), Color(hex: 0x0b0216))
            var grid = Path()
            for i in -8...8 { grid.addPath(Shape2.line(P(w / 2 + CGFloat(i) * w * 0.02, hz), P(w / 2 + CGFloat(i) * w * 0.3, h))) }
            let scroll = (t * 0.8).truncatingRemainder(dividingBy: 1)
            for j in 0..<10 {
                let k = pow((Double(j) + scroll) / 10, 2)
                let y = hz + (h - hz) * CGFloat(k)
                grid.addPath(Shape2.line(P(0, y), P(w, y)))
            }
            g.strokeColor(grid, Color(hex: 0x2de2e6, alpha: 0.5), 1.2)
        case "mines":
            g.fillColor(full, Color(hex: 0x010d06))
            let c = P(w / 2, h * 0.5)
            var rings = Path()
            for i in 1...5 { rings.addPath(Shape2.circle(c, CGFloat(i) * min(w, h) * 0.1)) }
            rings.addPath(Shape2.line(P(c.x - w, c.y), P(c.x + w, c.y)))
            rings.addPath(Shape2.line(P(c.x, c.y - h), P(c.x, c.y + h)))
            g.strokeColor(rings, Color(hex: 0x39ff88, alpha: 0.18), 1)
            let a = t * 2.4
            for i in 0..<22 {
                let b = a - Double(i) * 0.05
                g.strokeColor(Shape2.line(c, P(c.x + cosv(b) * h, c.y + sinv(b) * h)), Color(hex: 0x39ff88).opacity((1 - Double(i) / 22) * 0.3), 3)
            }
            var scan = Path()
            var y: CGFloat = 0
            while y < h { scan.addRect(CGRect(x: 0, y: y, width: w, height: 1)); y += 3 }
            g.fillColor(scan, Color.black.opacity(0.25))
        case "duel":
            let ground = h * 0.74
            g.fill(Path(CGRect(x: 0, y: 0, width: w, height: ground)), with: linear(G([(0, Color(hex: 0x2a1006)), (0.45, Color(hex: 0x8f2f12)), (0.8, Color(hex: 0xe0782a)), (1, Color(hex: 0xf6b04a))]), P(0, 0), P(0, ground)))
            g.fill(Shape2.circle(P(w / 2, ground - 30), 150), with: radial(G([(0, Color(hex: 0xfff1c2)), (0.45, Color(hex: 0xffcf6a)), (1, Color(hex: 0xffa03c, alpha: 0))]), P(w / 2, ground - 30), 10, 150))
            g.fillColor(Path(CGRect(x: 0, y: ground, width: w, height: h - ground)), Color(hex: 0x2a1207))
            Grain.draw(&g, CGRect(origin: .zero, size: size), alpha: 0.2, opacity: 0.5)
            g.fillColor(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.07)), .black)
            g.fillColor(Path(CGRect(x: 0, y: h * 0.93, width: w, height: h * 0.07)), .black)
        case "slice":
            g.fillColor(full, Color(hex: 0xefe6d2))
            Grain.draw(&g, CGRect(origin: .zero, size: size), alpha: 0.12, opacity: 0.9)
            g.fillColor(Shape2.circle(P(w * 0.66, h * 0.36), min(w, h) * 0.3), Color(hex: 0xe2402f, alpha: 0.85))
            Lettering.draw(&g, "斬", at: P(w * 0.22, h * 0.76), L(.kanji, min(w, h) * 0.5, Color(hex: 0x14100c, alpha: 0.08)))
            var stroke = Path()
            stroke.move(to: P(w * 0.08, h * 0.62))
            stroke.addQuadCurve(to: P(w * 0.94, h * 0.5), control: P(w * 0.5, h * 0.7))
            g.strokeColor(stroke, Color(hex: 0x14100c, alpha: 0.85), 9)
        case "goal":
            g.fill(full, with: linear(G([(0, Color(hex: 0x050a14)), (0.62, Color(hex: 0x0c1d2e)), (0.62, Color(hex: 0x1a6b2f)), (1, Color(hex: 0x1f7a36))]), P(0, 0), P(0, h)))
            for lx in [CGFloat(0.1), CGFloat(0.9)] {
                g.fill(full, with: radial(G([(0, Color(hex: 0xebf5ff, alpha: 0.7)), (0.15, Color(hex: 0xebf5ff, alpha: 0.15)), (1, Color(hex: 0xebf5ff, alpha: 0))]), P(w * lx, h * 0.04), 2, w * 0.6))
            }
            var frame = Path()
            frame.move(to: P(w * 0.1, h * 0.62)); frame.addLine(to: P(w * 0.1, h * 0.3))
            frame.addLine(to: P(w * 0.9, h * 0.3)); frame.addLine(to: P(w * 0.9, h * 0.62))
            g.strokeColor(frame, Color(hex: 0xf4f6fa), 7)
        case "range":
            for i in 0..<12 {
                g.fillColor(Path(CGRect(x: 0, y: CGFloat(i) * h / 12, width: w, height: h / 12 + 1)), i % 2 == 1 ? Color(hex: 0x3d2213) : Color(hex: 0x46281a))
            }
            let n = 7
            let sw = w / CGFloat(n)
            for i in 0..<n {
                var flap = Path()
                flap.move(to: P(CGFloat(i) * sw, 0))
                flap.addLine(to: P(CGFloat(i + 1) * sw, 0))
                flap.addLine(to: P(CGFloat(i + 1) * sw, h * 0.12))
                flap.addArc(center: P((CGFloat(i) + 0.5) * sw, h * 0.12), radius: sw / 2, startAngle: .radians(0), endAngle: .radians(Double.pi), clockwise: false)
                flap.closeSubpath()
                g.fillColor(flap, i % 2 == 1 ? Color(hex: 0xf7efe0) : Color(hex: 0xd6261c))
            }
            for i in 0..<10 {
                let lit = (Int(t * 5) + i) % 3 != 0
                g.fillColor(Shape2.circle(P(sw * 0.3 + CGFloat(i) * (w - sw * 0.6) / 9, h * 0.22), 6), lit ? Color(hex: 0xffe9a8) : Color(hex: 0x6b4a20))
            }
        case "arm":
            g.fillColor(full, Color(hex: 0x140a10))
            var bricks = Path()
            var y: CGFloat = 0
            var row = 0
            while y < h * 0.7 {
                var x: CGFloat = row % 2 == 1 ? -26 : 0
                while x < w { bricks.addRect(CGRect(x: x + 1, y: y + 1, width: 50, height: 20)); x += 52 }
                y += 22
                row += 1
            }
            g.fillColor(bricks, Color(hex: 0x3a1a20))
            g.fill(full, with: radial(G([(0, Color(hex: 0xff4fa3, alpha: 0.25)), (1, Color.black.opacity(0.6))]), P(w / 2, h * 0.42), 10, h * 0.7))
            g.fill(Path(CGRect(x: 0, y: h * 0.7, width: w, height: h * 0.3)), with: linear(G([(0, Color(hex: 0x5a2e1a)), (1, Color(hex: 0x1e0d06))]), P(0, h * 0.7), P(0, h)))
        case "hoop":
            g.fillColor(full, Color(hex: 0x0c0703))
            var cage = Path()
            for i in 0...12 {
                let k = CGFloat(i) / 12
                cage.addPath(Shape2.line(P(w * (0.14 + 0.72 * k), h * 0.12), P(w * k, h)))
            }
            g.strokeColor(cage, Color(hex: 0xff8a1f, alpha: 0.14), 1)
            var rails = Shape2.line(P(w * 0.14, h * 0.12), P(0, h))
            rails.addPath(Shape2.line(P(w * 0.86, h * 0.12), P(w, h)))
            g.strokeColor(rails, Color(hex: 0xff8a1f), 4)
            let bounce = abs(sin(t * 3.2))
            g.fill(Shape2.circle(P(w * 0.5, h * 0.8 - CGFloat(bounce) * h * 0.1), 30), with: radial(G([(0, Color(hex: 0xffb066)), (0.6, Color(hex: 0xee6a12)), (1, Color(hex: 0x8a3404))]), P(w * 0.49, h * 0.78 - CGFloat(bounce) * h * 0.1), 3, 30))
        default:
            g.fill(full, with: linear(G([(0, Color(hex: 0x07030f)), (1, Color(hex: 0x1d0f4a))]), P(0, 0), P(0, h)))
            var eq = Path()
            for i in 0..<18 {
                let lvl = sin(t * 6 + Double(i) * 1.7) * 0.5 + 0.5
                let hh = CGFloat(lvl) * h * 0.25
                eq.addRect(CGRect(x: CGFloat(i) * w / 18 + 2, y: h - hh, width: w / 18 - 4, height: hh))
            }
            g.fillColor(eq, Color(hex: 0x7d5cff, alpha: 0.35))
            for i in 0..<4 {
                let a = sin(t * 0.9 + Double(i) * 1.6) * 0.9
                g.strokeColor(Shape2.line(P(w / 2, 0), P(w / 2 + sinv(a) * h * 1.2, h)), (i % 2 == 1 ? Color(hex: 0xff4fd8) : Color(hex: 0x40c8ff)).opacity(0.35), 3)
            }
        }
    }
}

/// Афиша игры: перед первым раундом — во весь экран арены
struct PosterView: View {
    let game: GameInfo
    let label: String
    @State private var born = Date()

    var body: some View {
        ZStack {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(born)
                Canvas { g, size in
                    PosterArt.draw(game.id, &g, size, t)
                    let k = min(1, t / 0.45)
                    let pop = CGFloat(2.2 - 1.2 * Ease.back(k))
                    let titleSize = min(size.width, size.height) * 0.2
                    let st = game.titleStyle(titleSize, width: size.width * 0.86)
                    Lettering.draw(&g, game.title.uppercased(), at: P(size.width / 2, size.height * 0.44), st, scale: pop)
                }
            }
            VStack(spacing: 12) {
                Text(label)
                    .font(game.font.font(15))
                    .tracking(3)
                    .foregroundStyle(game.ink.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .padding(.top, 28)
                Spacer()
                Text(game.rule(0))
                    .font(game.font.font(19))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(game.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.42)))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
            }
        }
    }
}
