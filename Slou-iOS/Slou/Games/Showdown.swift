import SwiftUI

/// ДУЭЛЬ. Закат, два силуэта, стук сердца. Жди «DRAW!» и стреляй первым.
/// Раньше времени — фальстарт и ноль. Ворона и сверчки нарочно пугают.
final class ShowdownGame: GameBase {
    private enum State { case idle, wait, fire, done, foul }
    private struct Dust { var x: CGFloat; var y: CGFloat; var v: CGFloat; var r: CGFloat }

    private let sand = Color(hex: 0xf3dfb4)
    private let dark = Color(hex: 0x2a0e04)
    private let soot = Color(hex: 0x1a0c05)
    private var D: Double = 2000
    private var fakes: [Double] = []
    private var dust: [Dust] = []
    private var state = State.idle
    private var tf: Double = 0
    private var rt: Double = 0
    private var pts = 0
    private var flash: Double = 0
    private var crowAt: Double = -99999
    private var crowFor: Double = -1
    private var weedX: CGFloat = -60
    private var weedV: CGFloat = 60
    private var myDraw: Double = 0
    private var theyFall: Double = 0
    private var iFall: Double = 0
    private var heart: Double = 0
    private let ground: CGFloat

    override init(_ c: GameContext) {
        ground = c.h * 0.72
        super.init(c)
        D = 1600 + c.rnd.next() * 2500
        for _ in 0..<R { fakes.append(700 + c.rnd.next() * (D - 1100)) }
        for _ in 0..<40 {
            let x = CGFloat(c.rnd.next()) * w
            let y = h * CGFloat(0.62 + c.rnd.next() * 0.3)
            let v = CGFloat(8 + c.rnd.next() * 30)
            let r = CGFloat(1 + c.rnd.next() * 2)
            dust.append(Dust(x: x, y: y, v: v, r: r))
        }
        weedV = CGFloat(60 + c.rnd.next() * 40)
    }

    override func score() -> Int { pts }

    override func begin() { state = .wait }

    override func end() {
        if state == .fire {
            pts = 0
            state = .done
            rt = now - tf
        }
    }

    override func onDown(_ p: CGPoint) { shoot() }

    private func shoot() {
        if state == .wait {
            state = .foul
            iFall = now
            flash = 0.6
            sfx("bang")
            sfx("buzz")
            buzz("error")
            shake.kick(8 * S, 0.3)
            pops.add("ФАЛЬСТАРТ", w / 2, h * 0.36, L(.serif, 40 * S, dark).outline(sand, 6), life: 1.4, rise: 0)
            c.report(0)
            finish(0, 1500)
        } else if state == .fire {
            rt = (now - tf).rounded()
            state = .done
            myDraw = now
            pts = min(100, max(0, Int((100 - (rt - 150) / 3.5).rounded())))
            sfx("bang")
            buzz("heavy")
            flash = 1
            shake.kick(10 * S, 0.3)
            if pts > 0 { theyFall = now + 120 }
            parts.burst(w * 0.3, ground - 96 * S, n: 16, colors: [Color(hex: 0xfff3c4), Color(hex: 0xffb347), Color(hex: 0xff6a2e)], speed: 380 * S, angle: 0, spread: 0.8, gravity: 0, life: 0.35)
            report()
            finish(pts, 1500)
        }
    }

    override func update() {
        weedX += weedV * CGFloat(dt)
        if weedX > w + 60 { weedX = -60 }
        for i in dust.indices {
            dust[i].x += dust[i].v * CGFloat(dt)
            if dust[i].x > w { dust[i].x = 0 }
        }
        if state == .wait {
            for f in fakes where ms > f && ms < f + 900 && crowFor != f {
                crowFor = f
                crowAt = now
                sfx("caw")
                buzz("light")
            }
            if ms > D {
                state = .fire
                tf = now
                sfx("bell")
                buzz("rigid")
            } else if now - heart > 520 {
                heart = now
                sfx("heart", 0.8)
                buzz("soft")
            }
        }
        flash = max(0, flash - dt * 5)
    }

