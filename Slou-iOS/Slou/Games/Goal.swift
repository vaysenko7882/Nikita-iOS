import SwiftUI

/// ПЕНАЛЬТИ. Ночной стадион, четыре удара. Свайп от мяча задаёт направление,
/// скорость — высоту, а дуга пальца — закрутку. Вратарь угадывает всё чаще.
final class GoalGame: GameBase {
    private enum Result { case goal, save, post, miss }
    private enum Stage { case aim, fly, result, over }

    private struct Dive { var x: CGFloat; var y: CGFloat; var from: CGFloat; var t: Double }
    private struct Ball { var sx: CGFloat; var sy: CGFloat; var tx: CGFloat; var ty: CGFloat; var curve: CGFloat; var t0: Double; var dur: Double }
    private struct Roll { var read: Double; var side: Double; var sway: Double }
    private struct Fan { var x: CGFloat; var y: CGFloat; var c: Int; var ph: Double }

    private let lime = Color(hex: 0xc6ff3d)
    private let fanColors = [Color(hex: 0xe8f0ff), Color(hex: 0xff5a5a), Color(hex: 0xffe14d), Color(hex: 0x4da3ff), Color(hex: 0xc6ff3d)]
    private let SHOTS = 4
    private let gx0: CGFloat, gx1: CGFloat, gy0: CGFloat, gy1: CGFloat, GW: CGFloat, GH: CGFloat
    private let bx: CGFloat, by: CGFloat, br: CGFloat
    private let pRead: Double
    private let reach: CGFloat

    private var crowd: [Fan] = []
    private var rolls: [Roll] = []
    private var shot = 0
    private var stage = Stage.aim
    private var stageT: Double = 0
    private var goals = 0
    private var bonus = 0
    private var results: [Result] = []
    private var trail: [CGPoint] = []
    private var ball: Ball?
    private var keeperX: CGFloat = 0
    private var dive: Dive?
    private var netAt: (p: CGPoint, t: Double)?
    private var flash: Double = 0

    override init(_ c: GameContext) {
        let w = c.w, h = c.h, S = c.s
        gx0 = w * 0.06; gx1 = w * 0.94; gy0 = h * 0.2; gy1 = h * 0.5
        GW = gx1 - gx0; GH = gy1 - gy0
        bx = w / 2; by = h * 0.86; br = 22 * S
        let r = min(2, max(0, c.round))
        pRead = [0.34, 0.5, 0.64][r]
        reach = [0.17, 0.21, 0.25][r] * (w * 0.88)
        super.init(c)
        keeperX = w / 2
        for _ in 0..<240 {
            let x = CGFloat(c.rnd.next()) * w
            let y = CGFloat(c.rnd.next())
            let col = c.rnd.int(fanColors.count)
            let ph = c.rnd.next() * 6
            crowd.append(Fan(x: x, y: y, c: col, ph: ph))
        }
        for _ in 0..<SHOTS {
            let a = c.rnd.next(), b = c.rnd.next(), s = c.rnd.next() * 6
            rolls.append(Roll(read: a, side: b, sway: s))
        }
    }

    override func score() -> Int { goals * 22 + bonus }

    override func begin() {
        stage = .aim
        stageT = now
        sfx("whistle")
    }

    private func kick(_ tx: CGFloat, _ ty: CGFloat, _ curve: CGFloat, _ power: CGFloat) {
        stage = .fly
        stageT = now
        let roll = rolls[shot % SHOTS]
        var guess = P(tx, ty)
        if roll.read >= pRead { guess = P(gx0 + GW * (roll.side < 0.5 ? 0.22 : 0.78), gy0 + GH * 0.55) }
        let maxMove = GW * 0.38
        dive = Dive(x: clamp(guess.x, w / 2 - maxMove, w / 2 + maxMove), y: clamp(guess.y, gy0 + GH * 0.15, gy1 - GH * 0.1), from: keeperX, t: stageT + 90)
        ball = Ball(sx: bx, sy: by, tx: tx, ty: ty, curve: curve, t0: now, dur: Double(560 - power * 90))
        sfx("kick")
        buzz("medium")
    }

