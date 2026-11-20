import SwiftUI
import UIKit
import QuartzCore

// MARK: - Время

/// Монотонное время в секундах
@inline(__always) func gameNow() -> Double { CACurrentMediaTime() }

// MARK: - Шрифты игр (лежат в приложении, у каждой игры свой)

enum GFont: String {
    case inter = "InterDisplay-Black"
    case shoulders = "BigShoulders-Bold"
    case tektur = "Tektur-Medium"
    case serif = "DejaVuSerifCondensed-Bold"
    case erica = "EricaOne-Regular"
    case plex = "IBMPlexSerif-BoldItalic"
    case mono = "JetBrainsMono-Bold"
    case arsenal = "ArsenalSC-Regular"
    case pixel = "PixelifySans-Medium"
    case silk = "Silkscreen-Regular"
    case poiret = "PoiretOne-Regular"
    case jura = "Jura-Medium"
    case boldonse = "Boldonse-Regular"
    case kanji = "HiraMinProN-W6"   // хирагино минтё — есть в каждом айфоне

    func font(_ size: CGFloat) -> Font { .custom(rawValue, fixedSize: size) }
    func ui(_ size: CGFloat) -> UIFont { UIFont(name: rawValue, size: size) ?? .systemFont(ofSize: size, weight: .black) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Случайность с зерном: у обоих игроков одинаковые мины, фрукты и ноты

struct SeededRandom {
    private var a: UInt32
    init(seed: UInt32) { a = seed }

    mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t: UInt32 = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + next() * (hi - lo) }
    mutating func int(_ n: Int) -> Int { max(0, min(n - 1, Int(next() * Double(n)))) }
    mutating func chance(_ p: Double) -> Bool { next() < p }
    mutating func pick<T>(_ list: [T]) -> T { list[int(list.count)] }

    static func mix(_ values: [Int]) -> UInt32 {
        var h: UInt32 = 2166136261
        for v in values { h = (h ^ UInt32(truncatingIfNeeded: v)) &* 2654435761 }
        return h
    }
}

// MARK: - Плавность

enum Ease {
    static func out(_ t: Double) -> Double { let u = 1 - t; return 1 - u * u * u }
    static func inn(_ t: Double) -> Double { t * t * t }
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func back(_ t: Double) -> Double {
        let c = 1.9, u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
}

@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(hi, max(lo, v)) }
@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// MARK: - Фигуры

enum Shape2 {
    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
    static func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0) -> Path {
        let p = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation)
        return p.applying(t)
    }
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(CGRect(x: x, y: y, width: w, height: h)) }
    static func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: max(0, w), height: max(0, h)), cornerRadius: min(r, max(0, min(w, h) / 2)))
    }
    static func poly(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        p.closeSubpath()
        return p
    }
    static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        return p
    }
    /// Дуга эллипса: углы растут по часовой стрелке на экране, как в canvas
    static func ellipseArc(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: .zero, radius: 1, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        let t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: rx, y: ry)
        return p.applying(t)
    }
    static func arc(_ c: CGPoint, _ r: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        return p
    }
    static func star(_ c: CGPoint, _ r: CGFloat, inner: CGFloat = 0.45) -> Path {
        var pts: [CGPoint] = []
        for i in 0..<10 {
            let a = -Double.pi / 2 + Double(i) * Double.pi / 5
            let rr = i % 2 == 0 ? r : r * inner
            pts.append(CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr))
        }
        return poly(pts)
    }
}

extension GraphicsContext {
    mutating func fillColor(_ path: Path, _ color: Color) { fill(path, with: .color(color)) }
    mutating func strokeColor(_ path: Path, _ color: Color, _ width: CGFloat, cap: CGLineCap = .round) {
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round))
    }
}

/// Градиент с точками остановки: G([(0, a), (0.5, b), (1, c)])
func G(_ stops: [(CGFloat, Color)]) -> Gradient {
    Gradient(stops: stops.map { Gradient.Stop(color: $0.1, location: $0.0) })
}

