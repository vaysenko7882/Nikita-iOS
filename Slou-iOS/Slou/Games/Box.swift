import SwiftUI

/// БОКС. Вид от первого лица: соперник замахивается — уходи свайпом, раскрылся — бей касанием.
/// Уклонился от удара — он поплыл, и следующий удар идёт как «контра».
final class BoxGame: GameBase {
    private struct Move {
        var atk: Bool
        var t: Double
        var side: CGFloat
        var tell: Double
        var feint: Bool
        var len: Double
    }

    private struct Phase {
        enum K { case guardUp, open, tell, back, swing, dizzy, ko }
        var k: K
        var i: Int = -1
        var f: Double = 0
        var fromSwing = false
    }

    private struct Fan {
        var x: CGFloat
        var y: CGFloat
        var r: CGFloat
        var a: Double
        var ph: Double
        var warm: Bool
    }

    private struct Glove {
        var x: CGFloat
        var y: CGFloat
        var s: CGFloat
        var glow: Double
    }

    private static let names = ["ЖЕЛЕЗНЫЙ ГЕНА", "БЕШЕНЫЙ ЖОРА", "ЧЕМПИОН ТОЛИК"]
    private let ink = Color(hex: 0x1a0a08)
    private let gold = Color(hex: 0xffd23f)

    private var plan: [Move] = []
    private var crowd: [Fan] = []
    private var hp: Double = 100
    private var hits = 0
    private var counters = 0
    private var taken = 0
    private var ko = false
    private var koAt: Double = 0
    private var cam: CGFloat = 0
    private var dodgeDir: CGFloat = 0
    private var dodgeT: Double = -99999
    private var punchT: Double = -99999
    private var punchSide: CGFloat = 1
    private var lastPunch: Double = -99999
    private var headKick: CGFloat = 0
    private var flashRed: Double = 0
    private var flashBulb: Double = 0
    private var bulb = CGPoint.zero
    private var dizzyUntil: Double = 0
    private var openShown = -1
    private var done = Set<Int>()

    override init(_ c: GameContext) {
        super.init(c)
        let tell = [560.0, 450.0, 360.0][R]
        let feintChance = [0.0, 0.18, 0.28][R]
        var t = 900.0
        while t < 9200 {
            if c.rnd.next() < 0.56 {
                let tl = tell + c.rnd.next() * 140
                let side: CGFloat = c.rnd.next() < 0.5 ? -1 : 1
                let feint = R > 0 && c.rnd.next() < feintChance
                plan.append(Move(atk: true, t: t, side: side, tell: tl, feint: feint, len: 0))
                t += tl + 190 + 520 + c.rnd.next() * 300
            } else {
                let len = [950.0, 780.0, 640.0][R]
                plan.append(Move(atk: false, t: t, side: 0, tell: 0, feint: false, len: len))
                t += len + 380 + c.rnd.next() * 260
            }
        }
        for _ in 0..<80 {
            let x = CGFloat(c.rnd.next()) * w
            let y = CGFloat(c.rnd.next()) * h * 0.44
            let r = (2 + CGFloat(c.rnd.next()) * 6) * S
            let a = 0.06 + c.rnd.next() * 0.16
            let ph = c.rnd.next() * 6
            let warm = c.rnd.next() < 0.5
            crowd.append(Fan(x: x, y: y, r: r, a: a, ph: ph, warm: warm))
        }
    }

    override func score() -> Int {
        let v = hits * 7 + counters * 11 + (ko ? 25 : 0) - taken * 10
        return min(100, max(0, v))
    }

    override func begin() {
        sfx("bell")
        buzz("medium")
    }

    private func phase(_ ms: Double) -> Phase {
        if ko { return Phase(k: .ko) }
        if ms < dizzyUntil { return Phase(k: .dizzy) }
        for (i, p) in plan.enumerated() {
            if !p.atk {
                if ms >= p.t && ms < p.t + p.len { return Phase(k: .open, i: i) }
                continue
            }
            let e = p.t + p.tell
            if ms >= p.t && ms < e { return Phase(k: .tell, i: i, f: (ms - p.t) / p.tell) }
            if p.feint && ms >= e && ms < e + 260 { return Phase(k: .back, i: i, f: (ms - e) / 260) }
            if !p.feint && ms >= e && ms < e + 190 { return Phase(k: .swing, i: i, f: (ms - e) / 190, fromSwing: true) }
            if !p.feint && ms >= e + 190 && ms < e + 450 { return Phase(k: .back, i: i, f: (ms - e - 190) / 260, fromSwing: true) }
        }
        return Phase(k: .guardUp)
    }

