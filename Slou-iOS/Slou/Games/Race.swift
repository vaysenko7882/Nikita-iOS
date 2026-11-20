import SwiftUI
import CoreMotion

/// ГОНКА. Ночное шоссе в стиле ретровейв. Рулишь наклоном телефона или пальцем,
/// обходишь машины и ловишь стрелки ускорителей. Мотор поёт выше с каждой сотней.
final class RaceGame: GameBase {
    private struct Car {
        var z: CGFloat
        var lane: CGFloat
        var v: CGFloat
        var color: Color
    }

    private struct Proj {
        var x: CGFloat
        var y: CGFloat
        var s: CGFloat
        var wd: CGFloat
    }

    private struct Strip {
        var a: Proj
        var b: Proj
        var idx: Int
    }

    private struct Star {
        var x: CGFloat
        var y: CGFloat
        var r: CGFloat
    }

    private let SEG: CGFloat = 200
    private let ROAD: CGFloat = 2000
    private let DRAW = 110
    private let CAMH: CGFloat = 1050
    private let DEPTH: CGFloat = CGFloat(1 / tan(50 * Double.pi / 180))
    private let MAX: CGFloat
    private let horizon: CGFloat
    private let neon = Color(hex: 0x2de2e6)
    private let pink = Color(hex: 0xff2e88)

    private var segs: [CGFloat] = []
    private var boosts: [Int: CGFloat] = [:]
    private var cars: [Car] = []
    private var stars: [Star] = []
    private var LEN: CGFloat = 1

    private var pos: CGFloat = 0
    private var speed: CGFloat = 0
    private var px: CGFloat = 0
    private var target: CGFloat = 0
    private var boostUntil: Double = 0
    private var dist: CGFloat = 0
    private var sky: CGFloat = 0
    private var offT: Double = 0
    private var steer: CGFloat = 0
    private var crashFlash: Double = 0
    private var fingerAt: Double = -99999
    private let motion = CMMotionManager()

    override init(_ c: GameContext) {
        MAX = 200 * 62 * CGFloat([1.0, 1.07, 1.14][min(2, max(0, c.round))])
        horizon = c.h * 0.44
        super.init(c)
        road(10, 40, 10, 0)
        while segs.count < 1300 {
            let len = 25 + Int(c.rnd.next() * 45)
            let straight = c.rnd.next() < 0.28
            let dir: CGFloat = c.rnd.next() < 0.5 ? -1 : 1
            let curve: CGFloat = straight ? 0 : dir * CGFloat(2 + c.rnd.next() * 4.2)
            let edge = max(4, Int(Double(len) * 0.4))
            road(edge, len, edge, curve)
        }
        LEN = CGFloat(segs.count) * SEG
        var s = 70
        while s < segs.count {
            boosts[s] = CGFloat(Int(c.rnd.next() * 3) - 1)
            s += 48 + Int(c.rnd.next() * 40)
        }
        let palette = [neon, Color(hex: 0xffd319), Color(hex: 0xf6f6f6), Color(hex: 0xff901f), Color(hex: 0x9b5de5), Color(hex: 0x4cff7a)]
        let count = [16, 24, 32][R]
        for i in 0..<count {
            let z = (50 + CGFloat(i) * (1100 / CGFloat(count)) + CGFloat(c.rnd.next()) * 25) * SEG
            let lane = CGFloat(Int(c.rnd.next() * 3) - 1)
            let v = MAX * CGFloat(0.3 + c.rnd.next() * 0.25)
            cars.append(Car(z: z, lane: lane, v: v, color: c.rnd.pick(palette)))
        }
        for _ in 0..<60 {
            let x = CGFloat(c.rnd.next())
            let y = CGFloat(c.rnd.next()) * 0.7
            let r = CGFloat(c.rnd.next()) * 1.3 + 0.3
            stars.append(Star(x: x, y: y, r: r))
        }
    }

    deinit { motion.stopDeviceMotionUpdates() }

    private func road(_ enter: Int, _ hold: Int, _ leave: Int, _ curve: CGFloat) {
        let n = enter + hold + leave
        for i in 0..<n {
            var k: Double = 1
            if i < enter { k = Ease.inOut(Double(i) / Double(enter)) }
            else if i >= enter + hold { k = 1 - Ease.inOut(Double(i - enter - hold) / Double(leave)) }
            segs.append(curve * CGFloat(k))
        }
    }

