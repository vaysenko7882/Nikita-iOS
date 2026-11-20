import SwiftUI

final class RangeGame: StudioGame {
    override var fieldID:String {"range"}
    override var accent:Color {Color(hex:0xffce77)}
    private struct Toy {var x:CGFloat;let row:Int,dir:CGFloat,pace:CGFloat;let special:Bool,protected:Bool;let seed:Double;var knocked:Double?}
    private var toys:[Toy]=[]
    private(set) var ammo=5
    private(set) var reloading=false
    private var reloadAt=0.0,spawn=0.0,turn=0,points=0,chain=0
    private var finger:(id:Int,p:CGPoint)?,lastShot:CGPoint?,shotAt = -3.0
    private func location(_ t:Toy)->CGPoint {P(t.x,height*(0.34+CGFloat(t.row)*0.145)+sinv(elapsed*2.5+t.seed)*5)}
    private var lever:CGRect{CGRect(x:width-153,y:height-73,width:135,height:48)}
    override func begin(){for row in 0..<3 {add(row:row,x:width*(0.22+CGFloat(row)*0.24))};spawn=0.85}
    private func add(row:Int,x:CGFloat?=nil) {
        let dir:CGFloat=row%2==0 ? 1:-1
        toys.append(Toy(x:x ?? (dir>0 ? -39:width+39),row:row,dir:dir,pace:CGFloat(c.rnd.range(40,65))+CGFloat(R)*9,special:turn%5==3,protected:turn%6==4,seed:c.rnd.range(0,6),knocked:nil))
        turn+=1
    }
    override func score()->Int{min(100,points)}
    override func simulate(_ dt:Double) {
        if reloading && elapsed>=reloadAt {ammo=5;reloading=false;sfx("tick");buzz("light")}
        if elapsed>=spawn {add(row:c.rnd.int(3));spawn=elapsed+c.rnd.range(0.65,1.03)}
        for i in toys.indices {toys[i].x += toys[i].pace*toys[i].dir*CGFloat(dt)}
        toys.removeAll{($0.dir>0 && $0.x>width+55)||($0.dir<0 && $0.x < -55)||($0.knocked.map{elapsed-$0>0.38} ?? false)}
    }
    private func reload(){guard ammo<5 && !reloading else{return};reloading=true;reloadAt=elapsed+0.72;sfx("reload",0.65);buzz("light")}
    override func handle(_ phase:TouchEvent.Phase,id:Int,p:CGPoint,time:Double){
        switch phase{
        case .began:if finger==nil {finger=(id,p)}
        case .ended:
            guard let f=finger,f.id==id else{return};finger=nil
            if lever.insetBy(dx:-6,dy:-8).contains(p) || p.y-f.p.y>48 {reload();return}
            guard !reloading,ammo>0 else {toast("Потяни рычаг");return}
            ammo-=1;lastShot=p;shotAt=elapsed;sfx("blip",0.62)
            if let i=toys.indices.reversed().first(where:{i in let a=location(toys[i]);return toys[i].knocked==nil && pow((p.x-a.x)/36,2)+pow((p.y-a.y)/29,2)<1}) {
                let t=toys[i];toys[i].knocked=elapsed
                if t.protected {chain=0;points=max(0,points-6);toast("Синий флажок · пропусти");buzz("warning")}
                else {chain+=1;let q=location(t);let precise=hypot(p.x-q.x,p.y-q.y)<13
                    points+=(t.special ? 10:4)+(precise ? 3:0)+min(4,chain);sfx("tin",0.68);buzz("light")
                    if t.special || chain>=3 {toast(t.special ? "Латунная звезда":"Серия ×\(chain)",color:accent)}
                }
            }else{chain=0;sfx("splat",0.35)}
        case .cancelled:finger=nil
        case .moved:break
        }
    }
    override func render(_ g:inout GraphicsContext){
        for row in 0..<3 {
            let y=height*(0.34+CGFloat(row)*0.145)+27
            g.fillColor(Shape2.rrect(0,y,width,6,2),Color(hex:0x19364d));strokeLine(&g,[P(0,y),P(width,y)],Color(hex:0xf0c997),1.5)
            for t in toys where t.row==row {
                let p=location(t);let k=t.knocked.map{CGFloat(clamp((elapsed-$0)/0.36,0,1))} ?? 0
                var a=g;a.translateBy(x:p.x,y:p.y+23);a.scaleBy(x:t.dir>0 ? -1:1,y:max(0.02,1-k));a.rotate(by:.radians(sin(elapsed*3+t.seed)*0.06))
                ArcadeArt.draw(&a,"piece_rivet",CGRect(x:-39,y:-57,width:78,height:58))
                if t.special || t.protected {
                    a.fillColor(Shape2.circle(P(5,-19),10),t.protected ? Color(hex:0x28599a):Color(hex:0x875a2c));mark(&a,t.protected ? "minus":"star.fill",CGRect(x:-1,y:-25,width:12,height:12),.white)
                }
            }
        }
        if let p=lastShot,elapsed-shotAt<0.28 {g.strokeColor(Shape2.circle(p,8+CGFloat(elapsed-shotAt)*55),.white.opacity(1-(elapsed-shotAt)/0.28),2)}
        hud(&g,left:"Бумажный порт",value:"\(points) очков")
        shade(&g,at:height-102,height:102,top:0,bottom:0.8)
        for i in 0..<5 {g.fillColor(Shape2.rrect(18+CGFloat(i)*14,height-54,8,19,4),i<ammo ? accent:.white.opacity(0.26))}
        pill(&g,reloading ? "Заряжаю…":"Перезарядить",lever,active:reloading)
    }

    override func playTurn(_ pilot: ArcadePilot) {
        if ammo == 0 { pilot.tap(P(lever.midX,lever.midY)); pilot.wait(0.8); return }
        guard !reloading, let toy = toys.first(where: { !$0.protected && $0.knocked == nil && $0.x > 21 && $0.x < width-21 }) else { return }
        let p = location(toy)
        let error = CGFloat(13 + 46*(1-pilot.skill))
        pilot.tap(P(p.x+CGFloat(pilot.random.range(-1,1))*error,p.y+CGFloat(pilot.random.range(-1,1))*error))
        pilot.wait(pilot.random.range(0.55,1.34))
    }
}