    private func impact(_ p: Move) {
        let dodged = now - dodgeT < 480 && dodgeDir == -p.side
        if dodged {
            dizzyUntil = ms + 850
            sfx("whoosh")
            buzz("soft")
            pops.add("МИМО!", w / 2 - p.side * 90 * S, h * 0.3, L(.inter, 34 * S, Color(hex: 0xfff3d6)).outline(ink, 6).squeeze(0.8))
        } else {
            taken += 1
            flashRed = 1
            shake.kick(20 * S, 0.45)
            sfx("punch_big")
            buzz("heavy")
            pops.add("−10", w / 2, h * 0.62, L(.inter, 44 * S, Color(hex: 0xff3b2f)).outline(.white, 5).squeeze(0.8))
            parts.burst(w / 2, h * 0.7, n: 18, colors: [.white, Color(hex: 0xffd2c2), Color(hex: 0xff3b2f)], speed: 420 * S, gravity: 300, life: 0.5)
        }
        report()
    }

    override func onTap(_ p: CGPoint) {
        guard live, !ko, now - lastPunch >= 150 else { return }
        lastPunch = now
        punchT = now
        punchSide = -punchSide
        let ph = phase(now - t0)
        let hx = w / 2 + cam
        let hy = h * 0.37
        if ph.k == .open || ph.k == .dizzy || ph.k == .tell {
            let counter = ph.k == .dizzy
            hp -= counter ? 16 : 9
            if counter { counters += 1 } else { hits += 1 }
            headKick = 1
            sfx(counter ? "punch_big" : "punch")
            buzz(counter ? "heavy" : "medium")
            shake.kick((counter ? 9 : 5) * S, 0.2)
            parts.burst(hx + punchSide * 20 * S, hy, n: counter ? 22 : 12, colors: [.white, Color(hex: 0xbfe7ff), Color(hex: 0xfff0b3)], speed: 380 * S, gravity: 500, size: 5, life: 0.6)
            let word = counter ? "КОНТРА!" : (["БАМ!", "ПАУ!", "ХРЯСЬ!"].randomElement() ?? "БАМ!")
            let style = L(.inter, (counter ? 40 : 34) * S, counter ? gold : .white).outline(ink, 7).squeeze(0.78).turn(Double(punchSide) * -0.12)
            pops.add(word, hx + punchSide * 70 * S, hy - 40 * S, style)
            if hp <= 0 && !ko {
                ko = true
                koAt = now
                hp = 0
                sfx("crowd")
                sfx("bell")
                buzz("success")
                finish(score(), 2300)
            }
        } else {
            sfx("block")
            buzz("light")
            pops.add("БЛОК", hx + punchSide * 60 * S, hy + 20 * S, L(.inter, 22 * S, Color(hex: 0x9a8f86)).squeeze(0.8), life: 0.5, from: 1.2)
        }
        report()
    }

    override func onSwipe(_ s: Gestures.Swipe) {
        guard live, !ko, abs(s.dx) >= 40, abs(s.dx) >= abs(s.dy) else { return }
        dodgeDir = s.dx > 0 ? 1 : -1
        dodgeT = now
        sfx("whoosh", 0.7)
        buzz("soft")
    }

    override func update() {
        if live {
            for (i, p) in plan.enumerated() where p.atk && !p.feint && !done.contains(i) && ms >= p.t + p.tell + 170 {
                done.insert(i)
                impact(p)
            }
        }
        let target: CGFloat = now - dodgeT < 430 ? -dodgeDir * 92 * S : 0
        cam += (target - cam) * CGFloat(min(1, dt * 15))
        headKick = max(0, headKick - CGFloat(dt * 4))
        flashRed = max(0, flashRed - dt * 2.6)
        if live && Double.random(in: 0...1) < dt * 2 {
            flashBulb = 1
            bulb = P(CGFloat.random(in: 0...w), CGFloat.random(in: 0...(h * 0.4)))
        }
        flashBulb = max(0, flashBulb - dt * 9)
    }

