import SwiftUI

/// САМУРАЙ. Рисовая бумага, тушь и красная печать. Режь фрукты взмахом пальца,
/// бомбы не трогай. Три фрукта одним взмахом — комбо.
final class SamuraiGame: GameBase {
    private struct Fruit { var skin: Color; var dark: Color; var flesh: Color; var seed: Color; var r: CGFloat; var melon: Bool }
    private struct Item { var t: Double; var x0: CGFloat; var vx: CGFloat; var vy: CGFloat; var bomb: Bool; var f: Int; var r: CGFloat; var spin: Double; var alive: Bool }
    private struct Half { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat; var ang: Double; var side: CGFloat; var f: Int; var r: CGFloat; var rot: Double; var spin: Double; var life: Double }
    private struct Splat { var path: Path; var color: Color; var alpha: Double }
    private struct BladePoint { var p: CGPoint; var t: Double }

    private let paper = Color(hex: 0xefe6d2)
    private let inkC = Color(hex: 0x14100c)
    private let red = Color(hex: 0xe2402f)
    private let fruits: [Fruit] = [
        Fruit(skin: Color(hex: 0x2f7d32), dark: Color(hex: 0x1b4d1e), flesh: Color(hex: 0xe8414a), seed: Color(hex: 0x2a1a12), r: 34, melon: true),
        Fruit(skin: Color(hex: 0xf28c1c), dark: Color(hex: 0xb85d0a), flesh: Color(hex: 0xffb347), seed: Color(hex: 0xfff2c8), r: 26, melon: false),
        Fruit(skin: Color(hex: 0xd42a2a), dark: Color(hex: 0x7c1010), flesh: Color(hex: 0xfff0c9), seed: Color(hex: 0x4a2a12), r: 25, melon: false),
        Fruit(skin: Color(hex: 0x5b2a86), dark: Color(hex: 0x2d1145), flesh: Color(hex: 0xffd25c), seed: Color(hex: 0x7a3a12), r: 22, melon: false)
    ]
    private let gravity: CGFloat
    private var items: [Item] = []
    private var halves: [Half] = []
    private var splats: [Splat] = []
    private var blade: [BladePoint] = []
    private var points = 0
    private var stroke = 0
    private var flash: Double = 0

    override init(_ c: GameContext) {
        gravity = c.h * 1.9
        super.init(c)
        let rate = [1.5, 1.9, 2.3][R]
        let bombP = [0.1, 0.16, 0.22][R]
        var t = 300.0
        while t < 8400 {
            let volley = c.rnd.next() < 0.25 ? 2 + Int(c.rnd.next() * 2) : 1
            for i in 0..<volley {
                let bomb = c.rnd.next() < bombP
                let f = c.rnd.int(fruits.count)
                let vy = CGFloat(sqrt(2 * Double(gravity) * Double(h) * (0.55 + c.rnd.next() * 0.3)))
                let x0 = w * CGFloat(0.15 + c.rnd.next() * 0.7)
                let vx = CGFloat(c.rnd.next() - 0.5) * w * 0.55
                let r = (bomb ? 26 : fruits[f].r) * S
                let spin = (c.rnd.next() - 0.5) * 6
                items.append(Item(t: t + Double(i) * 90, x0: x0, vx: vx, vy: vy, bomb: bomb, f: f, r: r, spin: spin, alive: true))
            }
            t += 1000 / rate * (0.6 + c.rnd.next() * 0.9)
        }
    }

    override func score() -> Int { Int((Double(points) * 100 / 26).rounded()) }

    override func end() { endStroke() }

    private func position(_ it: Item) -> (s: Double, p: CGPoint) {
        let s = (now - t0 - it.t) / 1000
        let sc = CGFloat(s)
        let x = it.x0 + it.vx * sc
        let y = h + 30 * S - it.vy * sc + gravity * sc * sc / 2
        return (s, P(x, y))
    }

    private func splat(_ p: CGPoint, _ col: Color, big: Bool) {
        var drops = Path()
        for _ in 0..<(big ? 26 : 12) {
            let a = Double.random(in: 0...TAU)
            let d = CGFloat.random(in: 0...1) * (big ? 70 : 34) * S
            let r = (big ? 6 : 3) * S * CGFloat.random(in: 0.4...1.4)
            drops.addPath(Shape2.circle(P(p.x + cosv(a) * d, p.y + sinv(a) * d), r))
        }
        splats.append(Splat(path: drops, color: col, alpha: 0.55))
        splats.append(Splat(path: Shape2.circle(p, (big ? 24 : 12) * S), color: col, alpha: 0.7))
        if splats.count > 80 { splats.removeFirst(splats.count - 80) }
    }

