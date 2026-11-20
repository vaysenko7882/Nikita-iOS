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

/// Аркада: любая игра против бота, без сети. Открывается встряской телефона
struct ArcadeSheet: View {
    @ObservedObject var center: DuelCenter
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Аркада")
                            .font(Theme.display(38))
                        Text("Тренировка против бота — три раунда любой игры или все десять подряд")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    GlassIconButton(systemName: "xmark", size: 40) { dismiss() }
                }
                Button {
                    center.practice(nil)
                } label: {
                    HStack(spacing: 12) {
                        CrownGlyph(size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Битва за корону").font(.system(size: 17, weight: .bold, design: .rounded))
                            Text("10 игр · 30 раундов · бот").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.black.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 70)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LinearGradient(colors: [Color(hex: 0xfff1b8), Color(hex: 0xefc767)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                }
                .buttonStyle(.plain)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(Arcade.games.enumerated()), id: \.element.id) { i, game in
                        Button { center.practice(i) } label: { GameTile(game: game) }
                            .buttonStyle(TileButtonStyle())
                    }
                }
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .background(Color(hex: 0x09080b).ignoresSafeArea())
    }
}

struct GameTile: View {
    let game: GameInfo
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { g, size in
                PosterArt.draw(game.id, &g, size, 0.6)
                let st = game.titleStyle(min(size.width, size.height) * 0.26, width: size.width * 0.86)
                Lettering.draw(&g, game.title.uppercased(), at: P(size.width / 2, size.height * 0.46), st)
            }
            Text(game.rules[0])
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .aspectRatio(0.78, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(game.color.opacity(0.45), lineWidth: 1))
    }
}

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