    // MARK: рисование

    private func glove(_ g: inout GraphicsContext, _ gl: Glove, flip: CGFloat, mine: Bool) {
        var c = g
        c.translateBy(x: gl.x, y: gl.y)
        c.scaleBy(x: gl.s * S * flip, y: gl.s * S)
        let colors: [(CGFloat, Color)] = mine
            ? [(0, Color(hex: 0x7fb2ff)), (0.55, Color(hex: 0x2457e6)), (1, Color(hex: 0x0c1f63))]
            : [(0, Color(hex: 0xff7a63)), (0.55, Color(hex: 0xd8231c)), (1, Color(hex: 0x7c0b10))]
        var shell = Shape2.ellipse(P(0, -6), 40, 46)
        shell.addPath(Shape2.ellipse(P(-30, 6), 15, 20, rotation: -0.5))
        var body = c
        if gl.glow > 0 { body.addFilter(.shadow(color: Color(hex: 0xffec96, alpha: gl.glow), radius: 30)) }
        body.fill(shell, with: radial(G(colors), P(-10, -18), 4, 52))
        c.fillColor(Shape2.rrect(-30, 30, 60, 18, 7), Color(hex: 0xf4ead8))
        c.fillColor(Shape2.rect(-30, 41, 60, 4), Color.black.opacity(0.18))
        c.fillColor(Shape2.ellipse(P(-12, -26), 14, 8, rotation: -0.5), Color.white.opacity(0.38))
        c.strokeColor(Shape2.arc(P(4, -4), 26, 2.2, 3.6), Color(hex: 0x5a0000, alpha: 0.45), 2)
    }

    private func arm(_ g: inout GraphicsContext, cx: CGFloat, sh: CGFloat, side s: CGFloat, to gp: CGPoint, k: CGFloat) {
        let a = P(cx + s * 104 * S, sh + 14 * S)
        let e = P((a.x + gp.x) / 2 + s * 34 * S * k, max(a.y, gp.y) + 26 * S)
        let shade = linear(G([(0, Color(hex: 0xb77750)), (1, Color(hex: 0xd99a6c))]), a, gp)
        g.stroke(Shape2.line(a, e), with: shade, style: StrokeStyle(lineWidth: 40 * S * k, lineCap: .round))
        g.stroke(Shape2.line(e, P(gp.x, gp.y + 24 * S * k)), with: shade, style: StrokeStyle(lineWidth: 32 * S * k, lineCap: .round))
    }

