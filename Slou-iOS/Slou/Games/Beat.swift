import SwiftUI

/// РИТМ. Клуб с лазерами: три дорожки уходят к горизонту, ноты летят на тебя.
/// Тапай по дорожке, когда нота на линии, — каждая точная нота сыграет свою ноту мелодии.
final class BeatGame: GameBase {
    private struct Note { var t: Double; var lane: Int; var j: Int?; var n: Int }

    private let violet = Color(hex: 0x7d5cff)
    private let magenta = Color(hex: 0xff4fd8)
    private let beatMs: Double
    private let lead: Double = 1900
    private let fall: Double
    private let endMs: Double = 10000
    private let hitY: CGFloat
    private let vanY: CGFloat
    private var notes: [Note] = []
    private var sum = 0
    private var combo = 0
    private var glow: [Double] = [0, 0, 0]
    private var pulse: Double = 0
    private var lastBeat = -1
    private var lastHat = -1

    override init(_ c: GameContext) {
        let r = min(2, max(0, c.round))
        beatMs = 60000 / [104.0, 122.0, 140.0][r]
        fall = [1600.0, 1400.0, 1220.0][r]
        hitY = c.h * 0.8
        vanY = c.h * 0.08
        super.init(c)
        let scale = [0, 3, 5, 7, 10, 12]
        var b = 0
        while lead + Double(b) * beatMs < endMs - 300 {
            let t = lead + Double(b) * beatMs
            if b < 2 || c.rnd.next() < 0.8 { notes.append(Note(t: t, lane: c.rnd.int(3), j: nil, n: c.rnd.pick(scale))) }
            if R == 2 && c.rnd.next() < 0.22 {
                let l = c.rnd.int(3)
                notes.append(Note(t: t, lane: (l + 1) % 3, j: nil, n: c.rnd.pick(scale)))
            }
            if R > 0 && c.rnd.next() < [0, 0.3, 0.4][R] {
                notes.append(Note(t: t + beatMs / 2, lane: c.rnd.int(3), j: nil, n: c.rnd.pick(scale)))
            }
            b += 1
        }
    }

    override func score() -> Int { Int((Double(sum) / Double(max(1, notes.count * 2)) * 100).rounded()) }

    private func laneX(_ k: Int) -> (near: CGFloat, far: CGFloat) {
        let d = CGFloat(k - 1)
        return (w / 2 + d * w * 0.3, w / 2 + d * w * 0.045)
    }

    override func onDown(_ p: CGPoint) {
        let lane = clamp(Int(p.x / (w / 3)), 0, 2)
        hit(lane)
    }

    private func hit(_ lane: Int) {
        guard live else { return }
        glow[lane] = 1
        let t = now - t0
        var bestI: Int?
        var bd: Double = 150
        for i in notes.indices where notes[i].j == nil && notes[i].lane == lane {
            let d = abs(notes[i].t - t)
            if d < bd { bd = d; bestI = i }
        }
        let L0 = laneX(lane)
        guard let i = bestI else {
            sum = max(0, sum - 1)
            combo = 0
            sfx("buzz", 0.5)
            buzz("light")
            report()
            return
        }
        let j = bd <= 55 ? 2 : bd <= 120 ? 1 : 0
        notes[i].j = j
        if j > 0 {
            sum += j
            combo += 1
            sfx("note\(notes[i].n)", j == 2 ? 1 : 0.7)
            buzz(j == 2 ? "medium" : "light")
            parts.burst(L0.near, hitY, n: j == 2 ? 16 : 8, colors: [.white, violet, magenta], speed: 300 * S, angle: -Double.pi / 2, spread: 1.8, gravity: 200, life: 0.45)
            pops.add(j == 2 ? "ИДЕАЛЬНО" : "ХОРОШО", L0.near, hitY - 60 * S, L(.jura, (j == 2 ? 24 : 20) * S, j == 2 ? Color(hex: 0xfff27a) : Color(hex: 0xc9b6ff)), life: 0.5, from: 1.4, rise: 24)
        } else {
            combo = 0
            sfx("buzz", 0.5)
            pops.add("МИМО", L0.near, hitY - 60 * S, L(.jura, 20 * S, Color(hex: 0xff6b8b)), life: 0.5, from: 1.2)
        }
        report()
    }

    override func update() {
        let t = live ? now - t0 : 0
        if live {
            let b = Int(floor((t - lead) / beatMs))
            if b >= 0 && b != lastBeat && t < endMs {
                lastBeat = b
                sfx("drum", 0.8)
                pulse = 1
                if b % 2 == 0 { sfx("bass\((b / 2) % 4)", 0.7) }
            }
            let hb = Int(floor((t - lead - beatMs / 2) / beatMs))
            if hb >= 0 && hb != lastHat && t < endMs {
                lastHat = hb
                sfx("hat", 0.5)
            }
            for i in notes.indices where notes[i].j == nil && t - notes[i].t > 160 {
                notes[i].j = 0
                combo = 0
            }
        }
        pulse = max(0, pulse - dt * 3.5)
        for k in 0..<3 { glow[k] = max(0, glow[k] - dt * 5) }
    }

