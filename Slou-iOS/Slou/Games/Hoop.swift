import SwiftUI

/// The shot uses a ballistic arc. Glass and rim contacts change the same velocity vector.
final class HoopGame: StudioGame {
    override var fieldID:String {"hoop"}
    override var accent:Color {Color(hex:0xffb17d)}
    private(set) var points=0
    private(set) var streak=0
    private var ball=CGPoint.zero,vel=CGVector.zero,rot=0.0
    private var flying=false,banked=false,scored=false,ballAge=0.0,netAt = -3.0,lastRim = -3.0
    private var aim:(id:Int,start:CGPoint,end:CGPoint)?,offset:CGFloat=0, shots=0
    private let gravity:CGFloat=850
    private var origin:CGPoint{P(width*(0.5+offset),height*0.80)}
    private var hoop:CGPoint{P(width*(0.5+CGFloat(R)*0.065*sinv(elapsed*(0.72+roundScale*0.17))),height*0.355)}
    private var rim:CGFloat{min(39,width*0.105)}
    override func begin(){ball=origin}
    override func score()->Int{min(100,points)}
    private func launchVector(_ a:CGPoint,_ b:CGPoint)->CGVector {
        // Vertical throw distance determines apex; horizontal movement aims the throw.
        let pull=max(0,a.y-b.y),wanted=clamp(pull/(height*0.24),0.12,1.95)
        let rise=(origin.y-hoop.y)*(0.66+0.54*wanted)
        let vy = -sqrt(2*gravity*rise)
        let crossing = (-vy+sqrt(max(1,vy*vy-2*gravity*(origin.y-hoop.y))))/gravity
        let destination=origin.x+(b.x-a.x)*2.4
        return CGVector(dx:(destination-origin.x)/max(0.45,crossing),dy:vy)
    }
    override func handle(_ phase:TouchEvent.Phase,id:Int,p:CGPoint,time:Double){
        guard !flying else{return}
        switch phase{
        case .began:if aim==nil && p.y>height*0.50 {aim=(id,p,p)}
        case .moved:if aim?.id==id {aim?.end=p}
        case .ended:
            guard let a=aim,a.id==id else{return};aim=nil
            guard a.start.y-p.y>22 else{return}
            vel=launchVector(a.start,p);ball=origin;flying=true;banked=false;scored=false;ballAge=0;shots+=1;sfx("whoosh",0.59);buzz("light")
        case .cancelled:aim=nil
        }
    }
    override func simulate(_ dt:Double) {
        guard flying else{ball=origin;return}
        let old=ball,ring=hoop
        vel.dy+=gravity*dt;ball.x+=vel.dx*dt;ball.y+=vel.dy*dt;rot+=dt*(3+Double(vel.dx)/40);ballAge+=dt
        // Glass occupies the raised outer areas of the backboard. A descending bank redirects toward the rim.
        if !banked,vel.dy>0,old.y<ring.y-36,ball.y>=ring.y-36,abs(ball.x-ring.x)>rim*0.48,abs(ball.x-ring.x)<rim*1.58 {
            banked=true;vel.dx=(ring.x-ball.x)*3.4;vel.dy=max(53,vel.dy*0.55);sfx("bounce",0.53);buzz("light")
        }
        let rx=ball.x-ring.x
        if !scored,vel.dy>0,old.y<=ring.y,ball.y>=ring.y {
            if abs(rx)<rim-8 {scored=true;streak+=1;let gain=(banked ? 13:15)+(streak>=3 ? 6:0);points+=gain;netAt=elapsed
                sfx("swish");buzz("success");toast(banked ? "От щита +\(gain)":"Чисто +\(gain)",color:accent)
            }else if abs(abs(rx)-rim)<11 && elapsed-lastRim>0.18 {
                lastRim=elapsed;vel.dy = -max(65,abs(vel.dy)*0.34);vel.dx+=(rx>0 ? 1:-1)*47;sfx("rim",0.65)
            }
        }
        if ball.y>height+35 || ball.x < -40 || ball.x>width+40 || ballAge>3.3 {
            if !scored{streak=0};flying=false;offset=CGFloat([0.0,-0.13,0.13,-0.20,0.18][shots%5]);ball=origin
        }
    }
    private func drawBall(_ g:inout GraphicsContext,p:CGPoint,r:CGFloat){
        var a=g;a.translateBy(x:p.x,y:p.y);a.rotate(by:.radians(rot))
        let shape=Shape2.circle(.zero,r)
        a.fill(shape,with:radial(G([(0,Color(hex:0xf7b57d)),(0.45,Color(hex:0xd47840)),(1,Color(hex:0x713a28))]),P(-r*0.39,-r*0.49),0,r*1.6));a.clip(to:shape)
        a.strokeColor(Shape2.ellipse(P(-r*0.54,0),r*0.50,r*1.04),Color(hex:0x372922),1.8)
        a.strokeColor(Shape2.ellipse(P(r*0.54,0),r*0.50,r*1.04),Color(hex:0x372922),1.8)
        strokeLine(&a,[P(-r,0),P(r,0)],Color(hex:0x372922),1.7)
    }
    override func render(_ g:inout GraphicsContext){
        let p=hoop
        let board=CGRect(x:p.x-rim*1.78,y:p.y-76,width:rim*3.56,height:75)
        g.fillColor(Path(roundedRect:board,cornerRadius:4),Color(hex:0xbad9d9,alpha:0.32))
        g.strokeColor(Path(roundedRect:board,cornerRadius:4),.white.opacity(0.86),3)
        g.strokeColor(Shape2.rect(p.x-22,p.y-42,44,29),.white.opacity(0.87),2)
        let stretch=max(0,1-(elapsed-netAt)/0.53)*12*sin((elapsed-netAt)*15)
        let bottom=P(p.x,p.y+42+CGFloat(stretch))
        for i in 0...8 {
            let x = -rim+2*rim*CGFloat(i)/8
            strokeLine(&g,[P(p.x+x,p.y),P(bottom.x+x*0.49+5,bottom.y)],.white.opacity(0.84),1.25)
            strokeLine(&g,[P(p.x+x,p.y),P(bottom.x+x*0.49-5,bottom.y)],.white.opacity(0.78),1.25)
        }
        g.strokeColor(Shape2.ellipse(p,rim,5),Color(hex:0xb75a36),5)
        if let a=aim,a.start.y-a.end.y>12 {
            let v=launchVector(a.start,a.end)
            for i in 1...13 {let t=CGFloat(i)*0.052;let q=P(origin.x+v.dx*t,origin.y+v.dy*t+gravity*t*t/2);g.fillColor(Shape2.circle(q,2.4),.white.opacity(0.90-Double(i)*0.045))}
        }
        let depth=clamp((origin.y-ball.y)/max(100,origin.y-p.y),0,1)
        drawBall(&g,p:ball,r:lerp(24,10,depth))
        if scored && ball.y<p.y+32 {g.strokeColor(Shape2.ellipseArc(p,rim,5,0,Double.pi),Color(hex:0xef8a4c),4)}
        hud(&g,left:"Дворовая лига",value:"\(points) очков",right:"Серия \(streak)")
        shade(&g,at:height-77,height:77,top:0,bottom:0.52)
        ink(&g,"Свайпни вверх · длина задаёт высоту",P(width/2,height-28),13)
    }
}