    private func boxer(_ g: inout GraphicsContext, _ ph: Phase) {
        let t = now / 1000
        let fall: CGFloat = ph.k == .ko ? CGFloat(clamp((now - koAt) / 1100, 0, 1)) : 0
        let dazed = ph.k == .dizzy || ph.k == .ko
        let swayK: CGFloat = ph.k == .dizzy ? 2.4 : 1
        let cx = w / 2 + cam + sinv(t * 2.4) * 9 * S * swayK
        let kick = headKick
        let hy = h * 0.37 + sinv(t * 4.8) * 3 * S - kick * 10 * S
        let sh = h * 0.52
        var b = g
        if fall > 0 {
            b.translateBy(x: cx, y: h * 0.9)
            b.rotate(by: .radians(Double(-fall * 0.5 * punchSide)))
            b.translateBy(x: -cx, y: -h * 0.9 + fall * h * 0.18)
            b.opacity = Double(1 - fall * 0.35)
        }

        // торс
        var torso = Path()
        torso.move(to: P(cx - 118 * S, sh))
        torso.addQuadCurve(to: P(cx + 118 * S, sh), control: P(cx, sh - 30 * S))
        torso.addLine(to: P(cx + 160 * S, h + 20))
        torso.addLine(to: P(cx - 160 * S, h + 20))
        torso.closeSubpath()
        let skin = G([(0, Color(hex: 0x6b3a24)), (0.35, Color(hex: 0xc98559)), (0.6, Color(hex: 0xd99a6c)), (1, Color(hex: 0x5c311f))])
        b.fill(torso, with: linear(skin, P(cx - 150 * S, 0), P(cx + 150 * S, 0)))
        var belly = Path()
        belly.move(to: P(cx - 70 * S, sh + 60 * S))
        belly.addQuadCurve(to: P(cx, sh + 66 * S), control: P(cx - 30 * S, sh + 82 * S))
        belly.addQuadCurve(to: P(cx + 70 * S, sh + 60 * S), control: P(cx + 30 * S, sh + 82 * S))
        belly.move(to: P(cx, sh + 80 * S))
        belly.addLine(to: P(cx, h))
        b.strokeColor(belly, Color(hex: 0x501e0a, alpha: 0.35), 3 * S)

        // шея и голова
        b.fillColor(Shape2.rect(cx - 30 * S, hy + 30 * S, 60 * S, 50 * S), Color(hex: 0xb77750))
        var head = b
        head.translateBy(x: cx, y: hy)
        let wobble = ph.k == .dizzy ? sin(t * 6) * 0.12 : 0
        head.rotate(by: .radians(wobble + Double(kick * 0.12 * punchSide)))
        var ears = Shape2.ellipse(P(-50 * S, 4 * S), 10 * S, 15 * S)
        ears.addPath(Shape2.ellipse(P(50 * S, 4 * S), 10 * S, 15 * S))
        head.fillColor(ears, Color(hex: 0xa8673f))
        let face = G([(0, Color(hex: 0xf0b98c)), (0.7, Color(hex: 0xc98559)), (1, Color(hex: 0x8a4f31))])
        head.fill(Shape2.ellipse(.zero, 50 * S, 58 * S), with: radial(face, P(-14 * S, -16 * S), 6 * S, 62 * S))
        head.fillColor(Shape2.rrect(-46 * S, -62 * S, 92 * S, 30 * S, 10 * S), Color(hex: 0x1d1210))
        head.fillColor(Shape2.rect(-50 * S, -36 * S, 100 * S, 9 * S), Color(hex: 0xd6211c))
        if hp < 55 { head.fillColor(Shape2.ellipse(P(-20 * S, -2 * S), 13 * S, 9 * S), Color(hex: 0x6e2878, alpha: 0.45)) }
        var brows = Path()
        brows.move(to: P(-32 * S, -20 * S))
        brows.addLine(to: P(-10 * S, (dazed ? -18 : -12) * S))
        brows.move(to: P(32 * S, -20 * S))
        brows.addLine(to: P(10 * S, (dazed ? -18 : -12) * S))
        head.strokeColor(brows, Color(hex: 0x1d1210), 5 * S)
        if dazed {
            var xs = Path()
            for s in [-1.0, 1.0] {
                let ex = CGFloat(s) * 20 * S
                xs.move(to: P(ex - 6 * S, -6 * S)); xs.addLine(to: P(ex + 6 * S, 6 * S))
                xs.move(to: P(ex + 6 * S, -6 * S)); xs.addLine(to: P(ex - 6 * S, 6 * S))
            }
            head.strokeColor(xs, Color(hex: 0x1d1210), 3.5 * S)
        } else {
            let look: CGFloat = ph.k == .tell && ph.i >= 0 ? plan[ph.i].side * 3 * S : 0
            for s in [-1.0, 1.0] {
                let ex = CGFloat(s) * 20 * S
                head.fillColor(Shape2.ellipse(P(ex, 0), 9 * S, 6 * S), Color(hex: 0xfff6e8))
                head.fillColor(Shape2.circle(P(ex + look, 1 * S), 3.6 * S), Color(hex: 0x1d1210))
            }
        }
        head.fillColor(Shape2.poly([P(0, -2 * S), P(-7 * S, 16 * S), P(7 * S, 16 * S)]), Color(hex: 0xa3603b))
        if kick > 0.2 || dazed {
            head.fillColor(Shape2.ellipse(P(0, 32 * S), 14 * S, 9 * S + kick * 5 * S), Color(hex: 0x2b0f0b))
            head.fillColor(Shape2.rect(-11 * S, 27 * S, 22 * S, 5 * S), Color(hex: 0x3aa0ff))
        } else {
            var mouth = Path()
            mouth.move(to: P(-16 * S, 32 * S))
            mouth.addQuadCurve(to: P(16 * S, 32 * S), control: P(0, 26 * S))
            head.strokeColor(mouth, Color(hex: 0x4a1d12), 4 * S)
        }
        if ph.k == .dizzy {
            for i in 0..<5 {
                let a = t * 5 + Double(i) * TAU / 5
                Lettering.draw(&b, "★", at: P(cx + cosv(a) * 62 * S, hy - 64 * S + sinv(a) * 14 * S), L(.inter, 22 * S, gold))
            }
        }

        // перчатки соперника
        var gloves: [CGFloat: Glove] = [:]
        for s in [CGFloat(-1), CGFloat(1)] {
            var gl = Glove(x: cx + s * 42 * S, y: hy + 46 * S, s: 1, glow: 0)
            if ph.k == .open || dazed {
                gl = Glove(x: cx + s * 100 * S, y: h * 0.67 + sinv(t * 3 + Double(s)) * 6 * S, s: 0.95, glow: 0)
            }
            let telling = ph.k == .tell || (ph.k == .back && !ph.fromSwing)
            if telling && ph.i >= 0 && plan[ph.i].side == s {
                let f = CGFloat(ph.k == .tell ? Ease.out(ph.f) : 1 - ph.f)
                let glow = ph.k == .tell ? 0.5 + 0.5 * sin(now / 40) : 0
                gl = Glove(x: cx + s * (42 + 80 * f) * S, y: hy + (46 - 40 * f) * S, s: 1 - 0.08 * f, glow: glow)
            }
            gloves[s] = gl
        }
        var swing: (p: CGPoint, s: CGFloat, flip: CGFloat)? = nil
        if (ph.k == .swing || (ph.k == .back && ph.fromSwing)) && ph.i >= 0 {
            let s = plan[ph.i].side
            let f = CGFloat(ph.k == .swing ? Ease.inn(ph.f) : 1 - Ease.out(ph.f))
            let a = P(cx + s * 122 * S, hy + 6 * S)
            let z = P(w / 2 - cam * 0.3, h * 0.7)
            swing = (p: P(a.x + (z.x - a.x) * f, a.y + (z.y - a.y) * f), s: 1 + 2.6 * f, flip: -s)
            gloves[s] = nil
        }
        for s in [CGFloat(-1), CGFloat(1)] {
            if let gl = gloves[s] { arm(&b, cx: cx, sh: sh, side: s, to: P(gl.x, gl.y), k: 1) }
        }
        for s in [CGFloat(-1), CGFloat(1)] {
            if let gl = gloves[s] { glove(&b, gl, flip: -s, mine: false) }
        }
        if let sw = swing {
            arm(&g, cx: cx, sh: sh, side: -sw.flip, to: sw.p, k: min(2.2, sw.s * 0.8))
            glove(&g, Glove(x: sw.p.x, y: sw.p.y, s: sw.s, glow: 0), flip: sw.flip, mine: false)
        }
        if ph.k == .open && openShown != ph.i {
            openShown = ph.i
            pops.add("ОТКРЫЛСЯ", cx, hy - 90 * S, L(.inter, 20 * S, gold).squeeze(0.85), life: 0.6, from: 1.3)
        }
    }