func linear(_ g: Gradient, _ a: CGPoint, _ b: CGPoint) -> GraphicsContext.Shading {
    .linearGradient(g, startPoint: a, endPoint: b)
}

func radial(_ g: Gradient, _ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat) -> GraphicsContext.Shading {
    .radialGradient(g, center: c, startRadius: r0, endRadius: r1)
}

@inline(__always) func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
@inline(__always) func sinv(_ v: Double) -> CGFloat { CGFloat(sin(v)) }
@inline(__always) func cosv(_ v: Double) -> CGFloat { CGFloat(cos(v)) }
let TAU = Double.pi * 2

// MARK: - Надписи: обводка, выдавливание, свечение, сжатие и наклон

struct LabelStyle {
    var font: GFont = .inter
    var size: CGFloat = 20
    var color: Color = .white
    var stroke: Color? = nil
    var strokeWidth: CGFloat = 0
    var extrude: Color? = nil
    var depth: Int = 0
    var glow: Color? = nil
    var glowRadius: CGFloat = 14
    var scaleX: CGFloat = 1
    var skew: CGFloat = 0
    var rotation: Double = 0
    var anchor: UnitPoint = .center
    var opacity: Double = 1
    var tracking: CGFloat = 0
    /// Не шире стольких точек: длинные слова сами ужимаются
    var maxWidth: CGFloat = 0
}

/// Короткая запись стиля: L(.inter, 34 * S, .white).outline(ink, 6).squeeze(0.8)
func L(_ font: GFont, _ size: CGFloat, _ color: Color) -> LabelStyle {
    var s = LabelStyle()
    s.font = font
    s.size = size
    s.color = color
    return s
}

extension LabelStyle {
    func outline(_ c: Color, _ w: CGFloat) -> LabelStyle { var s = self; s.stroke = c; s.strokeWidth = w; return s }
    func deep(_ c: Color, _ d: Int) -> LabelStyle { var s = self; s.extrude = c; s.depth = d; return s }
    func halo(_ c: Color, _ r: CGFloat = 14) -> LabelStyle { var s = self; s.glow = c; s.glowRadius = r; return s }
    func squeeze(_ v: CGFloat) -> LabelStyle { var s = self; s.scaleX = v; return s }
    func slant(_ v: CGFloat) -> LabelStyle { var s = self; s.skew = v; return s }
    func turn(_ v: Double) -> LabelStyle { var s = self; s.rotation = v; return s }
    func lead() -> LabelStyle { var s = self; s.anchor = .leading; return s }
    func trail() -> LabelStyle { var s = self; s.anchor = .trailing; return s }
    func fade(_ v: Double) -> LabelStyle { var s = self; s.opacity = v; return s }
    func spaced(_ v: CGFloat) -> LabelStyle { var s = self; s.tracking = v; return s }
    func fit(_ v: CGFloat) -> LabelStyle { var s = self; s.maxWidth = v; return s }
}

enum Lettering {
    static func draw(_ g: inout GraphicsContext, _ s: String, at p: CGPoint, _ st: LabelStyle, scale: CGFloat = 1) {
        var c = g
        c.opacity = g.opacity * st.opacity
        c.translateBy(x: p.x, y: p.y)
        if st.rotation != 0 { c.rotate(by: .radians(st.rotation)) }
        if st.skew != 0 { c.concatenate(CGAffineTransform(a: 1, b: 0, c: st.skew, d: 1, tx: 0, ty: 0)) }
        var base = Text(s).font(st.font.font(st.size))
        if st.tracking != 0 { base = base.tracking(st.tracking) }
        var shrink: CGFloat = 1
        if st.maxWidth > 0 {
            let size = c.resolve(base).measure(in: CGSize(width: 100_000, height: 100_000))
            let wide = size.width * st.scaleX
            if wide > st.maxWidth { shrink = st.maxWidth / wide }
        }
        c.scaleBy(x: st.scaleX * scale * shrink, y: scale * shrink)
        if let ex = st.extrude, st.depth > 0 {
            let r = c.resolve(base.foregroundColor(ex))
            for i in stride(from: st.depth, to: 0, by: -1) {
                c.draw(r, at: CGPoint(x: CGFloat(i) * 0.8, y: CGFloat(i)), anchor: st.anchor)
            }
        }
        if let sc = st.stroke, st.strokeWidth > 0 {
            let r = c.resolve(base.foregroundColor(sc))
            let w = st.strokeWidth / 2
            let n = st.strokeWidth > 6 ? 16 : 10
            for k in 0..<n {
                let a = Double(k) / Double(n) * 2 * Double.pi
                c.draw(r, at: CGPoint(x: CGFloat(cos(a)) * w, y: CGFloat(sin(a)) * w), anchor: st.anchor)
            }
        }
        if let glow = st.glow {
            var gc = c
            gc.addFilter(.shadow(color: glow, radius: st.glowRadius))
            gc.draw(base.foregroundColor(st.color), at: .zero, anchor: st.anchor)
        } else {
            c.draw(c.resolve(base.foregroundColor(st.color)), at: .zero, anchor: st.anchor)
        }
    }
}