    private func resolve() {
        guard let b = ball, let d = dive else { return }
        let post = 7 * S
        var res: Result
        if b.ty < gy0 - 4 * S || b.tx < gx0 - 2 || b.tx > gx1 + 2 {
            let nearPost = abs(b.tx - gx0) < post * 2 || abs(b.tx - gx1) < post * 2 || abs(b.ty - gy0) < post * 2
            res = nearPost ? .post : .miss
        } else {
            let dist = hypot(b.tx - d.x, (b.ty - d.y) * 1.25)
            res = dist < reach ? .save : .goal
        }
        results.append(res)
        switch res {
        case .goal:
            goals += 1
            let corner = abs(b.tx - w / 2) > GW * 0.33 && b.ty < gy0 + GH * 0.45
            if corner { bonus += 6 }
            netAt = (p: P(b.tx, b.ty), t: now)
            sfx("net")
            sfx("crowd")
            buzz("success")
            pops.add("GOAL!", w / 2, h * 0.5, L(.shoulders, 96 * S, lime).outline(Color(hex: 0x06210f), 10).deep(Color(hex: 0x0a3b18), 7), life: 1.2, rise: 10)
            if corner { pops.add("В ДЕВЯТКУ +6", w / 2, h * 0.62, L(.inter, 22 * S, .white), life: 1.1, from: 1.3) }
            parts.burst(w / 2, h * 0.45, n: 70, colors: [lime, .white, Color(hex: 0xffe14d), Color(hex: 0x4da3ff)], speed: 520 * S, gravity: 420, size: 7, life: 1.4)
            flash = 1
        case .save:
            sfx("punch")
            sfx("block")
            buzz("heavy")
            shake.kick(6 * S, 0.25)
            pops.add("СЕЙВ", w / 2, h * 0.5, L(.inter, 56 * S, .white).outline(Color(hex: 0x111111), 8).squeeze(0.85), life: 1)
        case .post, .miss:
            if res == .post { sfx("post"); buzz("rigid") } else { sfx("sad", 0.6); buzz("light") }
            pops.add(res == .post ? "ШТАНГА" : "МИМО", w / 2, h * 0.5, L(.inter, 52 * S, Color(hex: 0xff6b5b)).outline(Color(hex: 0x111111), 8).squeeze(0.85), life: 1)
        }
        report()
        stage = .result
        stageT = now
    }

    override func onDown(_ p: CGPoint) { trail = [p] }

    override func onMove(_ p: CGPoint, _ prev: CGPoint) {
        trail.append(p)
        if trail.count > 30 { trail.removeFirst() }
    }

    override func onSwipe(_ g: Gestures.Swipe) {
        guard live, stage == .aim, g.dy <= -30 else { return }
        let dirX = g.dx / -g.dy
        let mid = (gy0 + gy1) / 2
        let tx = bx + dirX * (by - mid) * 1.02
        let power = clamp(hypot(g.vx, g.vy) / 2600, 0.2, 1.3)
        let ty = gy1 - power * GH * 1.04
        // закрутка: насколько середина пути ушла вбок от прямой
        let pth = g.path
        var curve: CGFloat = 0
        if pth.count > 2, let a = pth.first, let b = pth.last {
            let m = pth[pth.count / 2]
            let len = max(1, hypot(b.x - a.x, b.y - a.y))
            let dev = ((b.x - a.x) * (a.y - m.y) - (a.x - m.x) * (b.y - a.y)) / len
            curve = clamp(-dev / 50, -1, 1)
        }
        kick(tx, ty, curve, power)
    }

    override func update() {
        if dive == nil {
            let roll = rolls[shot % SHOTS]
            let amp = CGFloat([0.12, 0.16, 0.2][R])
            keeperX = w / 2 + sinv(now / 520 + roll.sway) * GW * amp
        }
        if live && stage == .aim && now - stageT > 2800 {
            kick(w / 2 + CGFloat.random(in: -15...15), gy1 - GH * 0.3, 0, 0.3)
        }
        if stage == .fly, let b = ball, now - b.t0 >= b.dur { resolve() }
        if stage == .result && now - stageT > 1000 {
            shot += 1
            if shot >= SHOTS {
                stage = .over
                finish(score(), 300)
            } else {
                stage = .aim
                stageT = now
                ball = nil
                dive = nil
                netAt = nil
                trail = []
            }
        }
        flash = max(0, flash - dt * 2)
    }

    // MARK: рисование

