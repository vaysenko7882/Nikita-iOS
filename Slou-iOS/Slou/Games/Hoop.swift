import SwiftUI

/// БАСКЕТ. Уличный автомат с неоновыми бортиками и пиксельным табло.
/// Свайп вверх — бросок. Три подряд — мяч загорается, каждое попадание по 3 очка.
final class HoopGame: GameBase {
    private enum Res { case swish, inHoop, roll, bank, rim, board, miss
        var scored: Bool { self == .swish || self == .inHoop || self == .roll || self == .bank }
    }
    private struct Shot {
        var t: Double
        var ax: CGFloat
        var ay: CGFloat
        var fire: Bool
        var res: Res?
        var hx: CGFloat = 0
        var hy: CGFloat = 0
        var tr: Double = 0
        var gone = false
        var X: CGFloat = 0
        var Y: CGFloat = 0
        var r: CGFloat = 0
        var rot: Double = 0
    }

    private let orange = Color(hex: 0xff8a1f)
    private let bx: CGFloat, by: CGFloat, br: CGFloat, rw: CGFloat
    private let P0: CGFloat = 1300
    private var amp: CGFloat = 0
    private var ph: Double = 0
    private var shots: [Shot] = []
    private var points = 0
    private var streak = 0
    private var ready: Double = 0
    private var netK: CGFloat = 0
    private var trail: [CGPoint] = []

    override init(_ c: GameContext) {
        bx = c.w / 2
        by = c.h * 0.86
        br = 31 * c.s
        rw = 50 * c.s
        super.init(c)
        amp = CGFloat([0, 0.17, 0.27][R]) * w
        ph = c.rnd.next() * TAU
    }

    override func score() -> Int { Int((Double(points) * 100 / 32).rounded()) }

    override func begin() { sfx("count", 0.6) }

    private func hoop(_ at: Double) -> CGPoint {
        let k = (at - t0) / 1000
        let speed = [0, 1.3, 2.1][R]
        let x = w / 2 + sinv(k * speed + ph) * amp
        let y = h * 0.31 + (R == 2 ? sinv((at - t0) / 700) * 12 * S : 0)
        return P(x, y)
    }

    override func onDown(_ p: CGPoint) { trail = [p] }

    override func onMove(_ p: CGPoint, _ prev: CGPoint) {
        trail.append(p)
        if trail.count > 20 { trail.removeFirst() }
    }

    override func onSwipe(_ g: Gestures.Swipe) {
        guard live, g.dy <= -40, now >= ready else { return }
        let hp = hoop(now + 600)
        let total = max(1, hypot(g.vx, g.vy))
        let power = total * (abs(g.vy) / total)
        var ax = bx + (g.dx / -g.dy) * (by - hp.y) * 0.95
        var ay = hp.y + CGFloat(log(Double(P0 / max(300, power)))) * 95 * S
        // доводчик: почти точный бросок чуть подтягивается к кольцу
        if abs(ax - hp.x) < rw * 1.3 { ax += (hp.x - ax) * 0.4 }
        if abs(ay - hp.y) < 60 * S { ay += (hp.y - ay) * 0.3 }
        shots.append(Shot(t: now, ax: ax, ay: ay, fire: streak >= 3, res: nil))
        ready = now + 280
        sfx("whoosh", 0.7)
        buzz("light")
    }

    private func resolve(_ i: Int) {
        let hp = hoop(now)
        let dx = shots[i].ax - hp.x
        let dy = shots[i].ay - hp.y
        var res: Res
        if abs(dx) < rw * 0.7 && abs(dy) < 30 * S {
            res = abs(dx) < rw * 0.22 && abs(dy) < 12 * S ? .swish : .inHoop
        } else if abs(dx) < rw * 1.15 && abs(dy) < 46 * S {
            res = Double.random(in: 0...1) < 0.35 ? .roll : .rim
        } else if dy < -24 * S && dy > -120 * S && abs(dx) < rw * 1.6 {
            res = abs(dx) < rw * 0.7 ? .bank : .board
        } else {
            res = .miss
        }
        shots[i].res = res
        shots[i].hx = hp.x
        shots[i].hy = hp.y
        shots[i].tr = now
        if res.scored {
            let v = shots[i].fire ? 3 : 2
            points += v
            streak += 1
            netK = 1
            sfx(res == .swish ? "swish" : "bounce")
            if res == .roll || res == .bank { sfx("rim", 0.5) }
            buzz(res == .swish ? "success" : "medium")
            let word = res == .swish ? "SWISH" : res == .bank ? "BANK" : "+\(v)"
            let font: GFont = res == .swish || res == .bank ? .silk : .pixel
            pops.add(word, hp.x, hp.y - 50 * S, L(font, 34 * S, shots[i].fire ? Color(hex: 0xffcf40) : .white).outline(Color(hex: 0x2a0e02), 6))
            if streak == 3 {
                pops.add("OГOНЬ!", w / 2, h * 0.55, L(.pixel, 48 * S, orange).outline(Color(hex: 0x2a0e02), 7), life: 1.2)
                sfx("fire")
                buzz("heavy")
            }
            let colors = shots[i].fire ? [Color(hex: 0xffcf40), Color(hex: 0xff5a1f)] : [Color.white, orange]
            parts.burst(hp.x, hp.y, n: 18, colors: colors, speed: 260 * S, gravity: 500, life: 0.6)
        } else {
            streak = 0
            if res == .rim || res == .board {
                sfx("rim")
                buzz("rigid")
                shake.kick(3 * S, 0.15)
            }
        }
        report()
    }