// MARK: - Частицы

struct Particle {
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
    var gravity: CGFloat, life: Double, decay: Double, size: CGFloat
    var color: Color, round: Bool, drag: CGFloat, rot: Double, spin: Double
}

final class Particles {
    private(set) var list: [Particle] = []

    func burst(_ x: CGFloat, _ y: CGFloat, n: Int = 12, colors: [Color] = [.white], speed: CGFloat = 240, angle: Double? = nil,
               spread: Double = Double.pi * 2, gravity: CGFloat = 600, size: CGFloat = 4, life: Double = 0.7, round: Bool = false, drag: CGFloat = 0.985) {
        for i in 0..<n {
            let a: Double = angle.map { $0 + (Double.random(in: 0...1) - 0.5) * spread } ?? Double.random(in: 0...(Double.pi * 2))
            let v = speed * CGFloat(0.35 + Double.random(in: 0...0.75))
            let p = Particle(x: x, y: y, vx: CGFloat(cos(a)) * v, vy: CGFloat(sin(a)) * v, gravity: gravity, life: 1,
                             decay: 1 / (life * (0.6 + Double.random(in: 0...0.7))), size: size * CGFloat(0.5 + Double.random(in: 0...1)),
                             color: colors[i % max(1, colors.count)], round: round, drag: drag, rot: Double.random(in: 0...6), spin: Double.random(in: -6...6))
            list.append(p)
        }
        if list.count > 700 { list.removeFirst(list.count - 700) }
    }

    func step(_ dt: Double) {
        let d = CGFloat(dt)
        for i in list.indices {
            list[i].vx *= list[i].drag
            list[i].vy = list[i].vy * list[i].drag + list[i].gravity * d
            list[i].x += list[i].vx * d
            list[i].y += list[i].vy * d
            list[i].life -= list[i].decay * dt
            list[i].rot += list[i].spin * dt
        }
        list.removeAll { $0.life <= 0 }
    }

    func draw(_ g: inout GraphicsContext) {
        for p in list {
            var c = g
            c.opacity = min(1, max(0, p.life * 1.4))
            if p.round {
                c.fill(Shape2.circle(CGPoint(x: p.x, y: p.y), p.size), with: .color(p.color))
            } else {
                c.translateBy(x: p.x, y: p.y)
                c.rotate(by: .radians(p.rot))
                c.fill(Shape2.rect(-p.size / 2, -p.size / 2, p.size, p.size * 0.7), with: .color(p.color))
            }
        }
    }
}

// MARK: - Всплывающие надписи

final class Pops {
    private struct Pop { var text: String; var x: CGFloat; var y: CGFloat; var t: Double; var life: Double; var style: LabelStyle; var from: CGFloat; var rise: CGFloat }
    private var list: [Pop] = []

    func add(_ text: String, _ x: CGFloat, _ y: CGFloat, _ style: LabelStyle, life: Double = 0.9, from: CGFloat = 1.8, rise: CGFloat = 30) {
        list.append(Pop(text: text, x: x, y: y, t: 0, life: life, style: style, from: from, rise: rise))
    }