    private func cut(_ index: Int, at p: CGPoint, angle: Double) {
        items[index].alive = false
        let it = items[index]
        if it.bomb {
            points = max(0, points - 4)
            flash = 1
            shake.kick(16 * S, 0.5)
            sfx("boom", 0.9)
            buzz("heavy")
            splat(p, inkC, big: true)
            pops.add("−4", p.x, p.y - 30 * S, L(.plex, 40 * S, inkC).outline(paper, 5))
            parts.burst(p.x, p.y, n: 40, colors: [inkC, Color(hex: 0x3a332c), red], speed: 520 * S, gravity: 300, size: 6, life: 0.8)
        } else {
            points += 1
            stroke += 1
            let fr = fruits[it.f]
            sfx("slash", 0.8, rate: Float.random(in: 0.9...1.15))
            sfx("splat", 0.5)
            buzz("light")
            splat(p, fr.flesh, big: false)
            for side in [CGFloat(-1), CGFloat(1)] {
                let vx = cosv(angle + Double.pi / 2) * side * 120 * S + it.vx * 0.3
                halves.append(Half(x: p.x, y: p.y, vx: vx, vy: -120 * S, ang: angle, side: side, f: it.f, r: it.r, rot: 0, spin: Double(side) * 3, life: 1.6))
            }
            parts.burst(p.x, p.y, n: 14, colors: [fr.flesh, fr.skin], speed: 300 * S, gravity: 900, size: 4, life: 0.6)
        }
        report()
    }

    private func endStroke() {
        if stroke >= 3 {
            points += (stroke - 2) * 2
            pops.add("КОМБО ×\(stroke)", w / 2, h * 0.3, L(.plex, 42 * S, red).outline(paper, 6), life: 1)
            buzz("success")
            sfx("ding")
            report()
        }
        stroke = 0
    }

    override func onDown(_ p: CGPoint) {
        blade = [BladePoint(p: p, t: now)]
        stroke = 0
    }

    override func onMove(_ p: CGPoint, _ prev: CGPoint) {
        guard live else { return }
        let q = blade.last?.p ?? prev
        blade.append(BladePoint(p: p, t: now))
        if blade.count > 24 { blade.removeFirst() }
        let len = hypot(p.x - q.x, p.y - q.y)
        if len < 4 { return }
        let ang = atan2(Double(p.y - q.y), Double(p.x - q.x))
        for i in items.indices where items[i].alive {
            let o = position(items[i])
            if o.s < 0 { continue }
            let tt = clamp(((o.p.x - q.x) * (p.x - q.x) + (o.p.y - q.y) * (p.y - q.y)) / (len * len), 0, 1)
            let nx = q.x + (p.x - q.x) * tt - o.p.x
            let ny = q.y + (p.y - q.y) * tt - o.p.y
            if hypot(nx, ny) < items[i].r * 1.05 { cut(i, at: o.p, angle: ang) }
        }
    }

    override func onUp(_ p: CGPoint) { endStroke() }

    override func update() {
        let d = CGFloat(dt)
        for i in halves.indices {
            halves[i].vy += gravity * d
            halves[i].x += halves[i].vx * d
            halves[i].y += halves[i].vy * d
            halves[i].rot += halves[i].spin * dt
            halves[i].life -= dt
        }
        halves.removeAll { $0.life <= 0 || $0.y > h + 100 }
        flash = max(0, flash - dt * 3)
    }