    private func keeper(_ x: inout GraphicsContext) {
        var kx = keeperX
        let ky = gy1
        var rot: CGFloat = 0
        var lift: CGFloat = 0
        if let d = dive, now > d.t {
            let e = CGFloat(Ease.out(clamp((now - d.t) / 360, 0, 1)))
            kx = d.from + (d.x - d.from) * e
            lift = (gy1 - d.y) * e * 0.9
            let side: CGFloat = d.x >= d.from ? 1 : -1
            rot = side * clamp(abs(d.x - d.from) / (GW * 0.3), 0, 1) * 1.2 * e
        }
        let H = GH * 0.72
        let s = H / 140
        var k = x
        k.translateBy(x: kx, y: ky - lift)
        k.rotate(by: .radians(Double(rot)))
        k.fillColor(Shape2.ellipse(.zero, 30 * s, 6 * s), Color.black.opacity(0.35))
        var legs = Path()
        legs.move(to: P(-10 * s, -60 * s)); legs.addLine(to: P(-18 * s, -2 * s))
        legs.move(to: P(10 * s, -60 * s)); legs.addLine(to: P(18 * s, -2 * s))
        k.strokeColor(legs, Color(hex: 0x141414), 13 * s)
        let jersey = G([(0, Color(hex: 0xd9c400)), (0.5, Color(hex: 0xfff04a)), (1, Color(hex: 0xbba800))])
        k.fill(Shape2.rrect(-26 * s, -112 * s, 52 * s, 58 * s, 12 * s), with: linear(jersey, P(-30 * s, 0), P(30 * s, 0)))
        Lettering.draw(&k, "1", at: P(0, -86 * s), L(.shoulders, 30 * s, Color(hex: 0x111111)))
        let arm = sinv(now / 160) * 0.15
        var arms = Path()
        arms.move(to: P(-22 * s, -104 * s)); arms.addLine(to: P(-58 * s, -118 * s + arm * 40 * s))
        arms.move(to: P(22 * s, -104 * s)); arms.addLine(to: P(58 * s, -118 * s - arm * 40 * s))
        k.strokeColor(arms, Color(hex: 0xd9c400), 11 * s)
        var palms = Shape2.circle(P(-62 * s, -120 * s + arm * 40 * s), 10 * s)
        palms.addPath(Shape2.circle(P(62 * s, -120 * s - arm * 40 * s), 10 * s))
        k.fillColor(palms, Color(hex: 0xff5a1f))
        k.fillColor(Shape2.circle(P(0, -128 * s), 15 * s), Color(hex: 0xe0a47e))
        k.fillColor(Shape2.arc(P(0, -133 * s), 15 * s, Double.pi, TAU), Color(hex: 0x1a1a1a))
    }

    private func soccerBall(_ x: inout GraphicsContext, _ X: CGFloat, _ Y: CGFloat, _ r: CGFloat, _ spin: Double) {
        var b = x
        b.translateBy(x: X, y: Y)
        b.rotate(by: .radians(spin))
        b.fill(Shape2.circle(.zero, r), with: radial(G([(0, .white), (1, Color(hex: 0xbfc6cf))]), P(-r * 0.35, -r * 0.35), r * 0.1, r))
        var patches = Path()
        func pent(_ cx: CGFloat, _ cy: CGFloat, _ rr: CGFloat) {
            var pts: [CGPoint] = []
            for i in 0..<5 {
                let a = -Double.pi / 2 + Double(i) * TAU / 5
                pts.append(P(cx + cosv(a) * rr, cy + sinv(a) * rr))
            }
            patches.addPath(Shape2.poly(pts))
        }
        pent(0, 0, r * 0.32)
        for i in 0..<5 {
            let a = -Double.pi / 2 + Double(i) * TAU / 5
            pent(cosv(a) * r * 0.82, sinv(a) * r * 0.82, r * 0.2)
        }
        b.clip(to: Shape2.circle(.zero, r))
        b.fillColor(patches, Color(hex: 0x16181c))
    }

