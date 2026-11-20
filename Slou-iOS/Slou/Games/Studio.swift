import SwiftUI
import UIKit

/// Bitmaps are stored once and reused by the collection, intro and game field.
enum ArcadeArt {
    private static var cache: [String: UIImage] = [:]
    static func bitmap(_ key: String) -> UIImage? {
        if let image = cache[key] { return image }
        for ext in ["jpg", "png"] {
            for folder in [nil, "ArcadeArt"] as [String?] {
                if let url = Bundle.main.url(forResource: key, withExtension: ext, subdirectory: folder),
                   let image = UIImage(contentsOfFile: url.path) { cache[key] = image; return image }
            }
        }
        return nil
    }

    static func draw(_ g: inout GraphicsContext, _ key: String, _ rect: CGRect, fill: Bool = false) {
        guard let image = bitmap(key), rect.width > 0, rect.height > 0 else { return }
        let a = rect.width / image.size.width, b = rect.height / image.size.height
        let scale = fill ? max(a, b) : min(a, b)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        var layer = g
        if fill { layer.clip(to: Path(rect)) }
        layer.draw(Image(uiImage: image), in: CGRect(x: rect.midX - size.width/2, y: rect.midY - size.height/2, width: size.width, height: size.height))
    }
}

struct ArcadeCover: View {
    let id: String
    var body: some View {
        GeometryReader { geo in
            if let art = ArcadeArt.bitmap("world_" + id) {
                Image(uiImage: art).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
            if let name = ["box":"piece_fighter","race":"piece_coupe","arm":"piece_grip","goal":"piece_keeper","range":"piece_rivet","slice":"piece_fruit0","mines":"piece_sub","hoop":"piece_basketball"][id],
               let art = ArcadeArt.bitmap(name) {
                Image(uiImage: art).resizable().scaledToFit()
                    .frame(width: geo.size.width * (id == "race" ? 0.84 : 0.68), height: geo.size.height * (["hoop","mines"].contains(id) ? 0.44 : 0.77))
                    .position(x: geo.size.width * 0.56, y: geo.size.height * 0.49)
            }
        }.clipped().accessibilityHidden(true)
    }
}

func ink(_ g: inout GraphicsContext, _ value: String, _ p: CGPoint, _ size: CGFloat, _ color: Color = .white,
         _ weight: Font.Weight = .semibold, anchor: UnitPoint = .center, mono: Bool = false) {
    let label = Text(value).font(.system(size: size, weight: weight, design: mono ? .monospaced : .default)).foregroundStyle(color)
    g.draw(label, at: p, anchor: anchor)
}

func mark(_ g: inout GraphicsContext, _ name: String, _ rect: CGRect, _ color: Color) {
    var glyph = g.resolve(Image(systemName: name))
    glyph.shading = .color(color)
    g.draw(glyph, in: rect)
}

func strokeLine(_ g: inout GraphicsContext, _ points: [CGPoint], _ color: Color, _ width: CGFloat = 1) {
    guard let first = points.first else { return }
    var path = Path()
    path.move(to: first)
    for p in points.dropFirst() { path.addLine(to: p) }
    g.strokeColor(path, color, width)
}

func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let x = b.x-a.x, y = b.y-a.y
    let t = clamp(((p.x-a.x)*x+(p.y-a.y)*y)/max(0.01,x*x+y*y), 0, 1)
    return hypot(p.x-a.x-t*x,p.y-a.y-t*y)
}

/// The drawing and input coordinate systems are identical on phones and tablets.
class StudioGame: GameBase {
    var fieldID: String { "" }
    var accent: Color { .white }
    var unit: CGFloat { max(0.01, min(w/390, h/580)) }
    var width: CGFloat { w/unit }
    var height: CGFloat { h/unit }
    private(set) var elapsed = 0.0
    private(set) var ambient = 0.0
    private var notice = ""
    private var noticeUntil = 0.0
    private var noticeColor = Color.white
    private var lastReport = -1
    var duration: Double { c.duration }
    var remaining: Double { max(0, duration-elapsed) }
    var roundScale: Double { Double(R) }