    override func draw(_ g: inout GraphicsContext) {
        let t = live ? now - t0 : 0
        g.fillColor(Shape2.rect(0, 0, w, h), Color(hex: 0x07030f))
        // эквалайзер
        var eq = Path()
        for i in 0..<18 {
            let lvl = (sin(now / 160 + Double(i) * 1.7) * 0.5 + 0.5) * (0.25 + pulse * 0.75)
            let hh = CGFloat(lvl) * h * 0.22
            eq.addRect(CGRect(x: CGFloat(i) * w / 18 + 2, y: vanY + h * 0.3 - hh, width: w / 18 - 4, height: hh))
        }
        g.fillColor(eq, violet.opacity(0.15 + pulse * 0.2))
        // лазеры
        for i in 0..<4 {
            let a = sin(now / 900 + Double(i) * 1.6) * 0.9
            let tip = P(w / 2 + sinv(a) * h * 1.2, h)
            let col = i % 2 == 1 ? magenta : Color(hex: 0x40c8ff)
            let beam = linear(G([(0, col.opacity(0.25)), (1, col.opacity(0))]), P(w / 2, 0), P(w / 2 + sinv(a) * h, h))
            g.stroke(Shape2.line(P(w / 2, vanY), tip), with: beam, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        // дорожки в перспективе
        for k in 0..<3 {
            let ln = laneX(k)
            let half = w * 0.14, farHalf = w * 0.02
            let shape = Shape2.poly([P(ln.far - farHalf, vanY), P(ln.far + farHalf, vanY), P(ln.near + half, h), P(ln.near - half, h)])
            g.fill(shape, with: linear(G([(0, violet.opacity(0)), (1, violet.opacity(0.18 + glow[k] * 0.4))]), P(0, vanY), P(0, hitY)))
            g.strokeColor(shape, magenta.opacity(0.35), 1.5)
            var ring = g
            ring.addFilter(.shadow(color: magenta, radius: 14 * CGFloat(0.4 + glow[k])))
            ring.strokeColor(Shape2.ellipse(P(ln.near, hitY), half * 0.82, 12 * S), Color.white.opacity(0.5 + glow[k] * 0.5), 3)
        }
        // ноты
        for n in notes {
            if let j = n.j, j > 0 { continue }
            let k = 1 - (n.t - t) / fall
            if k < 0 || k > 1.15 { continue }
            let p = CGFloat(pow(clamp(k, 0, 1.15), 2.2))
            let ln = laneX(n.lane)
            let X = ln.far + (ln.near - ln.far) * p
            let Y = vanY + (hitY - vanY) * p
            let W = w * 0.02 + (w * 0.22 - w * 0.02) * p
            let H = (3 + 16 * p) * S
            let missed = n.j == 0
            var c = g
            c.addFilter(.shadow(color: missed ? Color(hex: 0xff5a78) : magenta, radius: 16 * p))
            c.fillColor(Shape2.rrect(X - W / 2, Y - H / 2, W, H, H / 2), missed ? Color(hex: 0xff5a78, alpha: 0.5) : .white)
        }
        overlays(&g)
        // точность с хроматическим сдвигом
        let sc = min(100, max(0, score()))
        var add = g
        add.blendMode = .plusLighter
        Lettering.draw(&add, "\(sc)%", at: P(w / 2 - 2 * S, h * 0.2), L(.jura, 46 * S, Color(red: 1, green: 40 / 255, blue: 120 / 255, opacity: 0.8)))
        Lettering.draw(&add, "\(sc)%", at: P(w / 2 + 2 * S, h * 0.2), L(.jura, 46 * S, Color(red: 40 / 255, green: 200 / 255, blue: 1, opacity: 0.8)))
        Lettering.draw(&g, "\(sc)%", at: P(w / 2, h * 0.2), L(.jura, 46 * S, .white))
        if combo >= 3 {
            Lettering.draw(&g, "КОМБО \(combo)", at: P(w / 2, h * 0.27), L(.jura, 20 * S, Color(hex: 0xfff27a)).spaced(3), scale: CGFloat(1 + pulse * 0.08))
        }
        let arrows = ["←", "↓", "→"]
        for k in 0..<3 {
            Lettering.draw(&g, arrows[k], at: P(laneX(k).near, hitY + 46 * S), L(.jura, 22 * S, Color.white.opacity(0.35)))
        }
    }
}