    func draw(_ g: inout GraphicsContext, _ dt: Double) {
        for i in list.indices {
            list[i].t += dt
            let p = list[i]
            let k = p.t / p.life
            let inK = min(1, p.t / 0.14)
            let sc = p.from + (1 - p.from) * CGFloat(Ease.back(inK))
            var st = p.style
            st.opacity = st.opacity * (k > 0.7 ? max(0, (1 - k) / 0.3) : 1)
            let y = p.y - p.rise * CGFloat(Ease.out(min(1, k)))
            Lettering.draw(&g, p.text, at: CGPoint(x: p.x, y: y), st, scale: sc)
        }
        list.removeAll { $0.t >= $0.life }
    }
}

// MARK: - Тряска

final class Shake {
    private var t = 0.0, mag: CGFloat = 0, dur = 1.0
    func kick(_ m: CGFloat, _ d: Double = 0.35) {
        let reduce = UIAccessibility.isReduceMotionEnabled
        let mm = reduce ? m * 0.3 : m
        if mm >= mag * CGFloat(t / dur) { mag = mm; t = d; dur = d }
    }
    func offset(_ dt: Double) -> CGSize {
        guard t > 0 else { return .zero }
        t = max(0, t - dt)
        let m = mag * CGFloat(t / dur)
        return CGSize(width: CGFloat.random(in: -1...1) * m, height: CGFloat.random(in: -1...1) * m)
    }
}

// MARK: - Зерно плёнки

enum Grain {
    private static var cache: [String: Image] = [:]
    static func image(alpha: Double, mono: Bool = true) -> Image {
        let key = "\(alpha)-\(mono)"
        if let img = cache[key] { return img }
        let w = 256, h = 256
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = UInt8.random(in: 0...255)
            let a = UInt8(Double(UInt8.random(in: 0...255)) * alpha)
            // премультиплицированный альфа-канал
            let pv = UInt8(Int(v) * Int(a) / 255)
            bytes[i * 4] = pv
            bytes[i * 4 + 1] = mono ? pv : UInt8(Int(UInt8.random(in: 0...255)) * Int(a) / 255)
            bytes[i * 4 + 2] = mono ? pv : UInt8(Int(UInt8.random(in: 0...255)) * Int(a) / 255)
            bytes[i * 4 + 3] = a
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        var image = Image(systemName: "circle")
        bytes.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info.rawValue),
               let cg = ctx.makeImage() {
                image = Image(decorative: cg, scale: 1)
            }
        }
        cache[key] = image
        return image
    }

    /// Плиткой на весь прямоугольник
    static func draw(_ g: inout GraphicsContext, _ rect: CGRect, alpha: Double, opacity: Double = 1) {
        let img = g.resolve(image(alpha: alpha))
        var c = g
        c.opacity = g.opacity * opacity
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                c.draw(img, in: CGRect(x: x, y: y, width: 256, height: 256))
                x += 256
            }
            y += 256
        }
    }
}

// MARK: - Касания: мультитач без задержек, с промежуточными точками (для взмахов)

struct TouchEvent {
    enum Phase { case began, moved, ended, cancelled }
    let phase: Phase
    let id: Int
    let point: CGPoint
    let time: Double
}

final class TouchView: UIView {
    var handler: ((TouchEvent) -> Void)?
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { nil }

    private func send(_ touches: Set<UITouch>, _ event: UIEvent?, _ phase: TouchEvent.Phase) {
        for t in touches {
            let key = ObjectIdentifier(t)
            if phase == .began { ids[key] = nextID; nextID += 1 }
            let id = ids[key] ?? 0
            if phase == .moved, let all = event?.coalescedTouches(for: t), !all.isEmpty {
                for c in all { handler?(TouchEvent(phase: .moved, id: id, point: c.location(in: self), time: c.timestamp)) }
            } else {
                handler?(TouchEvent(phase: phase, id: id, point: t.location(in: self), time: t.timestamp))
            }
            if phase == .ended || phase == .cancelled { ids[key] = nil }
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, event, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, event, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, event, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, event, .cancelled) }
}

