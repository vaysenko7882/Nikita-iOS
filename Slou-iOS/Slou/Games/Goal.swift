import SwiftUI

final class GoalGame: StudioGame {
    override var fieldID:String {"goal"}
    override var accent:Color{Color(hex:0xf1bc63)}
    private enum State {case aim,flight,settle}
    private struct Shot {let from:CGPoint,to:CGPoint,sideSpin:CGFloat,speed:Double,started:Double,keeperFrom:CGFloat,keeperTo:CGFloat}
    private var state=State.aim, shot:Shot?, finger:Int?, trace:[CGPoint]=[], touchAt=0.0
    private var readyAt=0.0, attempts=0, goals=0, extra=0, oldAim=0.0, hitNet = -10.0, saved=false
    private var ballOrigin:CGPoint{P(width/2,height*0.82)}
    private var net:CGRect{CGRect(x:width*0.075,y:height*0.28,width:width*0.85,height:min(height*0.255,width*0.46))}
    private var keeperIdle:CGFloat {net.midX+CGFloat(sin(elapsed*1.9+roundScale))*net.width*0.085}
    private var corner:CGPoint{P((attempts+R)%2==0 ? net.minX+22:net.maxX-22,net.minY+21)}
    override func score()->Int{min(100,goals*18+extra)}
    private func destination(_ points:[CGPoint])->(CGPoint,CGFloat) {
        guard let first=points.first,let last=points.last else{return (P(net.midX,net.midY),0)}
        let dx=last.x-first.x,up=max(26,first.y-last.y)
        let duration=max(0.08,elapsed-touchAt)
        let power=clamp(up/CGFloat(duration)/1100,0,1)
        let x=net.midX+dx/up*net.width*0.91
        let y=net.maxY-(clamp(up/(height*0.40),0.05,1.38)*0.74+power*0.26)*net.height
        let mid=points[points.count/2],dev=mid.x-(first.x+last.x)*0.5
        return (P(clamp(x,-width*0.12,width*1.12),clamp(y,net.minY-65,net.maxY+22)),clamp(dev,-78,78))
    }
    override func handle(_ phase:TouchEvent.Phase,id:Int,p:CGPoint,time:Double){
        guard state == .aim else{return}
        switch phase{
        case .began:
            if finger==nil && p.y>height*0.52 {finger=id;touchAt=elapsed;trace=[p]}
        case .moved:
            if finger==id {trace.append(p);if trace.count>70 {trace.remove(at:1)}}
        case .ended:
            guard finger==id,let f=trace.first else{return};finger=nil;trace.append(p)
            guard f.y-p.y>32 else{trace=[];return}
            let (dest,curl)=destination(trace)
            let newSide=Double((dest.x-net.midX)/net.width)
            let learned = attempts>0 && abs(newSide-oldAim)<0.19
            let read=c.rnd.chance(learned ? 0.82:0.32+roundScale*0.10)
            let guess=read ? dest.x-curl*0.85:net.midX+(c.rnd.chance(0.5) ? -1:1)*net.width*0.32
            oldAim=newSide
            shot=Shot(from:ballOrigin,to:dest,sideSpin:curl,speed:clamp(0.71-(elapsed-touchAt)*0.10,0.48,0.69),started:elapsed,keeperFrom:keeperIdle,keeperTo:clamp(guess,net.minX+15,net.maxX-15))
            state = .flight;trace=[];sfx("kick",0.86);buzz("medium")
        case .cancelled:if finger==id {finger=nil;trace=[]}
        }
    }
    private func position(_ s:Shot,_ t:CGFloat)->CGPoint {P(lerp(s.from.x,s.to.x,t)+s.sideSpin*3.2*t*(1-t),lerp(s.from.y,s.to.y,t)-height*0.12*4*t*(1-t))}
    override func simulate(_ dt:Double){
        if state == .flight,let s=shot,elapsed-s.started>=s.speed{
            let inside=net.insetBy(dx:3,dy:3).contains(s.to)
            let reach=net.width*(0.11+CGFloat(R)*0.016)
            saved=abs(s.to.x-s.keeperTo)<reach && s.to.y>net.minY+net.height*0.15
            if inside && !saved {
                let bonus=hypot(s.to.x-corner.x,s.to.y-corner.y)<29
                goals+=1;extra+=bonus ? 7:0;hitNet=elapsed
                toast(bonus ? "В девятку +7":"Гол",color:accent);sfx("net");sfx("crowd",0.55);buzz("success")
            }else{toast(inside ? "Сейв":"Мимо");sfx(inside ? "block":"post",0.62)}
            attempts+=1;state = .settle;readyAt=elapsed+0.92
            if attempts>=5 {finish(score(),900)}
        }
        if state == .settle && elapsed>=readyAt && attempts<5 {state = .aim;shot=nil}
    }
    override func render(_ g:inout GraphicsContext){
        let n=net
        let warp=CGFloat(max(0,1-(elapsed-hitNet)/0.57))*sinv((elapsed-hitNet)*21)*7
        var netting=Path()
        for i in 0...18{let x=n.minX+CGFloat(i)/18*n.width;netting.move(to:P(x,n.minY));netting.addQuadCurve(to:P(x,n.maxY),control:P(x+warp,n.midY))}
        for j in 0...8{let y=n.minY+CGFloat(j)/8*n.height;netting.move(to:P(n.minX,y));netting.addQuadCurve(to:P(n.maxX,y),control:P(n.midX,y+warp))}
        g.fillColor(Path(n),.black.opacity(0.23));g.strokeColor(netting,.white.opacity(0.40),0.8)
        strokeLine(&g,[P(n.minX,n.maxY+4),P(n.minX,n.minY),P(n.maxX,n.minY),P(n.maxX,n.maxY+4)],Color(hex:0xf6f0da),4)
        if state == .aim {g.strokeColor(Shape2.circle(corner,15),accent,3);g.strokeColor(Shape2.circle(corner,7),accent.opacity(0.6),1)}
        let progress=shot.map{CGFloat(clamp((elapsed-$0.started)/$0.speed,0,1))} ?? 0
        let dive=CGFloat(Ease.out(Double(clamp((progress-0.16)/0.84,0,1))))
        let kx=shot.map{lerp($0.keeperFrom,$0.keeperTo,dive)} ?? keeperIdle
        let lean=shot.map{clamp(($0.keeperTo-$0.keeperFrom)/n.width*80,-34,34)} ?? 0
        var keeper=g;keeper.translateBy(x:kx,y:n.maxY+3-sinv(Double(dive)*Double.pi)*14);keeper.rotate(by:.degrees(Double(lean*dive)))
        ArcadeArt.draw(&keeper,"piece_keeper",CGRect(x:-n.height*0.48,y:-n.height*0.85,width:n.height*0.96,height:n.height*0.85))
        if let f=trace.first, let end=trace.last, f.y-end.y>16 {
            let (dest,curve)=destination(trace)
            let preview=Shot(from:ballOrigin,to:dest,sideSpin:curve,speed:1,started:0,keeperFrom:0,keeperTo:0)
            for i in 1...12 {let t=CGFloat(i)/12;g.fillColor(Shape2.circle(position(preview,t),max(1.3,3.4-2*t)),.white.opacity(0.66))}
        }
        let bp=shot.map{position($0,progress)} ?? ballOrigin
        let r=lerp(23,8,progress)
        g.fillColor(Shape2.ellipse(P(bp.x,lerp(ballOrigin.y+17,n.maxY+4,progress)),r*1.05,r*0.23),.black.opacity(0.36))
        var ball=g
        ball.translateBy(x:bp.x,y:bp.y)
        ball.rotate(by:.radians(Double(progress)*7))
        ArcadeArt.draw(&ball, "piece_football", CGRect(x: -r, y: -r, width: 2*r, height: 2*r))
        hud(&g,left:"Голы",value:"\(goals) из 5",right:"Удар \(min(5,attempts+1))/5")
        if state == .aim {ink(&g,"Свайп от мяча · дуга задаёт подкрутку",P(width/2,height-29),13,.white,.semibold)}
    }

    override func playTurn(_ pilot: ArcadePilot) {
        guard state == .aim else { return }
        let side: CGFloat = pilot.random.chance(0.5) ? -1:1
        let pull = height*CGFloat(pilot.random.range(0.26,0.37))
        let angle = CGFloat(pilot.random.range(0.21,0.47)) + CGFloat(1-pilot.skill)*0.055
        let end = P(ballOrigin.x + side*pull*angle, ballOrigin.y-pull)
        let mid = P((ballOrigin.x+end.x)/2-side*CGFloat(pilot.random.range(15,60)),ballOrigin.y-pull/2)
        pilot.swipe(from:ballOrigin,through:mid,to:end)
        pilot.wait(pilot.random.range(2.0,3.2))
    }
}