    private func cowboy(_ g: inout GraphicsContext, _ X: CGFloat, _ Y: CGFloat, _ s: CGFloat, face: CGFloat, drawK: CGFloat, fallK: CGFloat) {
        var c = g
        c.translateBy(x: X, y: Y)
        if fallK > 0 {
            c.rotate(by: .radians(Double(face * -fallK * 1.45)))
            c.translateBy(x: 0, y: fallK * 6 * s)
        }
        c.scaleBy(x: face * s, y: s)
        var body = Shape2.poly([P(-9, 0), P(-6, -46), P(6, -46), P(10, 0), P(4, 0), P(0, -30), P(-3, 0)])
        body.addPath(Shape2.poly([P(-14, -44), P(-11, -96), P(13, -96), P(17, -44)]))
        var coat = Path()
        coat.move(to: P(-18, -92))
        coat.addQuadCurve(to: P(22, -86), control: P(0, -60))
        coat.addLine(to: P(14, -100))
        coat.addLine(to: P(-12, -100))
        coat.closeSubpath()
        body.addPath(coat)
        body.addPath(Shape2.circle(P(0, -108), 9))
        body.addPath(Shape2.ellipse(P(0, -116), 24, 4))
        var crown = Path()
        crown.move(to: P(-10, -116))
        crown.addQuadCurve(to: P(0, -130), control: P(-9, -132))
        crown.addQuadCurve(to: P(10, -116), control: P(9, -132))
        crown.closeSubpath()
        body.addPath(crown)
        c.fillColor(body, soot)
        let a = -1.35 + Double(drawK) * 1.25
        var arm = c
        arm.translateBy(x: 8, y: -92)
        arm.rotate(by: .radians(-a - 1.6))
        arm.strokeColor(Shape2.line(.zero, P(0, 36)), soot, 7)
        if drawK > 0 {
            var gun = Shape2.rect(-3, 34, 7, 18)
            gun.addPath(Shape2.rect(-3, 48, 12, 5))
            arm.fillColor(gun, soot)
        }
    }