    private func fruit(_ g: inout GraphicsContext, _ p: CGPoint, _ it: Item, _ rot: Double) {
        let f = fruits[it.f]
        let r = it.r
        var c = g
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .radians(rot))
        c.fillColor(Shape2.ellipse(P(5 * S, 7 * S), r, r * 0.95), inkC.opacity(0.18))
        let body = G([(0, f.flesh), (0.25, f.skin), (1, f.dark)])
        c.fill(Shape2.circle(.zero, r), with: radial(body, P(-r * 0.35, -r * 0.35), r * 0.1, r))
        if f.melon {
            var stripes = Path()
            for i in -2...2 { stripes.addPath(Shape2.ellipse(P(CGFloat(i) * r * 0.32, 0), r * 0.12, r * 0.96)) }
            var inside = c
            inside.clip(to: Shape2.circle(.zero, r))
            inside.strokeColor(stripes, f.dark, 3 * S)
        }
        c.strokeColor(Shape2.circle(.zero, r), inkC, 2.2 * S)
        c.fillColor(Shape2.ellipse(P(0, -r * 0.98), 2.5 * S, 5 * S, rotation: 0.3), inkC)
    }

    private func bomb(_ g: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat, _ rot: Double) {
        var c = g
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .radians(rot))
        c.fill(Shape2.circle(.zero, r), with: radial(G([(0, Color(hex: 0x5a524a)), (1, Color(hex: 0x0e0b08))]), P(-r * 0.3, -r * 0.3), 2, r))
        c.strokeColor(Shape2.circle(.zero, r * 0.62), red, 3 * S)
        Lettering.draw(&c, "✕", at: P(0, 1), L(.plex, r * 1.1, red))
        var fuse = Path()
        fuse.move(to: P(0, -r))
        fuse.addQuadCurve(to: P(r * 0.2, -r * 1.6), control: P(r * 0.4, -r * 1.4))
        c.strokeColor(fuse, Color(hex: 0x8a6a3a), 3 * S)
        c.fillColor(Shape2.circle(P(r * 0.2, -r * 1.6), 4 * S), sin(now / 30) > 0 ? Color(hex: 0xffd23f) : Color(hex: 0xff6a2e))
    }

    override func draw(_ g: inout GraphicsContext) {
        var x = world(g)
        x.fillColor(Shape2.rect(-20, -20, w + 40, h + 40), paper)
        Grain.draw(&x, CGRect(x: 0, y: 0, width: w, height: h), alpha: 0.12, opacity: 0.9)
        x.fillColor(Shape2.circle(P(w * 0.72, h * 0.3), 96 * S), red.opacity(0.14))
        Lettering.draw(&x, "斬", at: P(w * 0.2, h * 0.74), L(.kanji, 170 * S, inkC.opacity(0.07)))
        for s in splats { x.fillColor(s.path, s.color.opacity(s.alpha)) }
        if live {
            for i in items.indices where items[i].alive {
                let o = position(items[i])
                if o.s < 0 { continue }
                if o.p.y > h + 80 * S && o.s > 0.4 { items[i].alive = false; continue }
                let it = items[i]
                if it.bomb { bomb(&x, o.p, it.r, o.s * it.spin) } else { fruit(&x, o.p, it, o.s * it.spin) }
            }
        }
        for hf in halves {
            let f = fruits[hf.f]
            var c = x
            c.translateBy(x: hf.x, y: hf.y)
            c.rotate(by: .radians(hf.ang + hf.rot))
            let a0 = hf.side > 0 ? 0 : Double.pi
            let a1 = hf.side > 0 ? Double.pi : TAU
            var shell = Shape2.arc(.zero, hf.r, a0, a1)
            shell.closeSubpath()
            c.fillColor(shell, f.skin)
            c.strokeColor(shell, inkC, 2 * S)
            var meat = Shape2.arc(.zero, hf.r * 0.82, a0, a1)
            meat.closeSubpath()
            c.fillColor(meat, f.flesh)
            var seeds = Path()
            for i in -2...2 { seeds.addPath(Shape2.ellipse(P(CGFloat(i) * hf.r * 0.25, hf.side * hf.r * 0.35), 1.6 * S, 3 * S)) }
            c.fillColor(seeds, f.seed)
        }
        // клинок: тушь, сужается к хвосту, по краю — красная нить
        let fresh = blade.filter { now - $0.t < 170 }
        if fresh.count > 1 {
            for i in 1..<fresh.count {
                let k = CGFloat(i) / CGFloat(fresh.count)
                x.strokeColor(Shape2.line(fresh[i - 1].p, fresh[i].p), inkC.opacity(Double(0.25 + 0.75 * k)), (2 + 11 * k) * S)
            }
            var thread = Path()
            thread.addLines(fresh.map { $0.p })
            x.strokeColor(thread, red, 2 * S)
        }
        overlays(&g)
        // печать-ханко со счётом
        var seal = g
        seal.translateBy(x: w - 50 * S, y: 52 * S)
        seal.rotate(by: .radians(-0.08))
        seal.fillColor(Shape2.rrect(-34 * S, -34 * S, 68 * S, 68 * S, 10 * S), Color(hex: 0xc4301f))
        Lettering.draw(&seal, "\(points)", at: P(0, 2 * S), L(.plex, 34 * S, paper))
        Lettering.draw(&g, "侍", at: P(34 * S, 50 * S), L(.kanji, 40 * S, inkC))
        if flash > 0 { g.fillColor(Shape2.rect(0, 0, w, h), Color.white.opacity(flash)) }
    }
}
