import SwiftUI

final class ArmGame: StudioGame {
    override var fieldID: String {"arm"}
    override var accent: Color {Color(hex: 0xffc689)}
    private(set) var leverage = 0.0
    private(set) var stamina = 1.0
    private var best = 0.0, grip: Int?, lunges = 0, nextPush = 2.8, reversalUntil = -1.0
    private var counterReady = false, defeated = false, pinned = false, moved = false
    private var telegraph: Bool {elapsed>=nextPush-0.78 && elapsed<nextPush}
    private var surge: Bool {elapsed>=nextPush && elapsed<nextPush+0.60}
    private var handleRect: CGRect{CGRect(x: width*0.15, y: height-95, width: width*0.7, height: 56)}
    override func begin(){nextPush = 2.45+c.rnd.range(0, 0.45)}
    override func score()->Int{pinned ? 100 : moved ? clamp(Int(best*72)+lunges*9, 0, 99): 0}
    override func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double) {
        switch phase {
        case .began:
            if grip==nil, p.y>=height*0.55 {grip = id
                moved = true
                sfx("pump0", 0.40)
                buzz("light")
                if counterReady {counterReady = false
                    reversalUntil = elapsed+0.8
                    lunges+=1
                    stamina = min(1, stamina+0.24)
                    toast("Перехват", color: accent)
                    sfx("pump4", 0.65)}
            }
        case .ended, .cancelled:
            if grip==id {grip = nil
                if phase == .ended && (telegraph || surge) {counterReady = true
                    sfx("whoosh", 0.42)}
            }
        case .moved: break
        }
    }
    override func simulate(_ dt: Double){
        guard !defeated else{return}
        if elapsed>nextPush+1.0 {nextPush = elapsed+c.rnd.range(2.1, 3.1)-roundScale*0.13
            counterReady = false}
        let applying = grip != nil
        stamina = clamp(stamina+(applying ? -0.30: 0.44)*dt, 0, 1)
        let pressure = applying ? (0.04+0.36*stamina): 0
        let resistance = (surge ? 0.54: (telegraph ? 0.035: 0.12))+roundScale*0.019
        leverage = clamp(leverage+(pressure-resistance+(elapsed<reversalUntil ? 0.55: 0))*dt, -1, 1)
        best = max(best, leverage)
        if leverage>=0.99 {defeated = true
            pinned = true
            toast("Дожим", color: accent)
            sfx("victory", 0.65)
            buzz("success")
            finish(100, 700)}
        if leverage<=(-0.99){defeated = true
            let value = moved ? clamp(Int(best*72)+lunges*9, 0, 99): 0
            finish(value, 650)
            toast("Раунд соперника")
            sfx("slam", 0.55)}
    }
    override func render(_ g: inout GraphicsContext){
        let angle = leverage*39+(surge ? sin(elapsed*35)*0.9: 0)
        var arms = g
        arms.translateBy(x: width/2, y: height*0.66)
        arms.rotate(by: .degrees(angle))
        let span = min(width*1.14, height*0.93)
        ArcadeArt.draw(&arms, "piece_grip", CGRect(x: -span/2, y: -span*0.60, width: span, height: span*0.65))
        let middle = P(width/2, height*0.70), radius = min(width*0.28, 108)
        g.strokeColor(Shape2.arc(middle, radius, Double.pi*1.18, Double.pi*1.82), .white.opacity(0.52), 2)
        let phi = Double.pi*(1.5+leverage*0.32)
        g.fillColor(Shape2.circle(P(middle.x+cosv(phi)*radius, middle.y+sinv(phi)*radius), 5), accent)
        hud(&g, left: "Поединок хвата", value: telegraph ? "Готовит рывок" : surge ? "Рывок соперника" : grip != nil ? "Давление": "Передышка", right: "\(Int(ceil(remaining))) с")
        shade(&g, at: height-144, height: 144, top: 0, bottom: 0.90)
        meter(&g, CGRect(x: width*0.16, y: height-112, width: width*0.68, height: 5), CGFloat(stamina), stamina<0.2 ? Color(hex: 0xfb886a): accent)
        pill(&g, counterReady ? "Перехватить" : telegraph && grip != nil ? "Отпусти хват" : grip != nil ? "Давишь" : "Удерживать хват", handleRect, active: grip != nil)
    }

    override func playTurn(_ pilot: ArcadePilot) {
        let press = P(handleRect.midX, handleRect.midY)
        if counterReady || (pilot.hands[1] == nil && stamina > 0.62) {
            pilot.down(1, at: press)
        } else if stamina < 0.21 || (telegraph && pilot.random.chance(pilot.skill*0.5)) {
            pilot.up(1)
        }
        pilot.wait(pilot.random.range(0.12, 0.31))
    }
}
