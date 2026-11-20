import SwiftUI

/// Arcade bicycle-style handling on an authored mountain road, in metres and km/h.
final class RaceGame: StudioGame {
    override var fieldID: String { "race" }
    override var accent: Color { Color(hex:0xf8b464) }
    struct Rival {
        var distance: Double
        var lane: Double
        let pace: Double
        let phase: Double
        let tint: Color
        var counted = false
    }
    private(set) var velocity = 0.0
    private(set) var distance = 0.0
    private(set) var lateral = 0.0
    private(set) var steering = 0.0
    private(set) var passes = 0
    var practiceRival: (() -> (distance: Double, lateral: Double)?)?
    private var sideways = 0.0
    private var wheelInput = 0.0
    private var wheelID: Int?
    private var gasID: Int?
    private var brakeID: Int?
    private var wheelOrigin: CGFloat = 0
    private var wheelBase = 0.0
    private var impact = -10.0
    private var lastAudio = -1.0
    private var gear = 1
    private var rivals: [Rival] = []
    private let courseLength = 1350.0
    private var controlsY: CGFloat { height-58 }
    private var horizon: CGFloat { height*0.36 }
    private var carY: CGFloat { height*0.76 }

    override func begin() {
        rivals = (0..<9).map { i in
            Rival(distance: 48+Double(i)*87, lane: [-0.65,0.15,0.65,-0.23][i%4],
                  pace: 8+Double(i%3)*1.8+roundScale, phase: c.rnd.range(0,6),
                  tint:[Color(hex:0x7ba6b8),Color(hex:0xe3c379),Color(hex:0xc7d5ca)][i%3])
        }
        if c.effectsEnabled { Sound.shared.loop("motor",volume:0.27) }
    }
    override func end() {
        gasID=nil; brakeID=nil; wheelID=nil; wheelInput=0
        if c.effectsEnabled { Sound.shared.stopLoop("motor") }
    }
    func bend(_ at: Double) -> Double {
        0.62*sin(at/134+roundScale*0.7) + 0.39*sin(at/65-0.7) + 0.24*sin(at/278+1.1)
    }
    override func handle(_ phase: TouchEvent.Phase, id: Int, p: CGPoint, time: Double) {
        switch phase {
        case .began:
            guard p.y > height*0.67 else { return }
            if p.x < width*0.48, wheelID == nil {
                wheelID=id; wheelOrigin=p.x; wheelBase=clamp(Double((p.x-width*0.225)/58),-0.65,0.65); wheelInput=wheelBase
            } else if p.x >= width*0.73, gasID == nil { gasID=id; buzz("light") }
            else if p.x >= width*0.47, brakeID == nil { brakeID=id; buzz("light") }
        case .moved:
            if wheelID == id { wheelInput=clamp(wheelBase+Double(p.x-wheelOrigin)/52,-1,1) }
        case .ended,.cancelled:
            if wheelID == id { wheelID=nil; wheelInput=0 }
            if gasID == id { gasID=nil }
            if brakeID == id { brakeID=nil }
        }
    }
    override func simulate(_ dt: Double) {
        steering += (wheelInput-steering)*min(1,dt*9)
        let ratio=velocity/170
        let offroad=abs(lateral)>0.92
        let drag = 4.5+ratio*ratio*17+(offroad ? 34:0)
        let engine = gasID == nil ? 0.0 : 60-24*ratio
        velocity=clamp(velocity+(engine-drag-(brakeID == nil ? 0:104))*dt,0,178)
        let metres=velocity/3.6
        sideways += ((steering*(0.24+ratio*1.48)-bend(distance)*ratio*ratio*0.93)-sideways)*min(1,dt*6)
        lateral=clamp(lateral+sideways*dt*min(1,metres/3.5),-1.32,1.32)
        distance += metres*dt
        for i in rivals.indices {
            rivals[i].distance += rivals[i].pace*dt
            let dz=rivals[i].distance-distance
            let lane=rivals[i].lane+0.10*sin(elapsed*0.65+rivals[i].phase)
            if abs(dz)<4.8, abs(lane-lateral)<0.22, elapsed-impact>1.2, velocity>24 {
                velocity *= 0.63; sideways += lateral>=lane ? 0.7 : -0.7
                impact=elapsed; sfx("crash",0.55); buzz("heavy"); toast("Контакт",seconds:0.6)
            }
            if dz < -8, !rivals[i].counted { rivals[i].counted=true; passes+=1; toast("Обгон +1",color:accent); sfx("ding",0.4) }
        }
        let next=clamp(Int(velocity/31)+1,1,6)
        if next != gear { if next>gear { sfx("tick",0.27); buzz("light") }; gear=next }
        if c.effectsEnabled && elapsed-lastAudio>0.12 {
            lastAudio=elapsed
            Sound.shared.tune("motor",rate:Float(0.69+(velocity.truncatingRemainder(dividingBy:31)/47)+ratio*0.44),volume:Float(0.19+(gasID == nil ? 0.02:0.16)))
        }
        if distance>=courseLength { finish(100,500) }
    }
    override func score() -> Int {
        let target=min(courseLength,max(115,(duration-1.7)*29))
        return clamp(Int(distance/target*88)+passes*4,0,100)
    }