struct TouchSurface: UIViewRepresentable {
    let handler: (TouchEvent) -> Void
    func makeUIView(context: Context) -> TouchView {
        let v = TouchView(frame: .zero)
        v.handler = handler
        return v
    }
    func updateUIView(_ uiView: TouchView, context: Context) { uiView.handler = handler }
}

/// Распознаёт касание и свайп по сырым событиям
final class Gestures {
    struct Swipe {
        let dx: CGFloat, dy: CGFloat, vx: CGFloat, vy: CGFloat
        let start: CGPoint, end: CGPoint
        let path: [CGPoint]
    }
    var onDown: ((CGPoint) -> Void)?
    var onMove: ((CGPoint, CGPoint) -> Void)?   // текущая и предыдущая точка
    var onUp: ((CGPoint) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: ((Swipe) -> Void)?

    private struct Track { var start: CGPoint; var t0: Double; var last: CGPoint; var path: [(CGPoint, Double)]; var moved: Bool }
    private var tracks: [Int: Track] = [:]

    func handle(_ e: TouchEvent) {
        switch e.phase {
        case .began:
            tracks[e.id] = Track(start: e.point, t0: e.time, last: e.point, path: [(e.point, e.time)], moved: false)
            onDown?(e.point)
        case .moved:
            guard var tr = tracks[e.id] else { return }
            let prev = tr.last
            tr.path.append((e.point, e.time))
            if tr.path.count > 48 { tr.path.removeFirst() }
            if hypot(e.point.x - tr.start.x, e.point.y - tr.start.y) > 12 { tr.moved = true }
            tr.last = e.point
            tracks[e.id] = tr
            onMove?(e.point, prev)
        case .ended, .cancelled:
            guard let tr = tracks[e.id] else { return }
            tracks[e.id] = nil
            if e.phase == .ended {
                let dt = e.time - tr.t0
                let dx = e.point.x - tr.start.x, dy = e.point.y - tr.start.y
                if !tr.moved && dt < 0.35 {
                    onTap?(e.point)
                } else if hypot(dx, dy) > 30 {
                    let back = tr.path.first { e.time - $0.1 < 0.09 } ?? (tr.start, tr.t0)
                    let bt = max(0.016, e.time - back.1)
                    let vx = (e.point.x - back.0.x) / CGFloat(bt)
                    let vy = (e.point.y - back.0.y) / CGFloat(bt)
                    onSwipe?(Swipe(dx: dx, dy: dy, vx: vx, vy: vy, start: tr.start, end: e.point, path: tr.path.map { $0.0 }))
                }
            }
            onUp?(e.point)
        }
    }
}

// MARK: - Игра и её окружение

/// Что игра получает от арены
final class GameContext {
    let round: Int
    let size: CGSize
    let s: CGFloat            // масштаб от макета 390×560
    var rnd: SeededRandom
    var report: (Int) -> Void = { _ in }
    var opponent: () -> Int? = { nil }
    private(set) var finished: (pts: Int, at: Double)?

    init(round: Int, size: CGSize, seed: UInt32) {
        self.round = round
        self.size = size
        self.s = min(size.width / 390, size.height / 560)
        self.rnd = SeededRandom(seed: seed)
    }

    var w: CGFloat { size.width }
    var h: CGFloat { size.height }

    /// Закончить раунд раньше времени (через паузу, чтобы показать итог)
    func finish(_ pts: Int, after: Double = 0.6) {
        if finished == nil { finished = (pts: pts, at: gameNow() + after) }
    }
}

protocol ArcadeGame: AnyObject {
    func start()
    func step(_ dt: Double)
    func draw(_ g: inout GraphicsContext)
    func touch(_ e: TouchEvent)
    func stop() -> Int
}

/// Крутит кадры игры: шаг физики и отрисовка на каждый кадр экрана (до 120 в секунду)
final class GameHost {
    let info: GameInfo
    let ctx: GameContext
    let game: ArcadeGame
    private var last = 0.0
    private(set) var running = false

