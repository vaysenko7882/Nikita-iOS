import SwiftUI

/// Orthogonal chart with a guaranteed route to all samples and the extraction beacon.
final class MinesGame: StudioGame {
    override var fieldID: String {"mines"}
    override var accent: Color {Color(hex: 0x76e4cd)}
    let columns = 6, rows = 7
    private(set) var position = 39
    private var path = Set<Int>(), hazards = Set<Int>(), samples = Set<Int>(), visited = Set<Int>(), flagged = Set<Int>()
    private var goal = 2, collected = 0, hull = 3, pulses = 3, lastScan = -12.0, lastStep = -2.0, bestRow = 6
    private var held: (id: Int, start: CGPoint, at: Double, cell: Int?)?
    private var lastPoint: CGPoint?
    private var oldPos = 39
    private var ended = false
    private var cell: CGFloat { min((width-40)/6, (height-195)/7) }
    private var left: CGFloat {(width-cell*6)/2}
    private var top: CGFloat {max(82, (height-cell*7)*0.48)}
    private func index(_ x: Int, _ y: Int)->Int { y*columns+x }
    private func center(_ i: Int)->CGPoint {P(left+(CGFloat(i%6)+0.5)*cell, top+(CGFloat(i/6)+0.5)*cell)}
    private func at(_ p: CGPoint)->Int? {
        guard p.x>=left, p.x<left+cell*6, p.y>=top, p.y<top+cell*7 else{return nil}
        return Int((p.y-top)/cell)*6+Int((p.x-left)/cell)
    }
    override func begin() {
        var x = 3
        position = index(x, 6)
        oldPos = position
        visited = [position]
        path = [position]
        for row in stride(from: 5, through: 0, by: -1){
            path.insert(index(x, row))
            let next = clamp(x+c.rnd.int(3)-1, 0, 5)
            if next != x {path.insert(index(next, row))}
            x = next
            if row==4 || row==2 {samples.insert(index(x, row))}
        }
        goal = index(x, 0)
        for i in 0..<42 where !path.contains(i) && c.rnd.chance(0.26+roundScale*0.05) {hazards.insert(i)}
        lastScan = -0.4
        sfx("ping", 0.45)
    }
    private func nearby(_ i: Int)->Int {
        hazards.filter {abs(i%6-$0%6)<=1 && abs(i/6-$0/6)<=1}.count
    }
    override func score()->Int {min(100, (6-bestRow)*7+collected*21+(ended && position==goal ? 16: 0))}
    private func move(_ i: Int) {
        guard !ended, elapsed-lastStep>0.09, !flagged.contains(i),
              abs(i%6-position%6)+abs(i/6-position/6)==1 else{return}
        lastStep = elapsed
        if hazards.contains(i) {
            hull-=1
            flagged.insert(i)
            sfx("crash", 0.5)
            buzz("warning")
            toast("Пробоина · корпус \(hull)/3")
            if hull<=0{ended = true
                finish(score(), 600)}
            return
        }
        oldPos = position
        position = i
        visited.insert(i)
        bestRow = min(bestRow, i/6)
        sfx("step", 0.27)
        if samples.remove(i) != nil {collected+=1
            sfx("sparkle", 0.64)
            buzz("success")
            toast("Образец поднят", color: accent)}
        if position==goal {
            if samples.isEmpty {ended = true
                finish(100, 760)
                toast("Подъём на поверхность", color: accent)}
            else {toast("Нужны оба образца")}
        }
    }
    override func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double){
        switch phase{
        case .began:
            if p.y>height-82 && pulses>0 && !ended {pulses-=1
                lastScan = elapsed
                sfx("ping")
                buzz("light")
                return}
            held = (id, p, elapsed, at(p))
            lastPoint = p
        case .moved:
            guard held?.id==id else{return}
            lastPoint = p
            if let i = at(p){move(i)}
        case .ended:
            guard let hold = held, hold.id==id else{return}
            if let i = at(p), hold.cell==i, elapsed-hold.at>0.45, hypot(p.x-hold.start.x, p.y-hold.start.y)<15, !visited.contains(i), i != goal, !samples.contains(i) {
                if !flagged.insert(i).inserted {flagged.remove(i)}
                buzz("light")
            }else if let i = at(p){move(i)}
            held = nil
            lastPoint = nil
        case .cancelled: held = nil
        lastPoint = nil
        }
    }
    override func render(_ g: inout GraphicsContext) {
        shade(&g, at: 0, height: height, top: 0.24, bottom: 0.43)
        let sonar = elapsed-lastScan
        for i in 0..<42 {
            let p = center(i), r = CGRect(x: p.x-cell*0.47, y: p.y-cell*0.47, width: cell*0.94, height: cell*0.94)
            let plate = Path(roundedRect: r, cornerRadius: 6)
            g.fillColor(plate, visited.contains(i) ? accent.opacity(0.23): Color(hex: 0x09252b, alpha: 0.86))
            g.strokeColor(plate, visited.contains(i) ? accent.opacity(0.62): accent.opacity(0.22), 1)
            if flagged.contains(i) || (hazards.contains(i) && sonar<1.65) {mark(&g, "exclamationmark.triangle.fill", r.insetBy(dx: cell*0.26, dy: cell*0.26), Color(hex: 0xff9a74))}
            else if samples.contains(i) {mark(&g, "diamond.fill", r.insetBy(dx: cell*0.31, dy: cell*0.31), Color(hex: 0xf4c278))}
            else if i==goal {mark(&g, "arrow.up.circle", r.insetBy(dx: cell*0.20, dy: cell*0.20), .white)}
            else if visited.contains(i) && nearby(i)>0 {ink(&g, "\(nearby(i))", p, 14, accent, .medium, mono: true)}
            else {g.fillColor(Shape2.circle(p, 1.35), accent.opacity(0.34))}
        }
        let k = CGFloat(clamp((elapsed-lastStep)/0.14, 0, 1)), a = center(oldPos), b = center(position), sub = P(lerp(a.x, b.x, k), lerp(a.y, b.y, k))
        if sonar >= 0 && sonar<1.6 {
            var ring = g
            ring.clip(to: Shape2.rect(left, top, cell*6, cell*7))
            ring.strokeColor(Shape2.circle(sub, CGFloat(sonar)*cell*4.5), accent.opacity(1-sonar/1.6), 2)
        }
        g.fill(Shape2.circle(sub, cell*0.44), with: radial(G([(0, accent.opacity(0.30)), (1, .clear)]), sub, 0, cell*0.44))
        ArcadeArt.draw(&g, "piece_sub", CGRect(x: sub.x-cell*0.38, y: sub.y-cell*0.40, width: cell*0.76, height: cell*0.80))
        hud(&g, left: "Глубинная разведка", value: "\(collected) / 2 образца", right: "Корпус \(hull)/3")
        pill(&g, "Импульс сонара  ·  \(pulses)", CGRect(x: width/2-98, y: height-66, width: 196, height: 44), active: sonar<1.4)
    }

    override func playTurn(_ pilot: ArcadePilot) {
        guard !ended else { return }
        if pulses > 0 && (visited.count == 1 || pilot.random.chance(0.09)) {
            pilot.tap(P(width/2, height-45))
        }
        let targets = samples.isEmpty ? Set([goal]) : samples
        var queue = [position]
        var previous = [position: position]
        var cursor = 0
        while cursor < queue.count {
            let here = queue[cursor]
            cursor += 1
            if targets.contains(here) {
                var next = here
                while let parent = previous[next], parent != position { next = parent }
                pilot.tap(center(next))
                break
            }
            for (dx, dy) in [(0, -1), (-1, 0), (1, 0), (0, 1)] {
                let x = here%columns+dx, y = here/columns+dy
                guard (0..<columns).contains(x), (0..<rows).contains(y) else { continue }
                let next = index(x, y)
                if !hazards.contains(next), previous[next] == nil {
                    previous[next] = here
                    queue.append(next)
                }
            }
        }
        pilot.wait(pilot.random.range(0.9, 1.8)+(1-pilot.skill)*1.3)
    }
}
