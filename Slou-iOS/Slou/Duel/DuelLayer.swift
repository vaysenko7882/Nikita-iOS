import SwiftUI

/// Слой поверх страницы: вызов, ожидание ответа, сообщения, арена и финал
struct DuelLayer: View {
    @ObservedObject var center: DuelCenter

    var body: some View {
        ZStack {
            if let req = center.ask {
                AskCard(request: req, myFace: center.myFace, answer: { center.answer($0) })
                    .transition(.opacity)
                    .zIndex(2)
            }
            if let arena = center.arena {
                ArenaView(arena: arena)
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
                    .zIndex(3)
            }
            if let c = center.ceremony {
                CeremonyView(ceremony: c) { center.closeCeremony() }
                    .transition(.opacity)
                    .zIndex(4)
            }
            VStack(spacing: 8) {
                if let start = center.waiting {
                    WaitingBanner(start: start)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let t = center.toast {
                    ToastView(toast: t) { center.toast = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.horizontal, 14)
            .zIndex(6)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: center.toast?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: center.waiting)
    }
}

/// Гость бросил вызов и ждёт ответа короля
struct WaitingBanner: View {
    let start: Date

    var body: some View {
        HStack(spacing: 12) {
            CrownGlyph(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Вызов брошен")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text("Ждём ответа короля")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                    WaitDots(color: Color(hex: 0xefc767))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(alignment: .bottomLeading) {
            TimelineView(.animation(minimumInterval: 0.25)) { tl in
                let k = max(0, 1 - tl.date.timeIntervalSince(start) / 90)
                GeometryReader { geo in
                    Capsule().fill(Color(hex: 0xefc767)).frame(width: geo.size.width * k, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
        }
        .slouGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: 460)
    }
}

struct ToastView: View {
    let toast: Toast
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CrownGlyph(size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                if !toast.detail.isEmpty {
                    Text(toast.detail)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer(minLength: 0)
            if let action = toast.action {
                Button(action) {
                    toast.run?()
                    close()
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(.white))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .slouGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: 460)
        .onTapGesture { if toast.action == nil { close() } }
    }
}

/// Создателю комнаты: гость требует корону
struct AskCard: View {
    let request: AskRequest
    let myFace: URL?
    let answer: (Bool) -> Void
    @State private var sent = false
    @State private var appear = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    Face(url: myFace, name: "Я", size: 78, king: true, ring: Color(hex: 0xefc767))
                    Text("VS")
                        .font(Theme.display(34))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0xfff1b8), Color(hex: 0xefc767)], startPoint: .top, endPoint: .bottom))
                        .scaleEffect(appear ? 1 : 2.2)
                        .rotationEffect(.degrees(appear ? -6 : 20))
                    Face(url: request.face, name: request.name, size: 78)
                }
                .padding(.top, 14)
                Text("\(request.name) требует корону")
                    .font(Theme.display(26))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text("10 игр по 3 раунда. Выиграет — заберёт корону и пульт, а тебе достанется 💩. Проиграет — 💩 ему.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    Button("Принять бой") { send(true) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Не сегодня") { send(false) }
                        .buttonStyle(GlassButtonStyle(height: 50))
                }
                .disabled(sent)
                .opacity(sent ? 0.6 : 1)
                TimelineView(.animation(minimumInterval: 0.25)) { tl in
                    let k = max(0, min(1, request.deadline.timeIntervalSince(tl.date) / 85))
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color(hex: 0xefc767)).frame(width: geo.size.width * k)
                    }
                    .frame(height: 3)
                }
            }
            .padding(22)
            .slouGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: 520)
            .offset(y: appear ? 0 : 420)
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { appear = true } }
    }

    private func send(_ yes: Bool) {
        guard !sent else { return }
        sent = true
        answer(yes)
    }
}

struct DemoRoomView: View {
    @ObservedObject var center: DuelCenter
    @State private var preview: GameInfo?
    @State private var queuedGame: Int?
    private let columns = [GridItem(.adaptive(minimum:145, maximum:278),spacing:12)]
    private let surface = Color(hex:0x131615)

