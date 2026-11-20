import SwiftUI

/// МИНЁР. Зелёный радар старого терминала. Луч на миг подсвечивает мины —
/// запомни их и веди пальцем к выходу. Цифры на пройденных клетках — сколько мин рядом.
final class MinesGame: GameBase {
    private enum State { case idle, scan, go, dead, won, over }

    private let COLS = 5
    private let ROWS = 8
    private let green = Color(hex: 0x39ff88)
    private let pale = Color(hex: 0xeaffef)
    private let MINES: Int
    private let SHOW: Double
    private let cs: CGFloat
    private let ox: CGFloat
    private let oy: CGFloat
    private var mines = Set<Int>()
    private var seen: [Int: Double] = [:]
    private var visited = Set<Int>()
    private var cur = (x: 2, y: 7)
    private var state = State.idle
    private var best = 7
    private var pts = 0
    private var boom: (p: CGPoint, t: Double)?
    private var held = false
    private var flash: Double = 0

    override init(_ c: GameContext) {
        let r = min(2, max(0, c.round))
        MINES = [9, 12, 15][r]
        SHOW = [2100, 1800, 1500][r]
        let S = c.s
        let size = floor(min((c.w - 40 * S) / 5, (c.h - 120 * S) / 8))
        cs = size
        ox = (c.w - size * 5) / 2
        oy = (c.h - size * 8) / 2 + 18 * S
        super.init(c)
        let start = (x: 2, y: ROWS - 1)
        cur = start
        best = ROWS - 1
        visited = [key(start.x, start.y)]
        for _ in 0..<300 {
            var m = Set<Int>()
            while m.count < MINES {
                let a = c.rnd.int(COLS), b = c.rnd.int(ROWS)
                if abs(a - start.x) + abs(b - start.y) <= 1 || (a == 2 && b == 0) { continue }
                m.insert(key(a, b))
            }
            if reachable(m) { mines = m; break }
        }
    }

    private func key(_ a: Int, _ b: Int) -> Int { b * COLS + a }

