import SwiftUI

/// АРМРЕСТЛИНГ. Кирпичный бар, неоновая вывеска, стол. Жми по экрану как можно чаще
/// (можно двумя пальцами) и дожми руку соперника к подушке. Соперник жмёт по-настоящему:
/// его темп приходит по сети из его счёта.
final class ArmGame: GameBase {
    private let pink = Color(hex: 0xff4fa3)
    private let cyan = Color(hex: 0x40c8ff)
    private let GOAL = 62
    private let table: CGFloat
    private let pivot: CGPoint
    private let lenArm: CGFloat
    private var bricks: [Double] = []
    private var ghost: Double = 6.2
    private var ghostPh: Double = 0
    private var taps = 0
    private var theta: CGFloat = 0
    private var mine: [Double] = []
    private var theirs: [Double] = []
    private var opLast = 0
    private var pinned = 0
    private var flick: Double = 0
    private var lastPump: Double = 0

    override init(_ c: GameContext) {
        table = c.h * 0.66
        pivot = CGPoint(x: c.w / 2, y: c.h * 0.66 - 8 * c.s)
        lenArm = 150 * c.s
        super.init(c)
        for _ in 0..<60 { bricks.append(c.rnd.next()) }
        ghost = [6.2, 7.4, 8.6][R]
        ghostPh = c.rnd.next() * 6
    }

    override func score() -> Int {
        let base = min(70.0, Double(taps) * 70 / Double(GOAL))
        return Int((base + (pinned > 0 ? 30 : 0)).rounded())
    }

    override func begin() {
        sfx("bell")
        buzz("medium")
    }

    override func onDown(_ p: CGPoint) {
        guard live, pinned == 0 else { return }
        taps += 1
        mine.append(now)
        sfx("pump\(taps % 6)", 0.7)
        buzz(taps % 4 == 0 ? "medium" : "light")
        if taps % 8 == 0 { shake.kick(2 * S, 0.1) }
        report()
    }

    private func rate(_ list: inout [Double], window: Double = 700) -> Double {
        while let first = list.first, now - first > window { list.removeFirst() }
        return Double(list.count) / (window / 1000)
    }

    private func opRate() -> Double {
        // соперник присылает очки: из них получаем его нажатия
        if let live = c.opponent() {
            let t = Int((min(70, Double(live)) * Double(GOAL) / 70).rounded())
            while opLast < t { theirs.append(now); opLast += 1 }
            return rate(&theirs)
        }
        let k = (now - t0) / 1000
        return ghost * (0.85 + 0.25 * sin(k * 2.3 + ghostPh))
    }

    override func update() {
        flick = max(0, flick - dt * 2)
        guard live, pinned == 0 else { return }
        let me = rate(&mine)
        let op = opRate()
        theta = clamp(theta + CGFloat((me - op) * dt * 0.075), -1, 1)
        if abs(theta) >= 1 {
            pinned = theta > 0 ? 1 : -1
            flick = 1
            shake.kick(14 * S, 0.4)
            if pinned > 0 {
                sfx("slam")
                sfx("crowd")
                buzz("success")
                pops.add("ДОЖАЛ!", w / 2, h * 0.26, L(.poiret, 56 * S, pink).halo(pink, 24), life: 1.5, rise: 0)
            } else {
                sfx("slam")
                sfx("sad", 0.7)
                buzz("error")
                pops.add("ПРИЖАЛИ", w / 2, h * 0.26, L(.poiret, 52 * S, Color(hex: 0x7fd8ff)).halo(Color(hex: 0x7fd8ff), 24), life: 1.5, rise: 0)
            }
            let side: CGFloat = theta > 0 ? 1 : -1
            parts.burst(pivot.x + side * lenArm * 0.95, table, n: 30, colors: [.white, Color(hex: 0xffd1e8)], speed: 300 * S, gravity: 600, life: 0.6)
            report()
            finish(score(), 1500)
        }
        if abs(theta) > 0.55 && now - lastPump > 420 {
            lastPump = now
            sfx("strain", 0.35)
        }
        if Double.random(in: 0...1) < dt * 4 {
            parts.burst(pivot.x + CGFloat.random(in: -30...30) * S, pivot.y - lenArm * 0.9, n: 1, colors: [Color(hex: 0xbfe8ff)], speed: 40, angle: Double.pi / 2, spread: 1, gravity: 600, size: 3, life: 1, round: true)
        }
    }

