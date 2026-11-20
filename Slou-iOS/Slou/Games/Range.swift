import SwiftUI

/// ТИР. Ярмарочный тир под полосатым тентом с гирляндой. Стреляй касанием по уткам,
/// мишеням и банкам; зайца не трогать; звезда стоит тридцать. Шесть патронов, потом перезарядка.
final class RangeGame: GameBase {
    private enum Kind { case duck, bunny, target, can }
    private struct Target { var row: Int; var dir: CGFloat; var ph: Double; var v: Double; var kind: Kind; var down: Double; var hit: Bool }
    private struct Star { var t: Double; var x0: CGFloat; var y: CGFloat; var v: CGFloat; var hit: Bool }

    private let gold = Color(hex: 0xffcf40)
    private let cream = Color(hex: 0xfff6c8)
    private let brown = Color(hex: 0x3a1206)
    private let rows: [CGFloat]
    private var targets: [Target] = []
    private var holes: [CGPoint] = []
    private var points = 0
    private var ammo = 6
    private var reload: Double = 0
    private var star: Star?
    private var starAt: Double = 4000
    private var cross: (p: CGPoint, t: Double)?
    private var flash: Double = 0

    override init(_ c: GameContext) {
        rows = [c.h * 0.27, c.h * 0.47, c.h * 0.67]
        super.init(c)
        let sp = [1.0, 1.25, 1.5][R]
        lane(0, 1, 0.09 * sp, [.duck, .duck, .duck, .bunny, .duck, .duck])
        lane(1, -1, 0.07 * sp, [.target, .duck, .target, .target, .bunny])
        lane(2, 1, 0.11 * sp, [.can, .target, .can, .duck, .can, .can])
        starAt = 2500 + c.rnd.next() * 4500
    }

    private func lane(_ row: Int, _ dir: CGFloat, _ v: Double, _ kinds: [Kind]) {
        let off = c.rnd.int(kinds.count)
        for i in 0..<kinds.count {
            let ph = Double(i) / Double(kinds.count) + c.rnd.next() * 0.04
            targets.append(Target(row: row, dir: dir, ph: ph, v: v, kind: kinds[(i + off) % kinds.count], down: 0, hit: false))
        }
    }

    override func score() -> Int { Int((Double(points) / 1.4).rounded()) }

    private func position(_ t: Target) -> CGPoint {
        let span = w + 120 * S
        var ph = (t.ph + t.v * (now - t0) / 1000).truncatingRemainder(dividingBy: 1)
        if ph < 0 { ph += 1 }
        let x = t.dir > 0 ? -60 * S + CGFloat(ph) * span : w + 60 * S - CGFloat(ph) * span
        return P(x, rows[t.row])
    }

    private func size(_ k: Kind) -> CGFloat {
        switch k {
        case .duck, .bunny: return 30 * S
        case .target: return 28 * S
        case .can: return 20 * S
        }
    }

    private func starX() -> CGFloat {
        guard let s = star else { return -999 }
        return s.x0 + CGFloat((now - s.t) / 1000) * s.v
    }

    override func onDown(_ p: CGPoint) {
        guard live else { return }
        if reload > now { sfx("block", 0.6); return }
        ammo -= 1
        cross = (p: p, t: now)
        flash = 0.35
        sfx("shot")
        buzz("rigid")
        shake.kick(3 * S, 0.12)
        var hitStar = false
        var hitIndex: Int?
        if let s = star, !s.hit, hypot(p.x - starX(), p.y - s.y) < 26 * S { hitStar = true }
        if !hitStar {
            for i in targets.indices where !targets[i].hit {
                let o = position(targets[i])
                let sz = size(targets[i].kind)
                if hypot(p.x - o.x, p.y - (o.y - sz * 0.9)) < sz { hitIndex = i; break }
            }
        }
        if hitStar {
            star?.hit = true
            points += 30
            sfx("star")
            buzz("success")
            pops.add("+30", p.x, p.y - 20 * S, L(.arsenal, 40 * S, gold).outline(brown, 6))
            parts.burst(p.x, p.y, n: 30, colors: [gold, cream], speed: 400 * S, gravity: 300, size: 5, life: 0.8)
        } else if let i = hitIndex {
            targets[i].hit = true
            targets[i].down = now
            let t = targets[i]
            let o = position(t)
            let sz = size(t.kind)
            let center = hypot(p.x - o.x, p.y - (o.y - sz * 0.9)) < sz * 0.35
            var v = t.kind == .bunny ? -20 : t.kind == .can ? 15 : 10
            if center && v > 0 { v += 5 }
            points = max(0, points + v)
            if v < 0 {
                sfx("squeak")
                buzz("error")
            } else {
                sfx("tin", t.kind == .can ? 1 : 0.7, rate: t.kind == .can ? 1 : 1.4)
                buzz("medium")
            }
            pops.add((v > 0 ? "+" : "") + "\(v)", o.x, o.y - sz * 2, L(.arsenal, 34 * S, v > 0 ? cream : Color(hex: 0xff5a4a)).outline(brown, 6))
            parts.burst(o.x, o.y - sz, n: 12, colors: [Color(hex: 0xd9d2c3), gold], speed: 260 * S, gravity: 700, size: 4, life: 0.5)
        } else {
            holes.append(p)
            if holes.count > 60 { holes.removeFirst() }
        }
        if ammo <= 0 {
            reload = now + 900
            ammo = 6
            sfx("reload")
        }
        report()
    }