    init(info: GameInfo, ctx: GameContext) {
        self.info = info
        self.ctx = ctx
        self.game = info.make(ctx)
    }

    func start() { running = true; last = gameNow(); game.start() }
    func halt() { running = false }

    func frame(_ g: inout GraphicsContext) {
        let t = gameNow()
        let dt = last == 0 ? 0 : min(0.05, t - last)
        last = t
        game.step(dt)
        game.draw(&g)
    }
}

struct GameStageView: View {
    let host: GameHost
    var body: some View {
        TimelineView(.animation) { timeline in
            let stamp = timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: true, rendersAsynchronously: false) { g, _ in
                _ = stamp
                host.frame(&g)
            }
        }
        .overlay {
            TouchSurface(handler: { e in host.game.touch(e) })
        }
    }
}

// MARK: - Основа игры: время в миллисекундах, жесты, частицы, надписи и тряска

class GameBase: ArcadeGame {
    let c: GameContext
    let w: CGFloat
    let h: CGFloat
    let S: CGFloat
    let R: Int
    let parts = Particles()
    let pops = Pops()
    let shake = Shake()
    let gestures = Gestures()
    var live = false
    /// Время начала раунда и текущее время кадра, мс
    var t0: Double = 0
    var now: Double = 0
    /// Шаг кадра, с
    var dt: Double = 0

    init(_ c: GameContext) {
        self.c = c
        w = c.w
        h = c.h
        S = c.s
        R = min(2, max(0, c.round))
        now = gameNow() * 1000
        gestures.onDown = { [unowned self] p in self.onDown(p) }
        gestures.onMove = { [unowned self] p, q in self.onMove(p, q) }
        gestures.onUp = { [unowned self] p in self.onUp(p) }
        gestures.onTap = { [unowned self] p in self.onTap(p) }
        gestures.onSwipe = { [unowned self] s in self.onSwipe(s) }
    }

    /// Время от старта раунда, мс
    var ms: Double { live ? now - t0 : 0 }

    func start() {
        now = gameNow() * 1000
        t0 = now
        live = true
        begin()
    }

    func step(_ dt: Double) {
        self.dt = dt
        now = gameNow() * 1000
        update()
        parts.step(dt)
    }

    func touch(_ e: TouchEvent) { gestures.handle(e) }

    func stop() -> Int {
        end()
        live = false
        return min(100, max(0, score()))
    }

    // переопределяют игры
    func begin() {}
    func update() {}
    func end() {}
    func score() -> Int { 0 }
    func draw(_ g: inout GraphicsContext) {}
    func onDown(_ p: CGPoint) {}
    func onMove(_ p: CGPoint, _ prev: CGPoint) {}
    func onUp(_ p: CGPoint) {}
    func onTap(_ p: CGPoint) {}
    func onSwipe(_ s: Gestures.Swipe) {}

    func report() { c.report(min(100, max(0, score()))) }
    func finish(_ pts: Int, _ delayMs: Double) { c.finish(min(100, max(0, pts)), after: delayMs / 1000) }

    /// Сцена с тряской камеры (вызывать один раз за кадр)
    func world(_ g: GraphicsContext) -> GraphicsContext {
        var out = g
        let o = shake.offset(dt)
        out.translateBy(x: o.width, y: o.height)
        return out
    }

    func overlays(_ g: inout GraphicsContext) {
        parts.draw(&g)
        pops.draw(&g, dt)
    }

    func fillAll(_ g: inout GraphicsContext, _ color: Color, _ alpha: Double = 1) {
        g.fill(Path(CGRect(x: -40, y: -40, width: w + 80, height: h + 80)), with: .color(color.opacity(alpha)))
    }

    func vignette(_ g: inout GraphicsContext, _ color: Color, _ inner: CGFloat, _ outer: CGFloat, _ alpha: Double) {
        let grad = G([(0, color.opacity(0)), (1, color.opacity(alpha))])
        g.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: radial(grad, P(w / 2, h / 2), h * inner, h * outer))
    }
}
