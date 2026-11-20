import SwiftUI

/// Арена битвы за корону во весь экран: сверху счёт и игроки, в центре — игра,
/// снизу — живой счёт соперника и «Сдаться» (нужно подержать).
struct ArenaView: View {
    @ObservedObject var arena: Arena

    var body: some View {
        let game = arena.game
        ZStack {
            ArenaBackdrop(color: game.color)
            VStack(spacing: 8) {
                ArenaHUD(arena: arena, game: game)
                TugMeter(me: arena.totalMe, op: arena.totalOp, color: game.color)
                    .padding(.horizontal, 6)
                stage(game)
                ArenaFooter(arena: arena)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
            if let c = arena.ceremony {
                CeremonyView(ceremony: c) { arena.close() }
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func stage(_ game: GameInfo) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return ZStack {
            Color.black
            if let host = arena.host {
                GameStageView(host: host)
                    .id(ObjectIdentifier(host))
            }
            CardLayer(arena: arena)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(game.color.opacity(0.4), lineWidth: 1))
        .shadow(color: game.color.opacity(0.25), radius: 24)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { arena.stageSize = geo.size }
                    .onChange(of: geo.size) { _, size in arena.stageSize = size }
            }
        }
    }
}

/// Фон арены: чёрный, со светом цвета текущей игры
struct ArenaBackdrop: View {
    let color: Color
    var body: some View {
        ZStack {
            Color(hex: 0x09080b)
            RadialGradient(colors: [color.opacity(0.35), color.opacity(0)], center: .top, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [color.opacity(0.18), .clear], center: .bottom, startRadius: 10, endRadius: 380)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: color.description)
    }
}

struct ArenaHUD: View {
    @ObservedObject var arena: Arena
    let game: GameInfo

    var body: some View {
        HStack(spacing: 8) {
            plate(name: arena.info.name.isEmpty ? "Ты" : arena.info.name, face: arena.info.meFace, total: arena.totalMe, king: arena.me == "host", leading: true)
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(arena.only == nil ? arena.g + 1 : 1)")
                        .font(Theme.display(22))
                        .contentTransition(.numericText())
                    Text(arena.only == nil ? "/10" : "/1")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(pip(i) == 2 ? game.color : pip(i) == 1 ? Color.white : Color.white.opacity(0.18))
                            .frame(width: pip(i) == 1 ? 16 : 8, height: 5)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: arena.r)
            }
            .frame(width: 58)
            plate(name: arena.info.peerName.isEmpty ? "Соперник" : arena.info.peerName, face: arena.info.peerFace, total: arena.totalOp, king: arena.op == "host", leading: false)
        }
        .foregroundStyle(.white)
    }

    /// 2 — раунд сыгран, 1 — идёт сейчас, 0 — впереди
    private func pip(_ i: Int) -> Int { i < arena.r ? 2 : i == arena.r ? 1 : 0 }

    private func plate(name: String, face: URL?, total: Int, king: Bool, leading: Bool) -> some View {
        let faceView = Face(url: face, name: name, size: 40, king: king, ring: king ? Color(hex: 0xefc767) : .white.opacity(0.2))
        let text = VStack(alignment: leading ? .leading : .trailing, spacing: 0) {
            Text(name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Text("\(total)")
                .font(Theme.display(24))
                .contentTransition(.numericText(value: Double(total)))
                .monospacedDigit()
        }
        return HStack(spacing: 8) {
            if leading {
                faceView
                text
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                text
                faceView
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .slouGlass(in: Capsule())
    }
}

/// Перевес по общему счёту
struct TugMeter: View {
    let me: Int
    let op: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let all = max(1, me + op)
            let k = me + op == 0 ? 0.5 : CGFloat(me) / CGFloat(all)
            HStack(spacing: 2) {
                Capsule().fill(color).frame(width: max(4, (geo.size.width - 2) * k))
                Capsule().fill(Color.white.opacity(0.22))
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.75), value: k)
        }
        .frame(height: 5)
    }
}

struct ArenaFooter: View {
    @ObservedObject var arena: Arena

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Face(url: arena.info.peerFace, name: arena.info.peerName.isEmpty ? "С" : arena.info.peerName, size: 26)
                Text(arena.oppLive.map { "\($0)" } ?? "—")
                    .font(arena.game.font.font(17))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: arena.oppLive)
                    .frame(minWidth: 30, alignment: .leading)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 36)
            .slouGlass(in: Capsule())
            Text(arena.note)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !arena.isOver {
                HoldButton(title: arena.bot ? "Выйти" : "Сдаться") { arena.forfeit() }
            }
        }
        .frame(height: 40)
    }
}

/// Надписи поверх игры: заставка, отсчёт, итог раунда, ожидание, подсчёт короны
struct CardLayer: View {
    @ObservedObject var arena: Arena