    override func update() {
        if live && star == nil && ms > starAt {
            star = Star(t: now, x0: -40 * S, y: h * 0.12, v: w * 0.9, hit: false)
            sfx("whistle", 0.7)
        }
        flash = max(0, flash - dt * 6)
    }

    private func drawTarget(_ g: inout GraphicsContext, _ t: Target) {
        let o = position(t)
        let s = size(t.kind)
        let down = t.hit ? CGFloat(clamp((now - t.down) / 220, 0, 1)) : 0
        var c = g
        c.translateBy(x: o.x, y: o.y)
        c.scaleBy(x: 1, y: max(0.02, 1 - down * 0.9))
        c.fillColor(Shape2.rect(-2 * S, -s * 0.2, 4 * S, s * 0.5), Color(hex: 0x5a3418))
        c.translateBy(x: 0, y: -s * 0.9)
        switch t.kind {
        case .duck:
            c.scaleBy(x: t.dir, y: 1)
            var body = Shape2.ellipse(.zero, s * 1.05, s * 0.62)
            body.addPath(Shape2.circle(P(s * 0.7, -s * 0.62), s * 0.42))
            c.fillColor(body, gold)
            c.fillColor(Shape2.poly([P(s * 1.05, -s * 0.66), P(s * 1.45, -s * 0.56), P(s * 1.05, -s * 0.46)]), Color(hex: 0xff7a1a))
            c.fillColor(Shape2.circle(P(s * 0.82, -s * 0.72), s * 0.07), Color(hex: 0x1b0c04))
            c.strokeColor(Shape2.ellipse(P(-s * 0.1, 0), s * 0.5, s * 0.28, rotation: -0.2), Color(hex: 0xc99410), 2 * S)
        case .target:
            let rings: [(CGFloat, Color)] = [(1, Color(hex: 0xf7efe0)), (0.75, Color(hex: 0xd6261c)), (0.5, Color(hex: 0xf7efe0)), (0.25, Color(hex: 0xd6261c))]
            for (r, col) in rings { c.fillColor(Shape2.circle(.zero, s * r), col) }
        case .can:
            let metal = G([(0, Color(hex: 0x8a8f99)), (0.4, Color(hex: 0xe6ebf2)), (1, Color(hex: 0x6a6f79))])
            c.fill(Shape2.rrect(-s * 0.6, -s, s * 1.2, s * 2, 4 * S), with: linear(metal, P(-s * 0.6, 0), P(s * 0.6, 0)))
            c.fillColor(Shape2.rect(-s * 0.6, -s * 0.35, s * 1.2, s * 0.7), Color(hex: 0xd6261c))
            Lettering.draw(&c, "СЛОУ", at: .zero, L(.arsenal, s * 0.42, cream))
        case .bunny:
            var body = Shape2.ellipse(.zero, s * 0.8, s * 0.7)
            body.addPath(Shape2.ellipse(P(-s * 0.3, -s), s * 0.16, s * 0.5, rotation: -0.2))
            body.addPath(Shape2.ellipse(P(s * 0.3, -s), s * 0.16, s * 0.5, rotation: 0.2))
            c.fillColor(body, Color(hex: 0xffb3c7))
            var eyes = Shape2.circle(P(-s * 0.25, -s * 0.1), s * 0.08)
            eyes.addPath(Shape2.circle(P(s * 0.25, -s * 0.1), s * 0.08))
            c.fillColor(eyes, Color(hex: 0x1b0c04))
            c.fillColor(Shape2.circle(P(0, s * 0.1), s * 0.1), Color(hex: 0xff5a7a))
        }
    }