    private func road(_ z: Double)->(x:CGFloat,y:CGFloat,r:CGFloat) {
        let t=1.0/(1+z/19)
        let k=1-t
        let curve=(bend(distance+z*0.48)*0.50 + sin((distance+z)/216)*0.11)*k*k
        return (width*(0.5+CGFloat(curve)-CGFloat(lateral)*0.43*CGFloat(t)),horizon+(carY-horizon)*CGFloat(t),width*0.55*CGFloat(t))
    }
    override func backdrop(_ g: inout GraphicsContext, in bounds: CGRect) {
        let sceneHeight = max(height * 0.93, width * 1.65)
        let sceneWidth = max(width * 1.21, sceneHeight * 0.67)
        let pan = CGFloat(bend(distance + 70)) * width * 0.06
        let skyline = CGRect(x: (width - sceneWidth)/2 - pan, y: horizon - sceneHeight*0.53,
                             width: sceneWidth, height: sceneHeight)
        ArcadeArt.draw(&g, "world_race", skyline, fill: true)
    }
    override func render(_ g: inout GraphicsContext) {
        let strideZ=7.0, rem=distance.truncatingRemainder(dividingBy:strideZ)
        for i in stride(from:49,through:-1,by:-1) {
            let z=max(-5.4,Double(i)*strideZ-rem), zz=max(-5.3,Double(i+1)*strideZ-rem)
            let n=road(z), f=road(zz)
            let band=Int(floor((distance+z+0.1)/strideZ))
            let ground=band%2==0 ? Color(hex:0x75684b):Color(hex:0x776a4d)
            g.fillColor(Shape2.rect(0,f.y-0.5,width,max(0.5,n.y-f.y+1)),ground)
            func strip(_ x1:CGFloat,_ x2:CGFloat,_ col:Color) {
                g.fillColor(Shape2.poly([P(f.x+f.r*x1,f.y-0.4),P(f.x+f.r*x2,f.y-0.4),P(n.x+n.r*x2,n.y+0.4),P(n.x+n.r*x1,n.y+0.4)]),col)
            }
            strip(-1.04,1.04,band%4<2 ? Color(hex:0xf2dcca):Color(hex:0xbb593d))
            strip(-1,1,band%2==0 ? Color(hex:0x3c4549):Color(hex:0x3e484c))
            strip(-0.965,-0.955,.white.opacity(0.81));strip(0.955,0.965,.white.opacity(0.81))
            if band%4<2 {strip(-0.012,0.012,Color(hex:0xf6e4a7))}
            // Parallel rubber tracks, then rails and trees in the same perspective as the road.
            for track: CGFloat in [-0.60, -0.36, 0.36, 0.60] {
                strip(track-0.018, track+0.018, .black.opacity(0.07))
            }
            for side: CGFloat in [-1, 1] {
                let railNear = P(n.x + side * n.r * 1.13, n.y - n.r*0.10)
                let railFar = P(f.x + side * f.r * 1.13, f.y - f.r*0.10)
                strokeLine(&g, [railNear, railFar], Color(hex:0x655043), max(0.8,n.r*0.028))
                strokeLine(&g, [railNear, railFar], Color(hex:0xe8bd89), max(0.5,n.r*0.012))
            }
            if band >= 0, band % 4 == 1 {
                let side: CGFloat = band % 8 == 1 ? -1 : 1
                let treeHeight = f.r * (band % 3 == 0 ? 1.7 : 1.19)
                let x = f.x + side*f.r*1.79
                if x+treeHeight/2 > 0, x-treeHeight/2 < width {
                    ArcadeArt.draw(&g, "piece_pine", CGRect(x:x-treeHeight*0.39, y:f.y-treeHeight,
                                                            width:treeHeight*0.78, height:treeHeight))
                }
            }
            if band%5==0 {
                for side:CGFloat in [-1.09,1.09] {
                    let x=f.x+side*f.r
                    strokeLine(&g,[P(x,f.y),P(x,f.y-f.r*0.16)],.white.opacity(0.85),max(0.8,f.r*0.021))
                }
            }
        }
        let bottom=road(-5.4)
        g.fillColor(Shape2.rect(0,bottom.y-1,width,max(0,height-bottom.y+1)),Color(hex:0x3e484c))
        for rival in rivals.sorted(by:{$0.distance>$1.distance}) {
            let z=rival.distance-distance
            if z < -2 || z>300 { continue }
            let field=road(z), radius=field.r*0.38
            let px=field.x+field.r*CGFloat(rival.lane+0.10*sin(elapsed*0.65+rival.phase))
            drawCar(&g,center:P(px,field.y),wide:radius,tint:rival.tint,player:false)
        }
        if let rival = practiceRival?() {
            let gap = rival.distance - distance
            if gap > 2 && gap < 240 {
                let lane = road(gap)
                let wide = lane.r * 0.45
                let x = lane.x + lane.r * CGFloat(rival.lateral)
                var ghost = g
                ghost.addFilter(.hueRotation(.degrees(170)))
                drawCar(&ghost, center: P(x,lane.y), wide: wide, tint: .mint, player: false)
                if wide > 28 {
                    let marker = P(x, lane.y-wide*0.66)
                    g.fillColor(Shape2.rrect(marker.x-16,marker.y-8,32,16,8),.black.opacity(0.8))
                    ink(&g,"Бот",marker,10,.mint,.bold)
                }
            }
        }
        var chassis=g
        let lean=CGFloat(steering)*4
        chassis.translateBy(x:width*0.5,y:carY+8)
        chassis.rotate(by:.degrees(Double(lean)))
        let carWidth=min(width*0.37,154)
        drawCar(&chassis,center:.zero,wide:carWidth,tint:.white,player:true)
        if elapsed-impact<0.22 {g.fillColor(Shape2.rect(0,0,width,height),.white.opacity(max(0,0.18-(elapsed-impact))))}
        hud(&g,left:"Серпантины",value:"\(Int(distance)) м",right:"\(passes) обг.  ·  \(Int(ceil(remaining))) с")
        shade(&g,at:height-148,height:148,top:0,bottom:0.89)
        let dial=P(width*0.225,controlsY)
        var wheel=g
        wheel.translateBy(x:dial.x,y:dial.y);wheel.rotate(by:.degrees(steering*48))
        wheel.fillColor(Shape2.circle(.zero,38),.black.opacity(0.70));wheel.strokeColor(Shape2.circle(.zero,33),.white.opacity(0.8),5)
        for a in [-0.20,Double.pi+0.20,Double.pi/2] {strokeLine(&wheel,[.zero,P(cosv(a)*30,sinv(a)*30)],.white.opacity(0.7),4)}
        wheel.fillColor(Shape2.circle(.zero,8),Color(hex:0xd6dcda));strokeLine(&wheel,[P(0,-30),P(0,-36)],accent,4)
        ink(&g,"\(Int(velocity))",P(width*0.50,height-132),23,.white,.bold,mono:true)
        ink(&g,"КМ/Ч  ·  \(gear)",P(width*0.50,height-112),9,.white.opacity(0.75),.medium,mono:true)
        pill(&g,"ТОРМОЗ",CGRect(x:width*0.49,y:controlsY-20,width:width*0.208,height:43),active:brakeID != nil)
        pill(&g,"ГАЗ",CGRect(x:width*0.72,y:controlsY-36,width:width*0.235,height:65),active:gasID != nil)
    }
    private func drawCar(_ g: inout GraphicsContext,center p:CGPoint,wide:CGFloat,tint:Color,player:Bool) {
        g.fillColor(Shape2.ellipse(P(p.x,p.y+2),wide*0.51,wide*0.09),.black.opacity(0.36))
        let rect=CGRect(x:p.x-wide/2,y:p.y-wide*0.60,width:wide,height:wide*0.63)
        ArcadeArt.draw(&g,"piece_coupe",rect)
        if !player {g.fillColor(Shape2.rrect(p.x-wide*0.15,p.y-wide*0.20,wide*0.30,max(1,wide*0.035),1),tint)}
        if player && brakeID != nil {
            for side:CGFloat in [-1,1] {
                let q=P(p.x+side*wide*0.32,p.y-wide*0.19)
                g.fill(Shape2.circle(q,13),with:radial(G([(0,.red.opacity(0.9)),(1,.clear)]),q,0,13))
            }
        }
    }

    override func playTurn(_ pilot: ArcadePilot) {
        let curve = bend(distance+22)
        let cruise = 85 + 72*pilot.skill - abs(curve)*28
        let wheel = P(width*0.225,controlsY)
        let desiredLane = 0.25*sin(distance/68) + 0.09
        let steer = clamp((desiredLane-lateral)*2.6 + curve*velocity/190, -1, 1)
        pilot.down(1, at: wheel)
        pilot.move(1, to: P(wheel.x+CGFloat(steer)*52,wheel.y))
        if velocity < cruise-3 {
            pilot.up(3)
            pilot.down(2, at: P(width*0.84,controlsY))
        } else {
            pilot.up(2)
            if velocity > cruise+9 { pilot.down(3, at: P(width*0.60,controlsY)) }
            else { pilot.up(3) }
        }
        pilot.wait(0.13)
    }
}