    var body: some View {
        ZStack {
            switch arena.card {
            case .clear:
                EmptyView()
            case .hello(let text):
                hello(text)
            case .intro(let g):
                PosterView(game: Arcade.games[g], label: arena.only == nil ? "ИГРА \(g + 1) ИЗ 10" : "ТРЕНИРОВКА")
                    .id("poster\(g)")
                    .transition(.asymmetric(insertion: .scale(scale: 1.08).combined(with: .opacity), removal: .opacity))
            case .count(let g, let r, let n):
                count(Arcade.games[g], r, n)
            case .waitOp(let pts):
                waitOp(pts)
            case .splash(let r, let a, let b):
                splash(r, a, b)
            case .sum(let g, let a, let b):
                sum(Arcade.games[g], a, b)
            case .tally(let a, let b):
                tally(a, b)
            case .broken(let text):
                broken(text)
            case .giving:
                plain {
                    CrownGlyph(size: 64).opacity(0.6)
                    Text("СДАЁМСЯ…").font(Theme.display(28)).foregroundStyle(.white)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: arena.card)
    }

    private func plain<Content: View>(dim: Double = 0.72, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(dim)
            VStack(spacing: 14) { content() }
                .padding(24)
        }
        .transition(.opacity)
    }

    private func hello(_ text: String) -> some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0xefc767).opacity(0.28), .black], center: .center, startRadius: 10, endRadius: 360)
            VStack(spacing: 14) {
                CrownGlyph(size: 86)
                Text("БИТВА ЗА КОРОНУ")
                    .font(Theme.display(30))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xfff1b8), Color(hex: 0xefc767)], startPoint: .top, endPoint: .bottom))
                    .multilineTextAlignment(.center)
                Text(arena.bot ? "тренировка с ботом" : "10 игр · по 3 раунда")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 8) {
                    Text(text).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                    WaitDots(color: .white)
                }
                .padding(.top, 8)
            }
        }
        .transition(.opacity)
    }

    private func count(_ game: GameInfo, _ r: Int, _ n: Int) -> some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 6) {
                Text("РАУНД \(r + 1)")
                    .font(game.font.font(16))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.75))
                Text("\(n)")
                    .font(game.font.font(150))
                    .foregroundStyle(game.color)
                    .shadow(color: game.color.opacity(0.7), radius: 30)
                    .contentTransition(.numericText(countsDown: true))
                    .id(n)
                    .transition(.scale(scale: 1.9).combined(with: .opacity))
                Spacer().frame(height: 18)
                Text(game.rule(r))
                    .font(game.font.font(17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.45)))
                    .padding(.horizontal, 22)
            }
        }
        .transition(.opacity)
    }

    private func waitOp(_ pts: Int) -> some View {
        plain(dim: 0.66) {
            Text("\(pts)")
                .font(Theme.display(96))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Text("Ждём соперника").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                WaitDots()
            }
        }
    }

    private func splash(_ r: Int, _ a: Int, _ b: Int) -> some View {
        let win = a > b, lose = a < b
        let tint = win ? arena.game.color : lose ? Color(hex: 0x6b6b78) : Color.white
        return ZStack {
            Color.black.opacity(0.62)
            RadialGradient(colors: [tint.opacity(0.45), .clear], center: .center, startRadius: 10, endRadius: 320)
            VStack(spacing: 8) {
                Text("РАУНД \(r + 1)")
                    .font(arena.game.font.font(15))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 14) {
                    Text("\(a)").foregroundStyle(win ? tint : .white)
                    Text(":").foregroundStyle(.white.opacity(0.35))
                    Text("\(b)").foregroundStyle(lose ? .white : .white.opacity(0.75))
                }
                .font(Theme.display(76))
                .monospacedDigit()
                Text(win ? "Раунд твой" : lose ? "Раунд соперника" : "Ничья")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func sum(_ game: GameInfo, _ a: Int, _ b: Int) -> some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 10) {
                Canvas { g, size in
                    let st = game.titleStyle(46, width: size.width * 0.9)
                    Lettering.draw(&g, game.title.uppercased(), at: P(size.width / 2, size.height / 2), st)
                }
                .frame(height: 90)
                HStack(spacing: 12) {
                    Text("+\(a)").foregroundStyle(game.color)
                    Text(":").foregroundStyle(.white.opacity(0.35))
                    Text("+\(b)").foregroundStyle(.white.opacity(0.8))
                }
                .font(Theme.display(52))
                .monospacedDigit()
                Text("за три раунда")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 20)
        }
        .transition(.opacity)
    }

    private func tally(_ a: Int, _ b: Int) -> some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0xefc767).opacity(0.3), .black], center: .center, startRadius: 10, endRadius: 360)
            VStack(spacing: 14) {
                CrownGlyph(size: 80)
                Text("СЧИТАЕМ КОРОНУ")
                    .font(Theme.display(26))
                    .foregroundStyle(Color(hex: 0xfff1b8))
                HStack(spacing: 12) {
                    Text("\(a)")
                    Text(":").foregroundStyle(.white.opacity(0.35))
                    Text("\(b)")
                }
                .font(Theme.display(54))
                .monospacedDigit()
                .foregroundStyle(.white)
                WaitDots(color: Color(hex: 0xefc767))
            }
        }
        .transition(.opacity)
    }

    private func broken(_ text: String) -> some View {
        plain(dim: 0.8) {
            CrownGlyph(size: 64).opacity(0.7)
            Text(text)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Закрыть") { arena.dismissBroken() }
                .buttonStyle(PrimaryButtonStyle(height: 50))
                .frame(maxWidth: 240)
        }
    }
}
