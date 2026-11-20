import SwiftUI

final class SamuraiGame: StudioGame {
    override var fieldID:String {"slice"}
    override var accent:Color {Color(hex:0xf0b367)}
    struct Fruit {var p:CGPoint;var v:CGVector;var angle:Double;let spin:Double;let kind:Int;let axis:Double?;let r:CGFloat}
    private struct Half {var p:CGPoint;var v:CGVector;var angle:Double;let spin:Double;let kind:Int;let side:CGFloat;var life:Double;let r:CGFloat}
    private var fruits:[Fruit]=[], halves:[Half]=[]
    private var traces:[Int:[CGPoint]]=[:],count:[Int:Int]=[:]
    private var fading:[(a:CGPoint,b:CGPoint,until:Double)]=[]
    private var spawn=0.20,wave=0,points=0,best=0
    override func score()->Int{min(100,points)}
    private func launch() {
        let group=wave%3==2 ? 3:2
        let center=width*CGFloat(c.rnd.range(0.30,0.70))
        for i in 0..<group {
            let kind=(i==group-1 && wave%4==3) ? -1:c.rnd.int(4)
            let start=clamp(center+CGFloat(i-(group/2))*50,42,width-42)
            let vy = -sqrt(2*620*(height*CGFloat(c.rnd.range(0.44,0.68))))
            fruits.append(Fruit(p:P(start,height+20+CGFloat(i)*12),v:CGVector(dx:CGFloat(c.rnd.range(-44,44))+(width/2-start)*0.18,dy:vy),angle:c.rnd.range(-0.3,0.3),spin:c.rnd.range(-1.2,1.2),kind:kind,axis:(kind>=0 && wave%3==2 && i==0) ? -0.65:nil,r:CGFloat(c.rnd.range(25,34))))
        }
        wave+=1;spawn=elapsed+max(1.02,1.65-roundScale*0.18)
        sfx("whoosh",0.28)
    }
    override func simulate(_ dt:Double) {
        if elapsed>=spawn {launch()}
        for i in fruits.indices {fruits[i].p.x+=fruits[i].v.dx*dt;fruits[i].p.y+=fruits[i].v.dy*dt;fruits[i].v.dy+=620*dt;fruits[i].angle+=fruits[i].spin*dt}
        fruits.removeAll{$0.p.y>height+90 && $0.v.dy>0}
        for i in halves.indices {halves[i].p.x+=halves[i].v.dx*dt;halves[i].p.y+=halves[i].v.dy*dt;halves[i].v.dy+=650*dt;halves[i].angle+=halves[i].spin*dt;halves[i].life-=dt}
        halves.removeAll{$0.life<=0};fading.removeAll{$0.until<elapsed}
    }
    private func cut(id:Int,from a:CGPoint,to b:CGPoint) {
        guard hypot(b.x-a.x,b.y-a.y)>1.4 else{return}
        fading.append((a,b,elapsed+0.18))
        for i in fruits.indices.reversed() {
            let f=fruits[i]
            guard segmentDistance(f.p,a,b)<f.r*1.02 else{continue}
            let angle=atan2(Double(b.y-a.y),Double(b.x-a.x))
            if let axis=f.axis,abs(cos(angle-axis))<0.70 {continue}
            fruits.remove(at:i)
            if f.kind<0 {points=max(0,points-9);count[id]=0;sfx("tin");buzz("warning");toast("Цепочка прервана");continue}
            let chain=(count[id] ?? 0)+1;count[id]=chain;best=max(best,chain);points+=min(12,3+2*chain)+(f.axis != nil ? 4:0)
            for side:CGFloat in [-1,1] {
                halves.append(Half(p:f.p,v:CGVector(dx:f.v.dx+side*82,dy:f.v.dy*0.38-38),angle:f.angle,spin:Double(side)*3.8,kind:f.kind,side:side,life:0.8,r:f.r))
            }
            if chain>1 {toast("Одним взмахом ×\(chain)",color:accent)}
            sfx("slash",0.65,rate:Float(0.91+Double(chain)*0.10));buzz("light")
        }
    }
    override func handle(_ phase:TouchEvent.Phase,id:Int,p:CGPoint,time:Double) {
        switch phase {
        case .began:traces[id]=[p];count[id]=0
        case .moved,.ended:
            if let prev=traces[id]?.last {cut(id:id,from:prev,to:p);traces[id]=[p]}
            if phase == .ended {traces[id]=nil;count[id]=nil}
        case .cancelled:traces[id]=nil;count[id]=nil
        }
    }
    private func fruit(_ g:inout GraphicsContext,p:CGPoint,r:CGFloat,kind:Int,angle:Double,side:CGFloat=0) {
        var a=g;a.translateBy(x:p.x,y:p.y);a.rotate(by:.radians(angle))
        if kind<0 {a.fill(Shape2.circle(.zero,r*0.82),with:radial(G([(0,Color(hex:0x67544f)),(1,Color(hex:0x211f29))]),P(-10,-10),1,r));strokeLine(&a,[P(-r*0.33,-r*0.33),P(r*0.33,r*0.33)],.white.opacity(0.7),2);return}
        if side != 0 {a.clip(to:Shape2.rect(side<0 ? -r:0,-r,r,2*r))}
        ArcadeArt.draw(&a,"piece_fruit\(kind)",CGRect(x:-r,y:-r,width:2*r,height:2*r))
    }
    override func render(_ g:inout GraphicsContext) {
        for f in fruits {
            fruit(&g,p:f.p,r:f.r,kind:f.kind,angle:f.angle)
            if let a=f.axis {strokeLine(&g,[P(f.p.x-cosv(a)*f.r*0.78,f.p.y-sinv(a)*f.r*0.78),P(f.p.x+cosv(a)*f.r*0.78,f.p.y+sinv(a)*f.r*0.78)],.white.opacity(0.9),2)}
        }
        for h in halves {var a=g;a.opacity=min(1,h.life*2);fruit(&a,p:h.p,r:h.r,kind:h.kind,angle:h.angle,side:h.side)}
        for seg in fading{let k=(seg.until-elapsed)/0.18;strokeLine(&g,[seg.a,seg.b],Color(hex:0x9b271e).opacity(k*0.85),CGFloat(1+4*k))}
        hud(&g,left:"Сад на ветру",value:"\(points) очков",right:"Комбо ×\(best)")
    }
}