    override func update() {
        netK = max(0, netK - CGFloat(dt * 2.5))
        for i in shots.indices {
            let k = (now - shots[i].t) / 1000 / 0.62
            if shots[i].res == nil {
                if k >= 1 { resolve(i) }
                let e = CGFloat(min(1, k))
                shots[i].X = bx + (shots[i].ax - bx) * e
                shots[i].Y = by + (shots[i].ay - by) * e - 230 * S * 4 * e * (1 - e)
                shots[i].r = br * (1 - 0.48 * e)
            }
            shots[i].rot = (now - shots[i].t) / 80
            if let res = shots[i].res {
                let q = CGFloat((now - shots[i].tr) / 1000)
                let s = shots[i]
                shots[i].r = br * 0.52
                switch res {
                case .swish, .inHoop:
                    shots[i].X = s.hx + (s.ax - s.hx) * 0.4
                    shots[i].Y = s.hy + q * q * 900 * S
                case .roll:
                    let a = Double(q) * 9
                    shots[i].X = s.hx + cosv(a) * rw * 0.7 * max(0, 1 - q * 2)
                    shots[i].Y = s.hy - 8 * S + (q > 0.5 ? (q - 0.5) * (q - 0.5) * 1800 * S : 0)
                case .bank:
                    shots[i].X = s.ax + (s.hx - s.ax) * min(1, q * 4)
                    shots[i].Y = s.ay + q * q * 1200 * S
                case .rim, .board:
                    let away: CGFloat = s.ax >= s.hx ? 1 : -1
                    shots[i].X = s.ax + away * q * 260 * S
                    shots[i].Y = s.ay - q * 120 * S + q * q * 1300 * S
                case .miss:
                    shots[i].X = s.ax
                    shots[i].Y = s.ay + q * q * 1400 * S
                }
                if q > 1.4 { shots[i].gone = true }
            }
        }
        shots.removeAll { $0.gone }
        if live && streak >= 3 && Double.random(in: 0...1) < 0.6 {
            parts.burst(bx, by - br * 0.6, n: 1, colors: [Color(hex: 0xffcf40), Color(hex: 0xff5a1f)], speed: 60, angle: -Double.pi / 2, spread: 0.8, gravity: -200, size: 6, life: 0.5)
        }
    }

    private func ball(_ g: inout GraphicsContext, _ X: CGFloat, _ Y: CGFloat, _ r: CGFloat, _ rot: Double, _ fire: Bool) {
        if fire {
            let flame = G([(0, Color(hex: 0xffaa28, alpha: 0.6)), (1, Color(hex: 0xff3c00, alpha: 0))])
            g.fill(Shape2.circle(P(X, Y), r * 2), with: radial(flame, P(X, Y), r * 0.5, r * 2))
        }
        var c = g
        c.translateBy(x: X, y: Y)
        c.rotate(by: .radians(rot))
        let leather = G([(0, Color(hex: 0xffb066)), (0.6, Color(hex: 0xee6a12)), (1, Color(hex: 0x8a3404))])
        c.fill(Shape2.circle(.zero, r), with: radial(leather, P(-r * 0.35, -r * 0.35), r * 0.1, r))
        var seams = Shape2.line(P(-r, 0), P(r, 0))
        seams.addPath(Shape2.line(P(0, -r), P(0, r)))
        seams.addPath(Shape2.arc(P(-r * 1.25, 0), r * 0.9, -0.9, 0.9))
        seams.addPath(Shape2.arc(P(r * 1.25, 0), r * 0.9, Double.pi - 0.9, Double.pi + 0.9))
        var inside = c
        inside.clip(to: Shape2.circle(.zero, r))
        inside.strokeColor(seams, Color(hex: 0x2a1004), max(1, r * 0.07))
    }