    override func start() {
        elapsed = 0
        super.start()
    }
    override func step(_ delta: Double) {
        dt = max(0, min(delta, 0.18))
        now = gameNow() * 1000
        ambient += dt
        guard live else { return }
        var left = dt
        while left > 0.00001 {
            let step = min(left, 1.0/60.0)
            elapsed += step
            simulate(step)
            left -= step
        }
        let current = clamp(score(), 0, 100)
        if current != lastReport { lastReport = current; c.report(current) }
    }
    func playTurn(_ pilot: ArcadePilot) {}
    func sfx(_ name: String, _ volume: Float = 1, rate: Float = 1) {
        if c.effectsEnabled { Sound.shared.play(name, volume: volume, rate: rate) }
    }
    func buzz(_ kind: String) {
        if c.effectsEnabled { Haptics.shared.play(kind) }
    }
    func simulate(_ dt: Double) {}
    func render(_ g: inout GraphicsContext) {}
    func backdrop(_ g: inout GraphicsContext, in bounds: CGRect) {
        ArcadeArt.draw(&g, "world_" + fieldID, bounds, fill: true)
    }
    func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double) {}
    override func touch(_ e: TouchEvent) {
        guard live else { return }
        handle(e.phase, id: e.id, p: P(e.point.x/unit,e.point.y/unit), time: e.time)
    }
    override func draw(_ g: inout GraphicsContext) {
        var view = g
        view.scaleBy(x: unit,y: unit)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        view.fill(Path(bounds), with: .color(Color(hex: 0x11191c)))
        backdrop(&view, in: bounds)
        render(&view)
        if noticeUntil > elapsed {
            var n = view
            n.opacity = min(1,(noticeUntil-elapsed)*6)
            let p = P(width/2, height*0.22)
            let measured = n.resolve(Text(notice).font(.system(size: 15,weight:.semibold))).measure(in: CGSize(width: width, height: 40)).width
            n.fillColor(Shape2.rrect(p.x-measured/2-13,p.y-15,measured+26,30,15),Color.black.opacity(0.76))
            ink(&n,notice,p,15,noticeColor)
        }
    }
    func toast(_ value: String, color: Color = .white, seconds: Double = 0.75) {
        notice = value; noticeColor = color; noticeUntil = elapsed+seconds
    }
    func shade(_ g: inout GraphicsContext, at y: CGFloat, height span: CGFloat, top: Double, bottom: Double) {
        g.fill(Shape2.rect(0,y,width,span),with:linear(G([(0,.black.opacity(top)),(1,.black.opacity(bottom))]),P(0,y),P(0,y+span)))
    }
    func hud(_ g: inout GraphicsContext, left: String, value: String, right: String = "") {
        shade(&g,at:0,height:92,top:0.76,bottom:0)
        ink(&g,left.uppercased(),P(16,15),10,.white.opacity(0.72),.semibold,anchor:.leading,mono:true)
        let scoreLabel = Text(value).font(ArcadeType.title(fieldID, 23)).foregroundStyle(.white)
        g.draw(scoreLabel, at: P(16,40), anchor: .leading)
        ink(&g,right.isEmpty ? "\(Int(ceil(remaining))) с" : right,P(width-16,23),15,.white,.semibold,anchor:.trailing,mono:true)
    }
    func pill(_ g: inout GraphicsContext, _ text: String, _ rect: CGRect, active: Bool = false) {
        let p = Shape2.rrect(rect.minX,rect.minY,rect.width,rect.height,min(16,rect.height/2))
        g.fillColor(p,active ? accent : Color(hex:0x10161a,alpha:0.87))
        g.strokeColor(p,active ? accent : .white.opacity(0.35),1)
        ink(&g,text,P(rect.midX,rect.midY),14,active ? Color(hex:0x0d1011) : .white,.semibold)
    }
    func meter(_ g: inout GraphicsContext, _ rect: CGRect, _ fraction: CGFloat, _ color: Color) {
        g.fillColor(Shape2.rrect(rect.minX,rect.minY,rect.width,rect.height,rect.height/2),.white.opacity(0.19))
        g.fillColor(Shape2.rrect(rect.minX,rect.minY,rect.width*clamp(fraction,0,1),rect.height,rect.height/2),color)
    }
}