    private func arm(_ g: inout GraphicsContext, from e: CGPoint, to hnd: CGPoint, sleeve: Color, skin: (Color, Color), mine: Bool) {
        let shade = linear(G([(0, skin.1), (1, skin.0)]), e, hnd)
        g.stroke(Shape2.line(e, hnd), with: shade, style: StrokeStyle(lineWidth: 46 * S, lineCap: .round))
        if abs(theta) < 0.9 && live {
            var veins = Path()
            for i in 0..<2 {
                let off: CGFloat = i == 1 ? 8 : -6
                let off2: CGFloat = i == 1 ? 12 : -10
                veins.move(to: P(e.x + (hnd.x - e.x) * 0.2 + off * S, e.y + (hnd.y - e.y) * 0.2))
                veins.addQuadCurve(to: P(e.x + (hnd.x - e.x) * 0.75, e.y + (hnd.y - e.y) * 0.75), control: P(e.x + (hnd.x - e.x) * 0.5 + off2 * S, e.y + (hnd.y - e.y) * 0.5))
            }
            g.strokeColor(veins, Color.black.opacity(0.18), 3 * S)
        }
        g.fillColor(Shape2.circle(e, 30 * S), sleeve)
        let dir: CGFloat = mine ? -1 : 1
        g.strokeColor(Shape2.line(e, P(e.x + dir * 70 * S, e.y + 140 * S)), sleeve, 64 * S)
    }