    override func score() -> Int { Int((dist / (MAX * 8.6) * 100).rounded()) }

    override func begin() {
        speed = MAX * 0.35
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates()
        }
        Sound.shared.loop("motor", volume: 0.45)
        buzz("medium")
    }

    override func end() {
        Sound.shared.stopLoop("motor")
        motion.stopDeviceMotionUpdates()
    }

    private func aim(_ p: CGPoint) {
        fingerAt = now
        target = clamp((p.x / w) * 2.5 - 1.25, -1.2, 1.2)
    }

    override func onDown(_ p: CGPoint) { aim(p) }
    override func onMove(_ p: CGPoint, _ prev: CGPoint) { aim(p) }
    override func onUp(_ p: CGPoint) { fingerAt = now }

    private func project(_ xw: CGFloat, _ zr: CGFloat) -> Proj {
        let s = DEPTH / max(1, zr)
        return Proj(x: w / 2 + s * xw * w / 2, y: horizon + s * CAMH * h / 2 * 0.9, s: s, wd: s * ROAD * w / 2)
    }

    override func update() {
        guard live else { return }
        let base = Int(pos / SEG) % segs.count
        let curve = segs[base]
        let boosting = now < boostUntil
        let off = abs(px) > 1
        // наклон телефона, если палец не на экране
        if now - fingerAt > 350, let g = motion.deviceMotion?.gravity {
            target = clamp(CGFloat(g.x) * 2.6, -1.2, 1.2)
        }
        let top = MAX * (boosting ? 1.35 : 1) * (off ? 0.45 : 1)
        let d = CGFloat(dt)
        speed += (top - speed) * d * (speed < top ? 0.9 : 2.4)
        px += (target - px) * min(1, d * 7)
        px -= curve * (speed / MAX) * d * 0.085
        steer += ((target - px) * 2 - steer) * min(1, d * 8)
        pos = (pos + speed * d).truncatingRemainder(dividingBy: LEN)
        dist += speed * d
        sky -= curve * (speed / MAX) * d * 18
        if off && now - offT > 140 {
            offT = now
            buzz("light")
            shake.kick(2.5 * S, 0.15)
        }
        if let lane = boosts[base], abs(px - lane * 0.66) < 0.38, now > boostUntil - 1400 {
            boostUntil = now + 1600
            sfx("boost")
            buzz("medium")
            pops.add("ТУРБО", w / 2, h * 0.62, L(.tektur, 40 * S, neon).outline(Color(hex: 0x1a0533), 6).slant(-0.25).halo(neon))
        }
        for i in cars.indices {
            cars[i].z = (cars[i].z + cars[i].v * d).truncatingRemainder(dividingBy: LEN)
            var dz = cars[i].z - pos
            if dz < -LEN / 2 { dz += LEN }
            if dz > 0 && dz < SEG * 0.9 && abs(cars[i].lane * 0.66 - px) < 0.44 && speed > cars[i].v {
                speed = cars[i].v * 0.55
                cars[i].z = (pos + SEG * 1.4).truncatingRemainder(dividingBy: LEN)
                shake.kick(14 * S, 0.4)
                crashFlash = 1
                sfx("crash")
                buzz("heavy")
                parts.burst(w / 2, h * 0.82, n: 26, colors: [Color(hex: 0xffd319), Color(hex: 0xff901f), .white], speed: 520 * S, gravity: 900, size: 4, life: 0.5)
                pops.add("БАМ!", w / 2, h * 0.66, L(.tektur, 44 * S, .white).outline(Color(hex: 0xff2a4a), 6).slant(-0.25))
            }
        }
        Sound.shared.tune("motor", rate: Float(0.65 + speed / MAX * 0.85), volume: boosting ? 0.6 : 0.45)
        report()
    }

    // MARK: рисование

    private func car(_ g: inout GraphicsContext, _ cx: CGFloat, _ by: CGFloat, _ W: CGFloat, _ color: Color, tilt: CGFloat, player: Bool) {
        let H = W * 0.5
        var c = g
        c.translateBy(x: cx, y: by)
        if tilt != 0 { c.concatenate(CGAffineTransform(a: 1, b: 0, c: tilt * 0.25, d: 1, tx: 0, ty: 0)) }
        if player {
            let glow = G([(0, neon.opacity(0.55)), (1, neon.opacity(0))])
            c.fill(Shape2.rect(-W, -H * 0.2, W * 2, H * 0.5), with: radial(glow, .zero, 4, W * 0.8))
        }
        c.fillColor(Shape2.ellipse(.zero, W * 0.55, H * 0.14), Color.black.opacity(0.45))
        var tyres = Shape2.rrect(-W * 0.46, -H * 0.3, W * 0.18, H * 0.32, 3)
        tyres.addPath(Shape2.rrect(W * 0.28, -H * 0.3, W * 0.18, H * 0.32, 3))
        c.fillColor(tyres, Color(hex: 0x0c0a12))
        let body = Shape2.poly([P(-W * 0.5, -H * 0.12), P(-W * 0.46, -H * 0.62), P(W * 0.46, -H * 0.62), P(W * 0.5, -H * 0.12)])
        c.fillColor(body, color)
        c.fill(body, with: linear(G([(0, color.opacity(0)), (1, Color.black.opacity(0.7))]), P(0, -H), P(0, 0)))
        c.fillColor(Shape2.poly([P(-W * 0.34, -H * 0.62), P(-W * 0.26, -H * 0.98), P(W * 0.26, -H * 0.98), P(W * 0.34, -H * 0.62)]), color)
        c.fillColor(Shape2.poly([P(-W * 0.29, -H * 0.66), P(-W * 0.23, -H * 0.92), P(W * 0.23, -H * 0.92), P(W * 0.29, -H * 0.66)]), Color(hex: 0x120a1f))
        c.fillColor(Shape2.rect(-W * 0.2, -H * 0.9, W * 0.08, H * 0.2), Color.white.opacity(0.25))
        var lights = Shape2.rect(-W * 0.44, -H * 0.5, W * 0.26, H * 0.1)
        lights.addPath(Shape2.rect(W * 0.18, -H * 0.5, W * 0.26, H * 0.1))
        if player {
            var lit = c
            lit.addFilter(.shadow(color: Color(hex: 0xff2a4a), radius: max(1, W * 0.12)))
            lit.fillColor(lights, Color(hex: 0xff2a4a))
        } else {
            var halo = Shape2.rect(-W * 0.48, -H * 0.56, W * 0.34, H * 0.22)
            halo.addPath(Shape2.rect(W * 0.14, -H * 0.56, W * 0.34, H * 0.22))
            c.fillColor(halo, Color(hex: 0xff2a4a, alpha: 0.25))
            c.fillColor(lights, Color(hex: 0xff2a4a))
        }
        var cores = Shape2.rect(-W * 0.41, -H * 0.48, W * 0.16, H * 0.04)
        cores.addPath(Shape2.rect(W * 0.25, -H * 0.48, W * 0.16, H * 0.04))
        c.fillColor(cores, Color(hex: 0xffd7de))
        c.fillColor(Shape2.rrect(-W * 0.1, -H * 0.36, W * 0.2, H * 0.1, 2), Color.black.opacity(0.55))
    }

    private func quad(_ g: inout GraphicsContext, _ ya: CGFloat, _ yb: CGFloat, _ x1: CGFloat, _ w1: CGFloat, _ x2: CGFloat, _ w2: CGFloat, _ col: Color) {
        g.fillColor(Shape2.poly([P(x1 - w1, ya), P(x1 + w1, ya), P(x2 + w2, yb), P(x2 - w2, yb)]), col)
    }

    private func backdrop(_ x: inout GraphicsContext) {
        let skyTop = R == 2 ? Color(hex: 0x05010f) : Color(hex: 0x12032b)
        let skyGrad = G([(0, skyTop), (0.6, Color(hex: 0x3b0a5e)), (1, pink)])
        x.fill(Shape2.rect(-20, -20, w + 40, horizon + 22), with: linear(skyGrad, P(0, 0), P(0, horizon)))
        for s in stars {
            let tw = sin(now / 700 + Double(s.x) * 40)
            let sx = (s.x * w + sky * 0.2).truncatingRemainder(dividingBy: w)
            x.fillColor(Shape2.rect(sx < 0 ? sx + w : sx, s.y * horizon, s.r, s.r), Color.white.opacity(0.3 + 0.5 * tw * tw))
        }
        var clip = x
        clip.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: horizon)))
        let sunR = w * 0.27
        let sunX = w / 2 + (sky * 0.5).truncatingRemainder(dividingBy: w * 2)
        let sunY = horizon - sunR * 0.35
        let sunGrad = G([(0, Color(hex: 0xffe66b)), (0.55, Color(hex: 0xff6a3d)), (1, Color(hex: 0xff1f8e))])
        let aura = G([(0, pink.opacity(0.55)), (0.7, pink.opacity(0.12)), (1, pink.opacity(0))])
        clip.fill(Shape2.circle(P(sunX, sunY), sunR * 1.45), with: radial(aura, P(sunX, sunY), sunR * 0.8, sunR * 1.45))
        clip.fill(Shape2.circle(P(sunX, sunY), sunR), with: linear(sunGrad, P(0, sunY - sunR), P(0, sunY + sunR)))
        var bands = Path()
        for i in 0..<6 {
            let yy = sunY + sunR * (0.1 + CGFloat(i) * 0.16)
            bands.addRect(CGRect(x: sunX - sunR, y: yy, width: sunR * 2, height: 2 + CGFloat(i) * 1.6))
        }
        clip.fillColor(bands, Color(hex: 0x3b0a5e))
        let hills: [(Color, Color, CGFloat, CGFloat)] = [(Color(hex: 0x2a0948), Color(hex: 0xff4fd8), 0.25, 0.16), (Color(hex: 0x170530), Color(hex: 0x9b5de5), 0.5, 0.1)]
        for (col, edge, k, amp) in hills {
            var ridge = Path()
            ridge.move(to: P(-10, horizon))
            for i in 0...24 {
                let X = CGFloat(i) / 24 * (w + 20) - 10
                let ph = Double((X + sky * k) / w) * TAU
                let lift = 0.45 + 0.3 * sin(ph * 2.3) + 0.25 * sin(ph * 5.1 + 1)
                ridge.addLine(to: P(X, horizon - h * amp * CGFloat(lift)))
            }
            ridge.addLine(to: P(w + 10, horizon))
            ridge.closeSubpath()
            clip.fillColor(ridge, col)
            clip.strokeColor(ridge, edge.opacity(0.7), 1.5)
        }
        x.fillColor(Shape2.rect(-20, horizon, w + 40, h - horizon + 20), Color(hex: 0x0b0216))
    }

    override func draw(_ g: inout GraphicsContext) {
        var x = world(g)
        backdrop(&x)
        let base = Int(pos / SEG) % segs.count
        let pct = pos.truncatingRemainder(dividingBy: SEG) / SEG
        var strips: [Strip] = []
        strips.reserveCapacity(DRAW)
        var xa: CGFloat = 0
        var dx: CGFloat = -segs[base] * pct
        for n in 0..<DRAW {
            let idx = (base + n) % segs.count
            let z1 = (CGFloat(n) - pct) * SEG
            let a = project(xa - px * ROAD, max(z1, 1))
            let b = project(xa + dx - px * ROAD, z1 + SEG)
            strips.append(Strip(a: a, b: b, idx: idx))
            xa += dx
            dx += segs[idx]
        }
        for strip in strips.reversed() {
            let a = strip.a, b = strip.b, idx = strip.idx
            if b.y >= a.y { continue }
            let alt = (idx / 3) % 2 == 1
            x.fillColor(Shape2.rect(-20, b.y, w + 40, a.y - b.y + 1), alt ? Color(hex: 0x140428) : Color(hex: 0x0e021d))
            if idx % 6 == 0 { x.fillColor(Shape2.rect(-20, a.y - 1, w + 40, max(1, a.s * 900)), Color(hex: 0xff4fd8, alpha: 0.55)) }
            quad(&x, a.y, b.y, a.x, a.wd * 1.14, b.x, b.wd * 1.14, alt ? pink : Color(hex: 0xf6f0ff))
            quad(&x, a.y, b.y, a.x, a.wd, b.x, b.wd, alt ? Color(hex: 0x1d0b33) : Color(hex: 0x24103d))
            if alt {
                for l in [CGFloat(-1) / 3, CGFloat(1) / 3] {
                    quad(&x, a.y, b.y, a.x + a.wd * l * 2, a.wd * 0.02, b.x + b.wd * l * 2, b.wd * 0.02, neon)
                }
            }
            if let lane = boosts[idx] {
                let c1 = a.x + a.wd * lane * 0.66
                let c2 = b.x + b.wd * lane * 0.66
                quad(&x, a.y, b.y, c1, a.wd * 0.2, c2, b.wd * 0.2, neon.opacity(0.32))
                let arrow = Shape2.poly([P(c1 - a.wd * 0.16, a.y), P(c2, b.y), P(c1 + a.wd * 0.16, a.y), P(c1, a.y - (a.y - b.y) * 0.4)])
                x.fillColor(arrow, neon.opacity(0.9))
            }
        }
        // машины: дальние первыми
        var vis: [(car: Car, X: CGFloat, Y: CGFloat, W: CGFloat, dz: CGFloat)] = []
        for k in cars {
            var dz = k.z - pos
            if dz < 0 { dz += LEN }
            let fz = dz / SEG + pct
            let n = Int(fz)
            if n < 1 || n >= strips.count - 2 { continue }
            let pr = strips[n]
            let f = fz - CGFloat(n)
            let wd = pr.a.wd + (pr.b.wd - pr.a.wd) * f
            let X = pr.a.x + (pr.b.x - pr.a.x) * f + wd * k.lane * 0.66
            let Y = pr.a.y + (pr.b.y - pr.a.y) * f
            vis.append((car: k, X: X, Y: Y, W: wd * 0.62, dz: dz))
        }
        vis.sort { $0.dz > $1.dz }
        for v in vis where v.W > 3 { car(&x, v.X, v.Y, v.W, v.car.color, tilt: 0, player: false) }
        let boosting = now < boostUntil
        if live && (boosting || speed > MAX * 0.95) {
            var lines = Path()
            for _ in 0..<(boosting ? 14 : 6) {
                let a = Double.random(in: 0...TAU)
                let r1 = w * CGFloat(0.25 + Double.random(in: 0...0.2))
                lines.move(to: P(w / 2 + cosv(a) * r1, horizon + 40 + sinv(a) * r1 * 0.6))
                lines.addLine(to: P(w / 2 + cosv(a) * r1 * 1.6, horizon + 40 + sinv(a) * r1))
            }
            x.strokeColor(lines, boosting ? neon.opacity(0.55) : Color.white.opacity(0.18), 2)
        }
        car(&x, w / 2, h - 18 * S, w * 0.38, pink, tilt: steer, player: true)
        overlays(&g)
        if crashFlash > 0 {
            g.fillColor(Shape2.rect(0, 0, w, h), Color.white.opacity(crashFlash * 0.5))
            crashFlash = max(0, crashFlash - dt * 4)
        }
        // спидометр и путь
        let kmh = Int((speed / MAX * 238).rounded())
        let sc = min(100, max(0, score()))
        Lettering.draw(&g, String(kmh), at: P(22 * S, h * 0.1), L(.tektur, 52 * S, .white).lead().slant(-0.22).halo(pink, 16))
        Lettering.draw(&g, "КМ/Ч", at: P(24 * S, h * 0.1 + 34 * S), L(.tektur, 14 * S, neon).lead().slant(-0.22).spaced(2))
        let pw = w * 0.36
        let pxx = w - pw - 20 * S
        g.fillColor(Shape2.rect(pxx, h * 0.1 - 3, pw, 6), Color.white.opacity(0.15))
        var bar = g
        bar.addFilter(.shadow(color: neon, radius: 10))
        bar.fillColor(Shape2.rect(pxx, h * 0.1 - 3, pw * CGFloat(sc) / 100, 6), neon)
        Lettering.draw(&g, "\(sc)%", at: P(w - 20 * S, h * 0.1 + 20 * S), L(.tektur, 18 * S, .white).trail().slant(-0.22))
        if live && now - t0 < 2200 && now - fingerAt > 2000 {
            let k = (now - t0) / 2200
            Lettering.draw(&g, "НАКЛОНЯЙ ТЕЛЕФОН", at: P(w / 2, h * 0.56), L(.tektur, 18 * S, .white).slant(-0.22).spaced(2).fade(1 - k))
        }
    }
}