    override func draw(_ g: inout GraphicsContext) {
        var x = world(g)
        let skyGrad = G([(0, Color(hex: 0x2a1006)), (0.45, Color(hex: 0x8f2f12)), (0.8, Color(hex: 0xe0782a)), (1, Color(hex: 0xf6b04a))])
        x.fill(Shape2.rect(-20, -20, w + 40, ground + 20), with: linear(skyGrad, P(0, 0), P(0, ground)))
        let sunC = P(w * 0.5, ground - 40 * S)
        let sun = G([(0, Color(hex: 0xfff1c2)), (0.45, Color(hex: 0xffcf6a)), (1, Color(hex: 0xffa03c, alpha: 0))])
        x.fill(Shape2.circle(sunC, 130 * S), with: radial(sun, sunC, 10, 130 * S))
        let mesa = Shape2.poly([P(-10, ground), P(-10, ground - 60 * S), P(w * 0.1, ground - 64 * S), P(w * 0.14, ground - 120 * S), P(w * 0.3, ground - 122 * S),
                                P(w * 0.33, ground - 70 * S), P(w * 0.62, ground - 66 * S), P(w * 0.66, ground - 104 * S), P(w * 0.86, ground - 106 * S),
                                P(w * 0.9, ground - 58 * S), P(w + 10, ground - 52 * S), P(w + 10, ground)])
        x.fillColor(mesa, Color(hex: 0x5a2410))
        let earth = G([(0, Color(hex: 0x7a3a16)), (1, Color(hex: 0x2a1207))])
        x.fill(Shape2.rect(-20, ground, w + 40, h - ground + 20), with: linear(earth, P(0, ground), P(0, h)))
        // кактус
        let kx = w * 0.52, ky = ground + 4 * S
        var cactus = Shape2.rrect(kx - 6 * S, ky - 70 * S, 12 * S, 70 * S, 6 * S)
        cactus.addPath(Shape2.rrect(kx - 22 * S, ky - 52 * S, 8 * S, 26 * S, 4 * S))
        cactus.addPath(Shape2.rrect(kx - 22 * S, ky - 30 * S, 22 * S, 7 * S, 3 * S))
        cactus.addPath(Shape2.rrect(kx + 14 * S, ky - 60 * S, 8 * S, 24 * S, 4 * S))
        cactus.addPath(Shape2.rrect(kx, ky - 40 * S, 22 * S, 7 * S, 3 * S))
        x.fillColor(cactus, Color(hex: 0x2a1207))
        // перекати-поле
        var weed = x
        weed.translateBy(x: weedX, y: ground + 30 * S - abs(sinv(now / 180)) * 10 * S)
        weed.rotate(by: .radians(now / 160))
        var twigs = Path()
        for i in 0..<9 { twigs.addPath(Shape2.arc(.zero, 14 * S, Double(i), Double(i) + 2.6)) }
        weed.strokeColor(twigs, Color(hex: 0x3b1d0b), 1.5)
        var specks = Path()
        for d in dust { specks.addRect(CGRect(x: d.x, y: d.y, width: d.r, height: d.r)) }
        x.fillColor(specks, Color(hex: 0xffd696, alpha: 0.25))
        // ковбои
        let dk = myDraw > 0 ? CGFloat(clamp((now - myDraw) / 90, 0, 1)) : 0
        let fallT = theyFall > 0 && now > theyFall ? clamp((now - theyFall) / 700, 0, 1) : 0
        let meF = state == .foul ? CGFloat(clamp((now - iFall - 250) / 700, 0, 1)) : 0
        cowboy(&x, w * 0.24, ground + 30 * S, 1.25 * S, face: 1, drawK: dk, fallK: meF)
        var theirDraw: CGFloat = 0
        if state == .foul { theirDraw = CGFloat(clamp((now - iFall) / 90, 0, 1)) }
        else if state == .done && pts == 0 { theirDraw = 1 }
        cowboy(&x, w * 0.78, ground + 12 * S, 1.05 * S, face: -1, drawK: theirDraw, fallK: CGFloat(Ease.out(fallT)))
        // ворона
        if now - crowAt < 1100 {
            let k = CGFloat((now - crowAt) / 1100)
            let cx = kx + k * w * 0.7
            let cy = ky - 70 * S - k * h * 0.5
            let fl = sinv(now / 40) * 8 * S
            var bird = Path()
            bird.move(to: P(cx - 16 * S, cy + fl))
            bird.addQuadCurve(to: P(cx, cy), control: P(cx - 6 * S, cy - 6 * S))
            bird.addQuadCurve(to: P(cx + 16 * S, cy + fl), control: P(cx + 6 * S, cy - 6 * S))
            x.strokeColor(bird, Color(hex: 0x120804), 4 * S)
        }
        // надписи
        if state == .wait {
            Lettering.draw(&g, "ЖДИ…", at: P(w / 2, h * 0.28), L(.serif, 34 * S, sand).spaced(6).fade(0.65 + 0.35 * sin(now / 160)))
        }
        if state == .fire || (state == .done && now - myDraw < 900) {
            let k = clamp((now - tf) / 160, 0, 1)
            let st = L(.erica, 78 * S, Color(hex: 0xffe9b0)).outline(dark, 10).deep(Color(hex: 0x8f2f12), 6)
            Lettering.draw(&g, "DRAW!", at: P(w / 2, h * 0.3), st, scale: CGFloat(2 - Ease.back(k)))
        }
        if state == .done {
            let secs = String(format: "%.3f с", rt / 1000)
            Lettering.draw(&g, secs, at: P(w / 2, h * 0.46), L(.serif, 44 * S, pts > 0 ? Color(hex: 0xfff3c4) : sand).outline(dark, 6))
            let verdict = pts > 70 ? "САМЫЙ БЫСТРЫЙ НА ДИКОМ ЗАПАДЕ" : pts > 30 ? "НЕПЛОХО, ПАРТНЁР" : "МЕДЛЕННО, КАК ЧЕРЕПАХА"
            Lettering.draw(&g, verdict, at: P(w / 2, h * 0.54), L(.serif, 15 * S, sand).spaced(2))
        }
        overlays(&g)
        if flash > 0 { g.fillColor(Shape2.rect(0, 0, w, h), Color(hex: 0xfff4d6).opacity(flash)) }
        // кино: зерно, виньетка, чёрные полосы
        Grain.draw(&g, CGRect(x: 0, y: 0, width: w, height: h), alpha: 0.2, opacity: 0.55)
        vignette(&g, Color(hex: 0x140600), 0.25, 0.75, 0.75)
        g.fillColor(Shape2.rect(0, 0, w, h * 0.07), .black)
        g.fillColor(Shape2.rect(0, h * 0.93, w, h * 0.07), .black)
    }
}
