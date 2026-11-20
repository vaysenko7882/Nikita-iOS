import SwiftUI

/// A readiness duel with a moving brass medallion and a false starting signal.
final class ShowdownGame: StudioGame {
    override var fieldID: String {"duel"}
    override var accent: Color {Color(hex: 0xf4bd78)}
    enum State {case ready, waiting, liveSignal, feedback}
    private(set) var state = State.ready
    private var hand: Int?, signalAt = 0.0, timeout = 0.0, next = 0.0
    private var wins = 0, attempts = 0, points = 0, signal: CGPoint = .zero, from: CGPoint = .zero, aim: CGPoint?
    private var reaction = 0, phaseOffset = 0.0
    private var plate: CGRect {CGRect(x: width*0.15, y: height-93, width: width*0.70, height: 58)}
    private var target: CGPoint {
        P(signal.x+cosv((elapsed-signalAt)*1.9+phaseOffset)*width*0.055, signal.y+sinv((elapsed-signalAt)*2.5)*10)
    }
    override func begin(){phaseOffset = c.rnd.range(0, 6)
        signal = P(width/2, height*0.4)}
    private func arm(_ id: Int, p: CGPoint) {
        state = .waiting
        hand = id
        from = p
        aim = nil
        signalAt = elapsed+c.rnd.range(0.72, 1.65)+roundScale*0.10
        signal = P(width*CGFloat(c.rnd.range(0.22, 0.78)), height*CGFloat(c.rnd.range(0.32, 0.53)))
        sfx("tick", 0.4)
    }
    private func conclude(_ value: Int, _ label: String) {
        points+=value
        attempts+=1
        if value>0 {wins+=1}
        state = .feedback
        hand = nil
        aim = nil
        next = elapsed+0.75
        toast(label, color: value>0 ? accent: .white, seconds: 0.7)
        if value>0 {sfx("bell", 0.65)
            buzz("success")}else{sfx("tin", 0.64)
            buzz("warning")}
        if attempts==4 {finish(score(), 760)}
    }
    override func score()->Int {min(100, points)}
    override func simulate(_ dt: Double) {
        if state == .waiting && elapsed>=signalAt {state = .liveSignal
            timeout = elapsed+2.5-roundScale*0.24
            sfx("bell", 0.7)
            buzz("light")}
        if state == .liveSignal && elapsed>timeout {conclude(0, "Время вышло")}
        if state == .feedback && elapsed>next && attempts<4 {state = .ready}
    }
    override func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double){
        switch phase{
        case .began:
            if state == .ready && plate.insetBy(dx: -24, dy: -24).contains(p) {arm(id, p: p)}
            else if state == .liveSignal && hand==nil {hand = id
                aim = p}
        case .moved:
            guard hand==id else{return}
            if state == .waiting && hypot(p.x-from.x, p.y-from.y)>49 {conclude(0, "Фальстарт")}
            if state == .liveSignal {aim = p}
        case .ended:
            guard hand==id else{return}
            hand = nil
            if state == .waiting {conclude(0, "Фальстарт")
                return}
            if state == .liveSignal {
                let d = hypot(p.x-target.x, p.y-target.y)
                if plate.insetBy(dx: -10, dy: -10).contains(p) {aim = nil
                    return}
                reaction = Int(max(0, elapsed-signalAt)*1000)
                let hit = d < max(27, 42-CGFloat(R)*3)
                conclude(hit ? clamp(27-Int(d/6)-reaction/300, 8, 25): 0, hit ? "\(reaction) мс": "Мимо")
            }
        case .cancelled:
            if hand==id {hand = nil
                aim = nil
                if state == .waiting {state = .ready}}
        }
    }
    override func render(_ g: inout GraphicsContext) {
        hud(&g, left: "Полдень", value: "\(wins) / 4 печати")
        if state == .liveSignal {
            let q = target, r: CGFloat = 36
            g.fillColor(Shape2.circle(q, r+5), Color(hex: 0x493522, alpha: 0.9))
            g.fill(Shape2.circle(q, r), with: linear(G([(0, Color(hex: 0xffdf97)), (0.5, Color(hex: 0xb8733c)), (1, Color(hex: 0x674027))]), P(q.x-r, q.y-r), P(q.x+r, q.y+r)))
            g.strokeColor(Shape2.circle(q, r-6), .white.opacity(0.75), 1.3)
            g.fillColor(Shape2.star(q, 19, inner: 0.41), Color(hex: 0x493624))
            if let p = aim{strokeLine(&g, [from, p], .white.opacity(0.58), 2)
                g.strokeColor(Shape2.circle(p, 10), .white, 1.7)}
        }else if state == .waiting {
            let q = P(width/2, height*0.42), t = signalAt-elapsed
            g.strokeColor(Shape2.circle(q, 17+CGFloat(max(0, t))*6), .white.opacity(0.60), 1.3)
            if R>0 && t>0.43 && t<0.72 {mark(&g, "wind", CGRect(x: q.x-12, y: q.y-7, width: 24, height: 14), .white.opacity(0.72))}
        }
        shade(&g, at: height-151, height: 151, top: 0, bottom: 0.86)
        let msg = state == .ready ? "Зажать до звонка" : state == .waiting ? "Жди звонка…" : state == .liveSignal ? "Веди к печати и отпускай" : "Следующая печать"
        pill(&g, msg, plate, active: state == .liveSignal)
    }

    override func playTurn(_ pilot: ArcadePilot) {
        switch state {
        case .ready: pilot.down(1, at: P(plate.midX, plate.midY))
        case .liveSignal:
            let error = 15 + (1-pilot.skill)*52
            let point = P(target.x+CGFloat(pilot.random.range(-error, error)), target.y+CGFloat(pilot.random.range(-error, error)))
            pilot.move(1, to: point)
            pilot.up(1, at: point)
        case .waiting, .feedback: break
        }
        pilot.wait(pilot.random.range(0.15, 0.37))
    }
}
