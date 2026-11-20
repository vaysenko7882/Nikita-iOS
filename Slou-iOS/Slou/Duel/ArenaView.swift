import SwiftUI

struct ArenaView:View {
    @ObservedObject var arena:Arena
    var body:some View {
        ZStack {
            Color(hex:0x0c100f).ignoresSafeArea()
            VStack(spacing:0){
                HStack(spacing:12){
                    VStack(alignment:.leading,spacing:2){
                        Text(arena.game.edition).font(.system(size:21,weight:.bold)).tracking(-0.6).lineLimit(1)
                        Text(arena.only==nil ? "Игра \(arena.g+1) из 10":"\(arena.game.title) · матч").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment:.trailing,spacing:5){
                        Text("Раунд \(arena.r+1)/3").font(.caption.weight(.semibold)).monospacedDigit()
                        HStack(spacing:3){ForEach(0..<3,id:\.self){i in Capsule().fill(i<=arena.r ? arena.game.color:.white.opacity(0.19)).frame(width:15,height:3)}}
                    }.accessibilityElement(children:.ignore)
                        .accessibilityLabel("\(arena.game.title), игра \(arena.only == nil ? arena.g+1:1) из \(arena.only == nil ? 10:1), раунд \(arena.r+1) из 3")
                        .accessibilityIdentifier("arena.progress")
                }.padding(.horizontal,16).padding(.vertical,6)
                ZStack {
                    Color.black
                    if let host=arena.host {GameStageView(host:host).id(ObjectIdentifier(host))}
                    CardLayer(arena:arena)
                }.clipped()
                .background {GeometryReader{geo in Color.clear.onAppear{arena.stageSize=geo.size}.onChange(of:geo.size){_,size in arena.stageSize=size}}}
                HStack(spacing:7){
                    Image(systemName:arena.bot ? "cpu":"person.fill").foregroundStyle(arena.game.color)
                    Text(arena.info.peerName.isEmpty ? "Соперник":arena.info.peerName).font(.subheadline)
                    Text(arena.oppLive.map(String.init) ?? "—").font(.subheadline.bold()).monospacedDigit().accessibilityIdentifier("arena.opponent.score")
                    if !arena.note.isEmpty {Text(arena.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)}
                    Spacer()
                    if !arena.isOver {
                        if arena.bot {Button("В комнату"){arena.close()}.font(.subheadline.weight(.semibold)).frame(minHeight:42).accessibilityIdentifier("arena.back")}
                        else {HoldButton(title:"Сдаться"){arena.forfeit()}}
                    }
                }.padding(.horizontal,16).frame(minHeight:44)
            }.accessibilityElement(children:.contain).accessibilityHidden(arena.ceremony != nil)
            if let result=arena.ceremony {
                CeremonyView(ceremony:result){arena.close()}.transition(.opacity)
            }
        }.foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

struct CardLayer:View {
    @ObservedObject var arena:Arena
    var body:some View {
        ZStack {
            switch arena.card {
            case .clear:EmptyView()
            case .intro(let i):
                PosterView(game:Arcade.games[i],label:arena.only == nil ? "Игра \(i+1) из 10":"Матч с ботом")
            case .hello(let status):
                PosterView(game:arena.game,label:status)
            case .count(let i,let r,let n):
                Color.black.opacity(0.46)
                VStack(spacing:7){
                    Text("Раунд \(r+1)").font(.headline)
                    Text("\(n)").font(.system(size:94,weight:.medium)).monospacedDigit().contentTransition(.numericText(countsDown:true))
                    Text(Arcade.games[i].rule(r)).font(.subheadline.weight(.medium)).multilineTextAlignment(.center).frame(maxWidth:340)
                }.padding(.horizontal,22)
            case .waitOp(let n):panel("Ждём соперника","\(n) очк.")
            case .splash(let r,let a,let b):panel("Раунд \(r+1) завершён","\(a)  :  \(b)")
            case .sum(let i,let a,let b):panel(Arcade.games[i].edition,"\(a)  :  \(b)")
            case .tally(let a,let b):panel("Итог матча","\(a)  :  \(b)")
            case .giving:panel("Сдача матча","…")
            case .broken(let text):
                Color.black.opacity(0.88)
                VStack(spacing:18){Text(text).multilineTextAlignment(.center);Button("Закрыть"){arena.dismissBroken()}.buttonStyle(.borderedProminent)}.padding()
            }
        }.foregroundStyle(.white).animation(.easeOut(duration:0.18),value:arena.card)
    }
    private func panel(_ title:String,_ score:String)->some View {
        ZStack{
            Color.black.opacity(0.65)
            VStack(spacing:9){Text(title).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                Text(score).font(.system(size:49,weight:.semibold)).monospacedDigit().minimumScaleFactor(0.65)}
        }
    }
}