    override func draw(_ g: inout GraphicsContext) {
        let hp = hoop(live ? now : (t0 > 0 ? t0 : now))
        var x = world(g)
        // короб автомата: тёмная клетка в перспективе, неоновые бортики
        x.fillColor(Shape2.rect(-20, -20, w + 40, h + 40), Color(hex: 0x0c0703))
        let back = Shape2.poly([P(w * 0.14, h * 0.12), P(w * 0.86, h * 0.12), P(w, h), P(0, h)])
        x.fill(back, with: linear(G([(0, Color(hex: 0x1d0f06)), (1, Color(hex: 0x060302))]), P(0, 0), P(0, h)))
        var cage = Path()
        for i in 0...12 {
            let t = CGFloat(i) / 12
            cage.addPath(Shape2.line(P(w * (0.14 + 0.72 * t), h * 0.12), P(w * t, h)))
        }
        for j in 0..<10 {
            let t = CGFloat(j) / 10
            let y = h * 0.12 + h * 0.88 * t * t
            cage.addPath(Shape2.line(P(w * 0.14 * (1 - t * t), y), P(w - w * 0.14 * (1 - t * t), y)))
        }
        x.strokeColor(cage, orange.opacity(0.12), 1)
        var rails = Shape2.line(P(w * 0.14, h * 0.12), P(0, h))
        rails.addPath(Shape2.line(P(w * 0.86, h * 0.12), P(w, h)))
        var neon = x
        neon.addFilter(.shadow(color: orange, radius: 18))
        neon.strokeColor(rails, orange, 4 * S)
        // табло
        let board = Shape2.rrect(w * 0.2, 6 * S, w * 0.6, 54 * S, 8 * S)
        x.fillColor(board, Color(hex: 0x050302))
        x.strokeColor(board, Color(hex: 0x3a1a06), 2)
        let left = live ? max(0, 10 - (now - t0) / 1000) : 10
        Lettering.draw(&x, String(format: "%02d", points), at: P(w * 0.36, 34 * S), L(.silk, 30 * S, orange).halo(orange, 14))
        Lettering.draw(&x, String(format: "%.1f", left), at: P(w * 0.64, 34 * S), L(.silk, 24 * S, Color(hex: 0xff3d2e)).halo(Color(hex: 0xff3d2e), 14))
        var lcd = Path()
        var lx: CGFloat = 0
        while lx < w * 0.6 { lcd.addRect(CGRect(x: w * 0.2 + lx, y: 6 * S, width: 1, height: 54 * S)); lx += 4 }
        x.fillColor(lcd, Color.white.opacity(0.05))
        // щит и кольцо
        let bw = 150 * S, bh = 100 * S
        let shield = Shape2.rrect(hp.x - bw / 2, hp.y - bh * 0.92, bw, bh, 6 * S)
        x.fillColor(shield, Color.white.opacity(0.12))
        x.strokeColor(shield, Color.white.opacity(0.75), 3 * S)
        x.strokeColor(Shape2.rect(hp.x - 30 * S, hp.y - 50 * S, 60 * S, 44 * S), orange, 3 * S, cap: .butt)
        // сетка
        var net = Path()
        for i in 0...8 {
            let t = CGFloat(i) / 8
            let x0 = hp.x - rw + t * rw * 2
            let x1 = hp.x - rw * 0.55 + t * rw * 1.1
            net.move(to: P(x0, hp.y))
            net.addQuadCurve(to: P(x1, hp.y + 56 * S + netK * 22 * S), control: P((x0 + x1) / 2, hp.y + 30 * S + netK * 16 * S))
        }
        for j in 1...3 {
            let t = CGFloat(j) / 4
            net.addPath(Shape2.ellipse(P(hp.x, hp.y + t * (56 + netK * 22) * S), rw * (1 - t * 0.45), 6 * S))
        }
        x.strokeColor(net, Color.white.opacity(0.75), 1.5)
        // мячи, что уже прошли кольцо, — за ободом; летящие — перед ним
        for s in shots where !s.gone && (s.res?.scored ?? false) { ball(&x, s.X, s.Y, s.r, s.rot, s.fire) }
        var rim = x
        rim.addFilter(.shadow(color: Color(hex: 0xff6a1a), radius: 10))
        rim.strokeColor(Shape2.ellipse(hp, rw, 11 * S), Color(hex: 0xff6a1a), 6 * S)
        for s in shots where !s.gone && !(s.res?.scored ?? false) { ball(&x, s.X, s.Y, s.r, s.rot, s.fire) }
        if live && now >= ready { ball(&x, bx, by + sinv(now / 300) * 3 * S, br, 0, streak >= 3) }
        if trail.count > 1 && live {
            var tr = Path()
            tr.addLines(trail)
            x.strokeColor(tr, orange.opacity(0.35), 5 * S)
        }
        overlays(&g)
        if streak >= 3 {
            Lettering.draw(&g, "×2", at: P(30 * S, h * 0.9), L(.pixel, 34 * S, Color(hex: 0xffcf40)).lead().halo(orange).fade(0.7 + 0.3 * sin(now / 90)))
        }
    }
}