    var body:some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:3){
                    Text("Демо-комната").font(.system(size:32,weight:.bold)).tracking(-1.2).accessibilityAddTraits(.isHeader)
                    Label(DuelCenter.demoOpponentName,systemImage:"cpu").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action:center.leaveDemoRoom) {
                    Image(systemName:"xmark").font(.system(size:16,weight:.semibold)).frame(width:44,height:44)
                        .background(.white.opacity(0.085),in:Circle())
                }.buttonStyle(.plain).accessibilityLabel("Выйти из демо-комнаты").accessibilityIdentifier("demo.close")
            }.padding(.horizontal,20).padding(.vertical,10)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if let race=Arcade.games.first(where:{$0.id=="race"}) {
                        Button {preview=race} label:{
                            ZStack(alignment:.bottomLeading){
                                ArcadeCover(id:race.id)
                                LinearGradient(colors:[.clear,.clear,.black.opacity(0.82)],startPoint:.top,endPoint:.bottom)
                                HStack(alignment:.bottom) {
                                    VStack(alignment:.leading,spacing:3){
                                        Text("Гонка").font(.subheadline.weight(.medium))
                                        Text(race.edition).font(.system(size:35,weight:.bold)).tracking(-1.2)
                                    }
                                    Spacer()
                                    Image(systemName:"play.fill").font(.body).foregroundStyle(.black).frame(width:43,height:43).background(.white,in:Circle())
                                }.padding(16)
                            }.frame(maxWidth:.infinity).aspectRatio(1.53,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:19)).contentShape(Rectangle())
                        }.buttonStyle(TileButtonStyle()).accessibilityLabel("Гонка, Серпантины").accessibilityIdentifier("demo.game.race")
                    }
                    Button {center.practice()} label:{
                        HStack(spacing:13){
                            Image(systemName:"crown.fill").foregroundStyle(Color(hex:0xead28d)).font(.title3)
                            VStack(alignment:.leading,spacing:3){Text("Битва за корону").font(.headline);Text("10 игр подряд · 30 раундов").font(.subheadline).foregroundStyle(.secondary)}
                            Spacer();Image(systemName:"chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }.padding(15).frame(maxWidth:.infinity).background(surface,in:RoundedRectangle(cornerRadius:15)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("demo.tournament")
                    Text("Выбрать игру").font(.title2.weight(.bold)).tracking(-0.6)
                    LazyVGrid(columns:columns,alignment:.leading,spacing:20) {
                        ForEach(Arcade.games.filter{$0.id != "race"}) {game in
                            Button {preview=game} label:{GameTile(game:game)}
                                .buttonStyle(TileButtonStyle()).accessibilityLabel("\(game.title), \(game.edition)")
                                .accessibilityIdentifier("demo.game."+game.id)
                        }
                    }
                }.padding(.horizontal,18).padding(.top,4).padding(.bottom,28)
            }.accessibilityIdentifier("demo.games")
        }
        .frame(maxWidth:700).frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(Color(hex:0x090c0b).ignoresSafeArea()).foregroundStyle(.white)
        .accessibilityElement(children:.contain)
        .accessibilityAction(.escape){center.leaveDemoRoom()}
        .sheet(item:$preview,onDismiss:{
            if let index=queuedGame {queuedGame=nil;center.practice(index)}
        }){game in
            ArcadeBriefing(game:game){
                queuedGame=Arcade.games.firstIndex(where:{$0.id==game.id});preview=nil
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }
}

struct GameTile:View {
    let game:GameInfo
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            ArcadeCover(id:game.id).aspectRatio(1.13,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:13))
            Text(game.title).font(.caption.weight(.semibold)).foregroundStyle(game.color).padding(.top,2)
            Text(game.edition).font(.system(size:19,weight:.semibold)).tracking(-0.45).lineLimit(2)
        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
    }
}

private struct ArcadeBriefing:View {
    let game:GameInfo
    let play:()->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0){
            ScrollView{
                VStack(alignment:.leading,spacing:16){
                    ZStack(alignment:.topTrailing){
                        ArcadeCover(id:game.id).aspectRatio(1.14,contentMode:.fit)
                        Button{dismiss()}label:{Image(systemName:"xmark").frame(width:42,height:42).background(.black.opacity(0.6),in:Circle())}
                            .padding(16).accessibilityLabel("Закрыть")
                    }
                    VStack(alignment:.leading,spacing:10){
                        Text(game.title).font(.headline).foregroundStyle(game.color)
                        Text(game.edition).font(.system(size:38,weight:.bold)).tracking(-1.3)
                        Text("3 раунда  ·  до \(Int(game.practiceDuration)) с каждый").font(.subheadline).foregroundStyle(.secondary)
                        Divider().padding(.vertical,4)
                        Text("Управление").font(.title3.weight(.semibold))
                        ForEach(game.rules,id:\.self){rule in Text(rule).font(.body).fixedSize(horizontal:false,vertical:true)}
                        let best=UserDefaults.standard.integer(forKey:"slou.arcade.record."+game.id)
                        if best>0 {Label("Личный рекорд  \(best) / 300",systemImage:"laurel.leading").font(.callout.weight(.semibold)).foregroundStyle(game.color)}
                    }.padding(.horizontal,22)
                }.padding(.bottom,22)
            }
            Button(action:play){Label("Играть с ботом",systemImage:"play.fill").font(.headline).frame(maxWidth:.infinity,minHeight:52).background(game.color,in:RoundedRectangle(cornerRadius:15)).foregroundStyle(.black)}
                .buttonStyle(.plain).padding(.horizontal,20).padding(.vertical,9).accessibilityIdentifier("demo.play")
        }.background(Color(hex:0x101412).ignoresSafeArea()).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.975:1)
            .animation(.easeOut(duration:0.15),value:configuration.isPressed)
    }
}