    override func draw(_ g: inout GraphicsContext) {
        var x = world(g)
        // доски
        for i in 0..<12 {
            let y = CGFloat(i) * h / 12
            x.fillColor(Shape2.rect(-20, y, w + 40, h / 12 + 1), i % 2 == 1 ? Color(hex: 0x3d2213) : Color(hex: 0x46281a))
            x.fillColor(Shape2.rect(-20, y, w + 40, 2), Color.black.opacity(0.25))
        }
        Grain.draw(&x, CGRect(x: 0, y: 0, width: w, height: h), alpha: 0.14, opacity: 0.4)
        // гирлянда
        var on = Path(), off = Path()
        for i in 0..<14 {
            let lit = (Int(now / 220) + i) % 3 != 0
            let bulb = Shape2.circle(P(14 * S + CGFloat(i) * (w - 28 * S) / 13, h * 0.08 + 6 * S), 4.5 * S)
            if lit { on.addPath(bulb) } else { off.addPath(bulb) }
        }
        x.fillColor(off, Color(hex: 0x6b4a20))
        var glow = x
        glow.addFilter(.shadow(color: gold, radius: 12))
        glow.fillColor(on, Color(hex: 0xffe9a8))
        // рельсы
        for y in rows {
            x.fillColor(Shape2.rect(-10, y, w + 20, 8 * S), Color(hex: 0x7a5530))
            x.fillColor(Shape2.rect(-10, y + 8 * S, w + 20, 4 * S), Color(hex: 0x2a170b))
        }
        if live { for t in targets { drawTarget(&x, t) } }
        if let s = star, !s.hit {
            let sx = starX()
            if sx < w + 40 {
                Lettering.draw(&x, "★", at: P(sx, s.y), L(.arsenal, 52 * S, gold).halo(gold, 20).turn(now / 200))
            }
        }
        var holePath = Path()
        for p in holes { holePath.addPath(Shape2.circle(p, 3.5 * S)) }
        x.fillColor(holePath, Color(hex: 0x120804))
        x.strokeColor(holePath, Color(hex: 0xffdca0, alpha: 0.3), 1)
        // тент
        x.fillColor(Shape2.rect(-10, 0, w + 20, h * 0.06), Color(hex: 0x2a0e06))
        let n = 8
        let sw = (w + 20) / CGFloat(n)
        for i in 0..<n {
            var flap = Path()
            let x0 = -10 + CGFloat(i) * sw
            flap.move(to: P(x0, 0))
            flap.addLine(to: P(x0 + sw, 0))
            flap.addLine(to: P(x0 + sw, h * 0.05))
            flap.addArc(center: P(x0 + sw / 2, h * 0.05), radius: sw / 2, startAngle: .radians(0), endAngle: .radians(Double.pi), clockwise: false)
            flap.closeSubpath()
            x.fillColor(flap, i % 2 == 1 ? Color(hex: 0xf7efe0) : Color(hex: 0xd6261c))
        }
        // прилавок
        x.fillColor(Shape2.rect(-10, h * 0.8, w + 20, h * 0.2 + 10), Color(hex: 0x6b1a10))
        x.fillColor(Shape2.rect(-10, h * 0.8, w + 20, 4 * S), gold)
        Lettering.draw(&x, "ТИР «СЛОУ»", at: P(w / 2, h * 0.87), L(.arsenal, 28 * S, gold).spaced(3))
        // патроны
        for i in 0..<6 {
            let loaded = reload <= now && i < ammo
            let bx = w - 22 * S - CGFloat(i) * 15 * S
            let by = h * 0.94
            g.fillColor(Shape2.rrect(bx - 4 * S, by - 12 * S, 8 * S, 20 * S, 3 * S), loaded ? Color(hex: 0xe2b34a) : Color.white.opacity(0.12))
            if loaded { g.fillColor(Shape2.rect(bx - 4 * S, by + 4 * S, 8 * S, 4 * S), Color(hex: 0x9a6a1a)) }
        }
        Lettering.draw(&g, "\(points)", at: P(22 * S, h * 0.94), L(.arsenal, 30 * S, cream).lead())
        if reload > now {
            Lettering.draw(&g, "ПЕРЕЗАРЯДКА", at: P(w / 2, h * 0.74), L(.arsenal, 24 * S, cream).outline(brown, 5).fade(0.6 + 0.4 * sin(now / 60)))
        }
        if let cr = cross, now - cr.t < 260 {
            let k = (now - cr.t) / 260
            let r = CGFloat(14 + k * 10) * S
            var sight = Shape2.circle(cr.p, r)
            sight.addPath(Shape2.line(P(cr.p.x - r * 1.5, cr.p.y), P(cr.p.x + r * 1.5, cr.p.y)))
            sight.addPath(Shape2.line(P(cr.p.x, cr.p.y - r * 1.5), P(cr.p.x, cr.p.y + r * 1.5)))
            g.strokeColor(sight, cream.opacity(1 - k), 2.5)
            if k < 0.3 {
                Lettering.draw(&g, "BANG!", at: P(cr.p.x, cr.p.y - 40 * S), L(.erica, 26 * S, cream).outline(brown, 5).fade(1 - k * 3))
            }
        }
        overlays(&g)
        if flash > 0 { g.fillColor(Shape2.rect(0, 0, w, h), Color(hex: 0xfff0c8).opacity(flash * 0.4)) }
    }
}
