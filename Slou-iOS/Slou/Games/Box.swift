import SwiftUI

final class BoxGame: StudioGame {
    override var fieldID: String { "box" }
    override var accent: Color { Color(hex: 0xf08163) }
    private(set) var stamina = 1.0
    private(set) var opponentHealth = 100.0
    private var health = 100.0, attack = 2.6, recover = 0.0, dodge = 0.0, dodgeSide = 1.0
    private var punch = -2.0, punchSide = 1.0, recoil = -2.0, swing = -2.0, opening = -2.0
    private var finger: (id: Int, p: CGPoint, time: Double)?
    private var guarding: Bool { finger != nil && elapsed-(finger?.time ?? elapsed)>0.21 && stamina>0.10 }
    private var chain = 0, hits = 0
    private var target: CGPoint { P(width/2 + 26*cosv(elapsed*1.4+Double(R)), height*0.44) }
    override func begin() { attack = 2.0+c.rnd.range(0, 0.6)
        sfx("bell", 0.52) }
    override func score()->Int { clamp(Int(100-opponentHealth)+min(12, hits*2), 0, 100) }
    override func simulate(_ dt: Double) {
        stamina = clamp(stamina+(guarding ? -0.07: 0.21)*dt, 0, 1)
        dodge = max(0, dodge-dt)
        recover = max(0, recover-dt)
        if elapsed>=attack && opponentHealth>0 && health>0 {
            swing = elapsed
            if dodge>0 {
                opening = elapsed+0.95
                toast("Окно контратаки", color: accent)
                sfx("whoosh", 0.6)
            } else if guarding {
                stamina = max(0, stamina-0.12)
                opening = elapsed+0.56
                toast("Блок")
                sfx("block", 0.65)
                buzz("medium")
            } else {
                health = max(0, health-Double(14+R*3))
                chain = 0
                recoil = elapsed
                sfx("punch", 0.58)
                buzz("heavy")
                if health<=0 {finish(score(), 700)}
            }
            attack = elapsed+c.rnd.range(1.9, 3.0)-roundScale*0.13
        }
    }
    override func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double){
        switch phase {
        case .began: if finger==nil {finger = (id, p, elapsed)}
        case .moved: break
        case .cancelled: if finger?.id==id {finger = nil}
        case .ended:
            guard let f = finger, f.id==id else{return}
            finger = nil
            let dx = p.x-f.p.x, dy = p.y-f.p.y
            if abs(dx)>48 && abs(dx)>abs(dy)*0.9 && stamina>0.10 {
                dodge = 0.48
                dodgeSide = dx<0 ? -1: 1
                stamina-=0.10
                sfx("whoosh", 0.43)
                return
            }
            if elapsed-f.time>0.35 && abs(dy)<40 {return}
            guard recover==0, stamina>0.15, health>0 else{return}
            let upper = dy < -38
            recover = upper ? 0.42: 0.24
            stamina = max(0, stamina-(upper ? 0.24: 0.14))
            punch = elapsed
            punchSide = p.x<width/2 ? -1: 1
            let strike = upper ? p : f.p
            let contact = pow((strike.x-target.x)/(width*0.30), 2) + pow((strike.y-target.y)/(height*0.28), 2)
            guard contact <= 1 else {
                chain = 0
                sfx("whoosh", 0.38)
                return
            }
            let open = elapsed<opening || attack-elapsed<0.65 || sin(elapsed*2.55)>0.12
            if open {
                let counter = elapsed<opening
                let strength = Double((upper ? 12: 8)+(counter ? 8: 0)+min(chain, 4))
                opponentHealth = max(0, opponentHealth-strength)
                hits+=1
                chain+=1
                sfx(counter || upper ? "punch_big": "punch", 0.8)
                buzz(counter ? "heavy": "medium")
                if counter {toast("Контратака", color: accent)}
                if opponentHealth<=0 {toast("Нокаут", color: accent)
                    finish(100, 720)}
            } else {chain = 0
            sfx("block", 0.52)
            toast("Соперник в блоке", seconds: 0.42)}
        }
    }
    override func render(_ g: inout GraphicsContext) {
        let hit = max(0, 1-(elapsed-punch)/0.27), foeSwing = max(0, 1-(elapsed-swing)/0.49)
        let size = min(height*0.75, width*1.29), anchor = target
        var actor = g
        actor.translateBy(x: anchor.x-CGFloat(dodge*dodgeSide)*45+CGFloat(hit*punchSide)*11, y: height*0.75)
        actor.rotate(by: .degrees(-punchSide*hit*4+sin(elapsed*1.7)*1.0))
        ArcadeArt.draw(&actor, "piece_fighter", CGRect(x: -size*0.43, y: -size+CGFloat(sinv(elapsed*3))*2, width: size*0.86, height: size))
        if foeSwing>0 { glove(&g, at: P(anchor.x+CGFloat(foeSwing)*25, anchor.y+20), scale: 0.45+CGFloat(foeSwing)*0.57, side: 1, opponent: true) }
        for side: CGFloat in [-1, 1] {
            let jab = Double(side)==punchSide ? CGFloat(hit): 0
            let lift = guarding ? height*0.11: 0
            glove(&g, at: P(width/2+side*(width*0.35-jab*width*0.17), height*(0.86-jab*0.27)-lift), scale: 0.94-jab*0.2, side: side, opponent: false)
        }
        if elapsed-recoil<0.22 {g.fillColor(Shape2.rect(0, 0, width, height), Color.red.opacity(max(0, 0.24-(elapsed-recoil))))}
        hud(&g, left: "Попадания", value: "\(hits)")
        meter(&g, CGRect(x: 16, y: 63, width: width*0.44, height: 4), CGFloat(health/100), .white)
        meter(&g, CGRect(x: width*0.52, y: 63, width: width*0.44, height: 4), CGFloat(opponentHealth/100), accent)
        if attack-elapsed<0.72 && attack>elapsed {
            let v = CGFloat(1-(attack-elapsed)/0.72)
            let q = P(anchor.x+width*0.18, anchor.y-19)
            g.strokeColor(Shape2.circle(q, 18-v*4), accent, 2.5)
            mark(&g, "exclamationmark", CGRect(x: q.x-3, y: q.y-8, width: 6, height: 16), .white)
        }
        shade(&g, at: height-92, height: 92, top: 0, bottom: 0.87)
        ink(&g, guarding ? "Блок" : "Выносливость", P(18, height-38), 13, .white, .semibold, anchor: .leading)
        meter(&g, CGRect(x: 16, y: height-23, width: width-32, height: 4), CGFloat(stamina), accent)
    }
    private func glove(_ g: inout GraphicsContext, at p: CGPoint, scale: CGFloat, side: CGFloat, opponent: Bool) {
        var sprite = g
        sprite.translateBy(x: p.x, y: p.y)
        sprite.scaleBy(x: side * scale, y: scale)
        sprite.rotate(by: .degrees(opponent ? -18 : -11))
        if opponent { sprite.addFilter(.colorMultiply(Color(red: 1, green: 0.69, blue: 0.59))) }
        ArcadeArt.draw(&sprite, "piece_glove", CGRect(x: -52, y: -60, width: 104, height: 145))
    }

    override func playTurn(_ pilot: ArcadePilot) {
        let hand = P(target.x + CGFloat(pilot.random.range(-24, 24)), target.y+48)
        if pilot.hands[1] != nil {
            pilot.up(1)
            pilot.wait(0.08)
        } else if attack-elapsed < 0.52 && pilot.random.chance(0.35+pilot.skill*0.55) {
            pilot.down(1, at: hand)
            pilot.wait(max(0.22, attack-elapsed+0.10))
        } else if stamina > 0.25 {
            if pilot.random.chance(0.35) { pilot.swipe(from: hand, to: P(hand.x, hand.y-62)) }
            else { pilot.tap(hand) }
            pilot.wait(pilot.random.range(0.55, 1.15) + (1-pilot.skill)*0.65)
        } else { pilot.wait(0.4) }
    }
}