    private func myGloves(_ g: inout GraphicsContext) {
        let k = clamp((now - punchT) / 130, 0, 2)
        let p = CGFloat(k < 1 ? Ease.out(k) : 1 - Ease.inn(k - 1))
        for s in [CGFloat(-1), CGFloat(1)] {
            let bx = w / 2 + s * w * 0.3 - cam * 0.25
            let by = h + 4 * S
            let hit = s == punchSide ? p : 0
            let bob = sinv(now / 260 + Double(s)) * 4 * S
            let gx = bx + (w / 2 - bx) * hit * 0.55
            let gy = by - hit * h * 0.36 + bob
            glove(&g, Glove(x: gx, y: gy, s: 1.75 - hit * 0.7, glow: 0), flip: s, mine: true)
        }
    }

    override func draw(_ g: inout GraphicsContext) {
        let ph = live ? phase(ms) : Phase(k: .guardUp)
        var x = world(g)
        // зал
        let hall = G([(0, Color(hex: 0x0d0506)), (0.5, Color(hex: 0x27100f)), (1, Color(hex: 0x130707))])
        x.fill(Shape2.rect(-30, -30, w + 60, h + 60), with: linear(hall, P(0, 0), P(0, h)))
        for p in crowd {
            let a = p.a * (0.7 + 0.3 * sin(now / 500 + p.ph))
            let col = p.warm ? Color(red: 1, green: 214 / 255, blue: 170 / 255) : Color(red: 1, green: 120 / 255, blue: 90 / 255)
            x.fillColor(Shape2.circle(P(p.x + cam * 0.3, p.y), p.r), col.opacity(a))
        }
        if flashBulb > 0 {
            let flash = G([(0, Color.white.opacity(flashBulb)), (1, Color.white.opacity(0))])
            x.fill(Shape2.circle(bulb, 40 * S), with: radial(flash, bulb, 0, 40 * S))
        }
        let spot = G([(0, Color(red: 1, green: 226 / 255, blue: 180 / 255, opacity: 0.28)), (1, Color(red: 1, green: 226 / 255, blue: 180 / 255, opacity: 0))])
        x.fill(Shape2.rect(0, 0, w, h), with: radial(spot, P(w / 2 + cam * 0.5, h * 0.35), 10, h * 0.6))
        // канаты
        let ropes: [(Color, CGFloat)] = [(Color(hex: 0xe8352c), 0.5), (Color(hex: 0xf4ead8), 0.575), (Color(hex: 0x2a4fd6), 0.65)]
        for (col, k) in ropes {
            var rope = Path()
            rope.move(to: P(-20, h * k + 8 * S))
            rope.addQuadCurve(to: P(w + 20, h * k + 8 * S), control: P(w / 2 + cam * 0.6, h * k + 22 * S))
            x.strokeColor(rope, col, 6 * S)
            x.strokeColor(rope, Color.white.opacity(0.25), 1.5 * S)
        }
        x.fillColor(Shape2.rrect(w * 0.06 + cam * 0.6, h * 0.44, 12 * S, h * 0.3, 4), Color(hex: 0x8a8f99))
        boxer(&x, ph)
        myGloves(&g)

        // здоровье соперника
        let bw = w - 40 * S
        let by = 16 * S
        Lettering.draw(&g, BoxGame.names[R], at: P(20 * S, by + 8 * S), L(.inter, 19 * S, Color(hex: 0xf4ead8)).squeeze(0.82).lead())
        g.fillColor(Shape2.rrect(20 * S, by + 22 * S, bw, 12 * S, 6 * S), Color.white.opacity(0.12))
        let bar = G([(0, gold), (1, Color(hex: 0xff3b2f))])
        g.fill(Shape2.rrect(20 * S, by + 22 * S, max(0, bw * CGFloat(hp / 100)), 12 * S, 6 * S), with: linear(bar, P(20 * S, 0), P(20 * S + bw, 0)))
        overlays(&g)
        if flashRed > 0 {
            let red = G([(0, Color.red.opacity(flashRed * 0.12)), (1, Color(red: 0.7, green: 0, blue: 0, opacity: flashRed * 0.7))])
            g.fill(Shape2.rect(0, 0, w, h), with: radial(red, P(w / 2, h / 2), h * 0.2, h * 0.75))
        }
        if ko {
            let k = clamp((now - koAt) / 400, 0, 1)
            let st = L(.boldonse, 54 * S, gold).outline(ink, 10).deep(Color(hex: 0x7c0b10), 6)
            Lettering.draw(&g, "K.O.!", at: P(w / 2, h * 0.42), st, scale: CGFloat(2.4 - 1.4 * Ease.back(k)))
        }
    }
}