    override func draw(_ g: inout GraphicsContext) {
        var x = world(g)
        x.fillColor(Shape2.rect(-20, -20, w + 40, h + 40), Color(hex: 0x140a10))
        // кирпичная стена
        let bw = 52 * S, bh = 22 * S
        var k = 0
        var y: CGFloat = 0
        var row = 0
        var tones = Array(repeating: Path(), count: 4)
        while y < table {
            var xx: CGFloat = row % 2 == 1 ? -bw / 2 : 0
            while xx < w {
                let v = bricks[k % bricks.count]
                k += 1
                tones[min(3, Int(v * 4))].addRect(CGRect(x: xx + 1, y: y + 1, width: bw - 2, height: bh - 2))
                xx += bw
            }
            y += bh
            row += 1
        }
        for i in 0..<4 {
            let v = (Double(i) + 0.5) / 4
            x.fillColor(tones[i], Color(red: (46 + v * 18) / 255, green: (20 + v * 8) / 255, blue: (26 + v * 8) / 255))
        }
        let lamp = G([(0, Color(hex: 0xffbe78, alpha: 0.35)), (1, Color.black.opacity(0.55))])
        x.fill(Shape2.rect(0, 0, w, table), with: radial(lamp, P(w / 2, table * 0.3), 10, h * 0.7))
        let flicker = sin(now / 37) > 0.96 ? 0.3 : 1.0
        Lettering.draw(&x, "армрестлинг", at: P(w / 2, h * 0.1), L(.poiret, 40 * S, Color(hex: 0xffd1e8)).halo(pink, 22).spaced(2).fade(flicker))
        Lettering.draw(&x, "до упора", at: P(w / 2, h * 0.17), L(.poiret, 20 * S, Color(hex: 0xc8f2ff)).halo(cyan, 16).spaced(3).fade(0.9))
        let wood = G([(0, Color(hex: 0x5a2e1a)), (1, Color(hex: 0x1e0d06))])
        x.fill(Shape2.rect(-20, table, w + 40, h - table + 20), with: linear(wood, P(0, table), P(0, h)))
        x.fillColor(Shape2.rect(-20, table, w + 40, 3 * S), Color(hex: 0xffc896, alpha: 0.25))
        // подушки по краям
        for s in [CGFloat(-1), CGFloat(1)] {
            var pad = x
            let col = s > 0 ? pink : cyan
            pad.addFilter(.shadow(color: col, radius: 10))
            pad.fillColor(Shape2.rrect(pivot.x + s * lenArm * 1.02 - 22 * S, table - 10 * S, 44 * S, 14 * S, 6 * S), col)
        }
        // руки: локти на столе, кисти сцеплены
        let tremble = live && pinned == 0 ? sin(now / 60) * 0.012 : 0
        let phi = Double(theta) * 1.32 + tremble
        let hx = pivot.x + sinv(phi) * lenArm * 0.78
        let hy = pivot.y - cosv(phi) * lenArm
        arm(&x, from: P(pivot.x - 46 * S, table + 4 * S), to: P(hx - 6 * S, hy + 8 * S), sleeve: Color(hex: 0x2d6fd6), skin: (Color(hex: 0xe8b48d), Color(hex: 0xb97b54)), mine: true)
        arm(&x, from: P(pivot.x + 46 * S, table + 4 * S), to: P(hx + 6 * S, hy + 8 * S), sleeve: Color(hex: 0xc42d78), skin: (Color(hex: 0xc58a63), Color(hex: 0x8a5434)), mine: false)
        let fist = G([(0, Color(hex: 0xf2c49e)), (1, Color(hex: 0xa8694a))])
        x.fill(Shape2.ellipse(P(hx, hy), 34 * S, 30 * S, rotation: CGFloat(phi)), with: radial(fist, P(hx - 6 * S, hy - 8 * S), 4, 34 * S))
        var knuckles = Path()
        for i in -1...1 {
            let ox = CGFloat(i) * 10 * S
            knuckles.addPath(Shape2.line(P(hx + ox - 14 * S, hy - 14 * S), P(hx + ox - 4 * S, hy + 8 * S)))
        }
        x.strokeColor(knuckles, Color(hex: 0x502814, alpha: 0.45), 2.5 * S)
        // шкала перевеса
        let mw = w * 0.7, mx = (w - mw) / 2, my = h * 0.9
        let pos = mx + mw * (theta + 1) / 2
        g.fillColor(Shape2.rrect(mx, my, mw, 10 * S, 5 * S), pink)
        var mineBar = g
        mineBar.addFilter(.shadow(color: cyan, radius: 14))
        mineBar.fillColor(Shape2.rrect(mx, my, max(10 * S, pos - mx), 10 * S, 5 * S), cyan)
        g.fillColor(Shape2.circle(P(pos, my + 5 * S), 9 * S), .white)
        Lettering.draw(&g, "ТЫ", at: P(mx, my + 30 * S), L(.poiret, 20 * S, Color(hex: 0x7fd8ff)).lead().halo(cyan, 10))
        Lettering.draw(&g, "ОН", at: P(mx + mw, my + 30 * S), L(.poiret, 20 * S, Color(hex: 0xff8cc4)).trail().halo(pink, 10))
        Lettering.draw(&g, "\(taps) нажатий", at: P(w / 2, my + 30 * S), L(.poiret, 16 * S, Color.white.opacity(0.7)))
        if live && pinned == 0 {
            Lettering.draw(&g, "ЖМИ!", at: P(w / 2, table + (h - table) * 0.38), L(.inter, 34 * S, .white).squeeze(0.85).fade(0.55 + 0.45 * sin(now / 70)))
        }
        overlays(&g)
        if flick > 0 { g.fillColor(Shape2.rect(0, 0, w, h), pink.opacity(flick * 0.3)) }
    }
}