    private func reachable(_ m: Set<Int>) -> Bool {
        var seenCells: Set<Int> = [key(2, ROWS - 1)]
        var queue = [(2, ROWS - 1)]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            if p.0 == 2 && p.1 == 0 { return true }
            for dx in -1...1 {
                for dy in -1...1 {
                    let a = p.0 + dx, b = p.1 + dy
                    if a < 0 || b < 0 || a >= COLS || b >= ROWS { continue }
                    let k = key(a, b)
                    if seenCells.contains(k) || m.contains(k) { continue }
                    seenCells.insert(k)
                    queue.append((a, b))
                }
            }
        }
        return false
    }

    private func near(_ a: Int, _ b: Int) -> Int {
        var n = 0
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let x = a + dx, y = b + dy
                if x >= 0 && x < COLS && y >= 0 && y < ROWS && mines.contains(key(x, y)) { n += 1 }
            }
        }
        return n
    }

    private func progress() -> Int { Int((Double(ROWS - 1 - best) / Double(ROWS - 1) * 55).rounded()) }

    override func score() -> Int { (state == .dead || state == .won) ? pts : progress() }

    override func begin() {
        state = .scan
        sfx("blip", 0.6)
    }

    override func end() {
        if state == .go || state == .scan {
            pts = progress()
            state = .over
        }
    }

    private func center(_ a: Int, _ b: Int) -> CGPoint { P(ox + (CGFloat(a) + 0.5) * cs, oy + (CGFloat(b) + 0.5) * cs) }

    private func walk(_ a: Int, _ b: Int) -> Bool {
        cur = (x: a, y: b)
        visited.insert(key(a, b))
        let n = near(a, b)
        sfx("step", 0.7, rate: Float(0.8 + Double(n) * 0.12))
        buzz(n >= 3 ? "rigid" : "light")
        if mines.contains(key(a, b)) {
            state = .dead
            let p = center(a, b)
            boom = (p: p, t: now)
            flash = 1
            sfx("boom")
            buzz("heavy")
            shake.kick(18 * S, 0.6)
            parts.burst(p.x, p.y, n: 50, colors: [green, pale, Color(hex: 0xffde59)], speed: 520 * S, gravity: 0, size: 4, life: 0.9, drag: 0.93)
            pts = progress()
            report()
            finish(pts, 1500)
            return false
        }
        best = min(best, b)
        if a == 2 && b == 0 {
            state = .won
            sfx("victory", 0.8)
            buzz("success")
            let left = clamp(1 - (ms - SHOW) / (13000 - SHOW), 0, 1)
            pts = 55 + Int((45 * left).rounded())
            report()
            finish(pts, 1300)
            pops.add("ВЫХОД ЧИСТ", w / 2, oy - 18 * S, L(.mono, 26 * S, green).halo(green), life: 1.3, rise: 0)
            return false
        }
        report()
        return true
    }

    private func toward(_ p: CGPoint) {
        guard state == .go else { return }
        let a = clamp(Int(floor((p.x - ox) / cs)), 0, COLS - 1)
        let b = clamp(Int(floor((p.y - oy) / cs)), 0, ROWS - 1)
        var guardSteps = 12
        while (cur.x != a || cur.y != b) && guardSteps > 0 {
            guardSteps -= 1
            let nx = cur.x + (a > cur.x ? 1 : a < cur.x ? -1 : 0)
            let ny = cur.y + (b > cur.y ? 1 : b < cur.y ? -1 : 0)
            if !walk(nx, ny) { break }
        }
    }

    override func onDown(_ p: CGPoint) { held = true; toward(p) }
    override func onMove(_ p: CGPoint, _ prev: CGPoint) { if held { toward(p) } }
    override func onUp(_ p: CGPoint) { held = false }

    override func update() {
        if state == .scan && ms > SHOW {
            state = .go
            sfx("whoosh")
            buzz("medium")
        }
        if state == .scan {
            let cx = ox + cs * CGFloat(COLS) / 2, cy = oy + cs * CGFloat(ROWS) / 2
            let sweep = ms / SHOW * TAU
            for k in mines where seen[k] == nil {
                let p = center(k % COLS, k / COLS)
                var ma = atan2(Double(p.y - cy), Double(p.x - cx)) + Double.pi / 2
                ma = (ma.truncatingRemainder(dividingBy: TAU) + TAU).truncatingRemainder(dividingBy: TAU)
                if sweep >= ma {
                    seen[k] = now
                    sfx("ping", 0.5)
                    buzz("soft")
                }
            }
        }
        flash = max(0, flash - dt * 3)
    }

    override func draw(_ g: inout GraphicsContext) {
        let gw = cs * CGFloat(COLS), gh = cs * CGFloat(ROWS)
        var x = world(g)
        x.fillColor(Shape2.rect(-20, -20, w + 40, h + 40), Color(hex: 0x010d06))
        x.fill(Shape2.rect(0, 0, w, h), with: radial(G([(0, green.opacity(0.1)), (1, Color.black.opacity(0))]), P(w / 2, h / 2), 10, h * 0.7))
        var grid = Path()
        for i in 0...COLS { grid.addPath(Shape2.line(P(ox + CGFloat(i) * cs, oy), P(ox + CGFloat(i) * cs, oy + gh))) }
        for j in 0...ROWS { grid.addPath(Shape2.line(P(ox, oy + CGFloat(j) * cs), P(ox + gw, oy + CGFloat(j) * cs))) }
        x.strokeColor(grid, green.opacity(0.22), 1)
        let digits = [green, green, Color(hex: 0xd8ff4f), Color(hex: 0xffb84f), Color(hex: 0xff5f4f), Color(hex: 0xff3b8b)]
        var trodden = Path()
        for k in visited {
            let a = k % COLS, b = k / COLS
            trodden.addRect(CGRect(x: ox + CGFloat(a) * cs + 2, y: oy + CGFloat(b) * cs + 2, width: cs - 4, height: cs - 4))
        }
        x.fillColor(trodden, green.opacity(0.13))
        for k in visited {
            let a = k % COLS, b = k / COLS
            let n = near(a, b)
            if n > 0 && !(a == cur.x && b == cur.y) {
                Lettering.draw(&x, "\(n)", at: center(a, b), L(.mono, cs * 0.38, digits[min(5, n)]).fade(0.85))
            }
        }
        // радар
        let cx = ox + gw / 2, cy = oy + gh / 2
        let rad = hypot(gw, gh) / 2
        if state == .scan {
            let ang = -Double.pi / 2 + ms / SHOW * TAU
            for i in 0..<26 {
                let a = ang - Double(i) * 0.045
                let ray = Shape2.line(P(cx, cy), P(cx + cosv(a) * rad, cy + sinv(a) * rad))
                x.strokeColor(ray, green.opacity((1 - Double(i) / 26) * 0.35), 3)
            }
        }
        for (k, t) in seen {
            let age = (now - t) / 1000
            var al: Double = 0
            if state == .scan { al = max(0.25, 1 - age * 0.55) }
            else if state == .go { al = max(0, 0.25 - (ms - SHOW) / 600) }
            if al <= 0 { continue }
            let p = center(k % COLS, k / COLS)
            var dot = x
            dot.addFilter(.shadow(color: green, radius: 16))
            dot.fillColor(Shape2.circle(p, cs * 0.2), green.opacity(al))
            x.strokeColor(Shape2.circle(p, cs * (0.25 + CGFloat(age) * 0.2)), green.opacity(al * 0.6), 1)
        }
        if state == .dead || state == .won || state == .over {
            for k in mines {
                Lettering.draw(&x, "✹", at: center(k % COLS, k / COLS), L(.mono, cs * 0.45, state == .dead ? Color(hex: 0xff5f4f) : green).fade(0.9))
            }
        }
        // выход и игрок
        Lettering.draw(&x, "ВЫХОД", at: center(2, 0), L(.mono, cs * 0.2, pale).fade(0.6 + 0.4 * sin(now / 200)))
        x.strokeColor(Shape2.rect(ox + 2 * cs + 4, oy + 4, cs - 8, cs - 8), pale, 2, cap: .butt)
        if state != .dead {
            let p = center(cur.x, cur.y)
            var me = x
            me.addFilter(.shadow(color: green, radius: 18))
            me.fillColor(Shape2.rect(p.x - cs * 0.16, p.y - cs * 0.16, cs * 0.32, cs * 0.32), pale)
            var sight = Path()
            sight.addPath(Shape2.line(P(p.x - cs * 0.42, p.y), P(p.x - cs * 0.24, p.y)))
            sight.addPath(Shape2.line(P(p.x + cs * 0.24, p.y), P(p.x + cs * 0.42, p.y)))
            sight.addPath(Shape2.line(P(p.x, p.y - cs * 0.42), P(p.x, p.y - cs * 0.24)))
            sight.addPath(Shape2.line(P(p.x, p.y + cs * 0.24), P(p.x, p.y + cs * 0.42)))
            x.strokeColor(sight, green, 1.5, cap: .butt)
        }
        if let b = boom {
            let k = (now - b.t) / 900
            for i in 0..<3 {
                let r = CGFloat(k - Double(i) * 0.12) * cs * 5
                if r > 0 { x.strokeColor(Shape2.circle(b.p, r), Color(hex: 0xff5f4f).opacity(max(0, 1 - k)), 4) }
            }
        }
        // приборная строка
        let status: String
        switch state {
        case .scan: status = "СКАН \(min(100, Int((ms / SHOW * 100).rounded())))%"
        case .go: status = "ВПЕРЁД"
        case .dead: status = "ПОДРЫВ"
        case .won: status = "ЧИСТО"
        default: status = "ГОТОВ"
        }
        let dim = green.opacity(0.7)
        Lettering.draw(&g, "СЕКТОР \(7 + R)-Г", at: P(ox, oy - 20 * S), L(.mono, 14 * S, dim).lead())
        Lettering.draw(&g, status, at: P(ox + gw, oy - 20 * S), L(.mono, 14 * S, green).trail().fade(state == .scan ? 0.6 + 0.4 * sin(now / 80) : 1))
        Lettering.draw(&g, "МИН: \(MINES)", at: P(ox, oy + gh + 20 * S), L(.mono, 14 * S, dim).lead())
        Lettering.draw(&g, "ОЧКИ: \(min(100, max(0, score())))", at: P(ox + gw, oy + gh + 20 * S), L(.mono, 14 * S, dim).trail())
        overlays(&g)
        if flash > 0 { g.fillColor(Shape2.rect(0, 0, w, h), Color(hex: 0xfff0e6).opacity(flash)) }
        var scan = Path()
        var y: CGFloat = 0
        while y < h { scan.addRect(CGRect(x: 0, y: y, width: w, height: 1)); y += 3 }
        g.fillColor(scan, Color.black.opacity(0.22))
        vignette(&g, .black, 0.3, 0.8, 0.8)
    }
}