    override func draw(_ g: inout GraphicsContext) {
        var x = world(g)
        let pitchY = gy1
        let skyGrad = G([(0, Color(hex: 0x050a14)), (1, Color(hex: 0x0c1d2e))])
        x.fill(Shape2.rect(-20, -20, w + 40, pitchY + 30), with: linear(skyGrad, P(0, 0), P(0, pitchY)))
        // трибуны: точки сгруппированы по цвету и яркости, чтобы рисовать быстро
        var buckets = Array(repeating: Array(repeating: Path(), count: 4), count: fanColors.count)
        let standH = gy0 - h * 0.02 + GH * 0.55
        for p in crowd {
            let v = sin(now / 300 + p.ph)
            let level = min(3, Int(v * v * 4))
            buckets[p.c][level].addRect(CGRect(x: p.x, y: h * 0.02 + p.y * standH, width: 2, height: 2))
        }
        for ci in 0..<fanColors.count {
            for lv in 0..<4 {
                x.fillColor(buckets[ci][lv], fanColors[ci].opacity(0.35 + 0.35 * Double(lv) / 3))
            }
        }
        for lx in [CGFloat(0.08), CGFloat(0.92)] {
            let beam = G([(0, Color(hex: 0xebf5ff, alpha: 0.75)), (0.12, Color(hex: 0xebf5ff, alpha: 0.18)), (1, Color(hex: 0xebf5ff, alpha: 0))])
            x.fill(Shape2.rect(0, 0, w, h * 0.6), with: radial(beam, P(w * lx, h * 0.03), 2, w * 0.5))
        }
        // рекламный борт
        x.fillColor(Shape2.rect(0, gy0 + GH * 0.55, w, GH * 0.45), Color(hex: 0x05070c))
        let ad = CGFloat(now / 18).truncatingRemainder(dividingBy: w * 0.8)
        for i in -1..<3 {
            let col = i % 2 != 0 ? lime : Color(hex: 0x4da3ff)
            Lettering.draw(&x, "СЛОУ · ТВ · СЛОУ ·", at: P(CGFloat(i) * w * 0.8 - ad, gy0 + GH * 0.78), L(.inter, 20 * S, col).squeeze(0.8).lead().spaced(2).fade(0.85))
        }
        // поле
        for i in 0..<9 {
            let y0 = pitchY + (h - pitchY) * CGFloat(pow(Double(i) / 9, 1.6))
            let y1 = pitchY + (h - pitchY) * CGFloat(pow(Double(i + 1) / 9, 1.6))
            x.fillColor(Shape2.rect(-20, y0, w + 40, y1 - y0 + 1), i % 2 == 1 ? Color(hex: 0x1f7a36) : Color(hex: 0x1a6b2f))
        }
        var lines = Shape2.line(P(-10, pitchY + 2), P(w + 10, pitchY + 2))
        var box = Path()
        box.move(to: P(gx0 - GW * 0.12, pitchY))
        box.addLine(to: P(gx0 - GW * 0.42, h * 0.66))
        box.addLine(to: P(gx1 + GW * 0.42, h * 0.66))
        box.addLine(to: P(gx1 + GW * 0.12, pitchY))
        lines.addPath(box)
        lines.addPath(Shape2.ellipseArc(P(w / 2, h * 0.66), GW * 0.32, h * 0.06, 0, Double.pi))
        x.strokeColor(lines, Color.white.opacity(0.8), 2.5 * S)
        var turf = x
        turf.clip(to: Path(CGRect(x: 0, y: pitchY, width: w, height: h - pitchY)))
        Grain.draw(&turf, CGRect(x: 0, y: pitchY, width: w, height: h - pitchY), alpha: 0.12, opacity: 0.6)
        x.fillColor(Shape2.ellipse(P(bx, by + br * 0.8), 6 * S, 3 * S), Color.white.opacity(0.85))
        // сетка, прогибается от гола
        x.fillColor(Shape2.rect(gx0, gy0, GW, GH), Color.white.opacity(0.04))
        func bulge(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            guard let n = netAt else { return P(px, py) }
            let k = clamp((now - n.t) / 500, 0, 1)
            let d = hypot(px - n.p.x, py - n.p.y)
            let amp = CGFloat(sin(k * Double.pi)) * 26 * S * max(0, 1 - d / (GW * 0.3))
            return P(px, py - amp * 0.4)
        }
        var mesh = Path()
        for i in 0...18 {
            let X = gx0 + GW * CGFloat(i) / 18
            for j in 0...8 {
                let q = bulge(X, gy0 + GH * CGFloat(j) / 8)
                if j == 0 { mesh.move(to: q) } else { mesh.addLine(to: q) }
            }
        }
        for j in 0...8 {
            let Y = gy0 + GH * CGFloat(j) / 8
            for i in 0...18 {
                let q = bulge(gx0 + GW * CGFloat(i) / 18, Y)
                if i == 0 { mesh.move(to: q) } else { mesh.addLine(to: q) }
            }
        }
        x.strokeColor(mesh, Color.white.opacity(0.28), 1)
        var back = Path()
        back.move(to: P(gx0, gy0))
        back.addLine(to: P(gx0 + GW * 0.06, gy0 - GH * 0.06))
        back.addLine(to: P(gx1 - GW * 0.06, gy0 - GH * 0.06))
        back.addLine(to: P(gx1, gy0))
        x.strokeColor(back, Color.white.opacity(0.18), 1)
        keeper(&x)
        var frame = Shape2.rect(gx0 - 7 * S, gy0 - 7 * S, 7 * S, GH + 7 * S)
        frame.addPath(Shape2.rect(gx1, gy0 - 7 * S, 7 * S, GH + 7 * S))
        frame.addPath(Shape2.rect(gx0 - 7 * S, gy0 - 7 * S, GW + 14 * S, 7 * S))
        var posts = x
        posts.addFilter(.shadow(color: Color.white.opacity(0.6), radius: 8))
        posts.fillColor(frame, Color(hex: 0xf4f6fa))
        // мяч
        if let b = ball {
            let k = clamp((now - b.t0) / b.dur, 0, 1)
            let e = CGFloat(Ease.out(k))
            let cx = (b.sx + b.tx) / 2 + b.curve * 110 * S
            let cy = (b.sy + b.ty) / 2 - 30 * S
            let u = 1 - e
            var X = u * u * b.sx + 2 * u * e * cx + e * e * b.tx
            var Y = u * u * b.sy + 2 * u * e * cy + e * e * b.ty
            if stage == .result || stage == .over, let res = results.last {
                let f = CGFloat(clamp((now - stageT) / 600, 0, 1))
                let away: CGFloat = b.tx < w / 2 ? -1 : 1
                switch res {
                case .save: X = b.tx + away * f * 140 * S; Y = b.ty + f * f * 160 * S - f * 40 * S
                case .goal: Y = b.ty + f * f * (gy1 - b.ty - 10 * S)
                case .post: X = b.tx + away * f * 90 * S; Y = b.ty + f * 120 * S
                case .miss: Y = b.ty - f * 60 * S
                }
            }
            let settled = stage == .result || stage == .over
            let r = br * (1 - 0.55 * (settled ? 1 : e))
            let shadowY = max(Y + r, pitchY + (by - pitchY) * (1 - e))
            x.fillColor(Shape2.ellipse(P(X, shadowY), r, r * 0.3), Color.black.opacity(0.3))
            soccerBall(&x, X, Y, r, (now - b.t0) / 60 * Double(b.curve == 0 ? 0.4 : b.curve))
        } else {
            soccerBall(&x, bx, by, br, 0)
            if trail.count > 1 && live && stage == .aim {
                var tr = Path()
                tr.addLines(trail)
                x.strokeColor(tr, lime.opacity(0.55), 4 * S)
            }
            if live && stage == .aim {
                Lettering.draw(&x, "СВАЙП ↑", at: P(bx, by + 46 * S), L(.inter, 16 * S, Color.white.opacity(0.6)).squeeze(0.85).spaced(2).fade(0.6 + 0.4 * sin(now / 200)))
            }
        }
        // табло
        g.fillColor(Shape2.rrect(14 * S, 12 * S, 176 * S, 34 * S, 8 * S), Color(hex: 0x050a14, alpha: 0.85))
        g.fillColor(Shape2.rrect(14 * S, 12 * S, 8 * S, 34 * S, 4 * S), lime)
        Lettering.draw(&g, "СЛОУ ТВ", at: P(30 * S, 29 * S), L(.inter, 14 * S, .white).squeeze(0.85).lead().spaced(1))
        for i in 0..<SHOTS {
            var col = Color.white.opacity(0.2)
            if i < results.count { col = results[i] == .goal ? lime : Color(hex: 0xff5a5a) }
            g.fillColor(Shape2.circle(P(114 * S + CGFloat(i) * 19 * S, 29 * S), 6.5 * S), col)
        }
        overlays(&g)
        if flash > 0 { g.fillColor(Shape2.rect(0, 0, w, h), lime.opacity(flash * 0.25)) }
    }
}
