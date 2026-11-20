import SwiftUI

/// Финал: корона по дуге летит на голову победителю, какашка шлёпается на проигравшего.
/// Победителю — конфетти, Taptic и фанфары; проигравшему — грустный тромбон.
struct CeremonyView: View {
    let ceremony: Ceremony
    let done: () -> Void

    @State private var crownStage = 0
    @State private var poopStage = 0
    @State private var squish = false
    @State private var shown = false
    @State private var born = Date()

    private let gold = Color(hex: 0xefc767)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let gap = min(w * 0.5, 210)
            ZStack {
                background
                if ceremony.iWon { Confetti(born: born).allowsHitTesting(false) }
                VStack(spacing: 22) {
                    Spacer(minLength: 10)
                    Text(ceremony.iWon ? "ПОБЕДА" : "ПОРАЖЕНИЕ")
                        .font(Theme.display(ceremony.iWon ? 56 : 44))
                        .foregroundStyle(ceremony.iWon
                                         ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xfff1b8), gold, Color(hex: 0xc9952e)], startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(Color.white.opacity(0.85)))
                        .shadow(color: ceremony.iWon ? gold.opacity(0.6) : .clear, radius: 24)
                        .scaleEffect(shown ? 1 : 1.6)
                        .opacity(shown ? 1 : 0)
                    if ceremony.practice {
                        Text("тренировка")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    HStack(spacing: 0) {
                        player(name: ceremony.meName, face: ceremony.meFace, score: ceremony.myScore, winner: ceremony.iWon, gap: gap, left: true)
                        player(name: ceremony.opName, face: ceremony.opFace, score: ceremony.theirScore, winner: !ceremony.iWon, gap: gap, left: false)
                    }
                    .frame(width: gap * 2)
                    Text(ceremony.line)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 28)
                        .opacity(shown ? 1 : 0)
                    Spacer()
                    Button(ceremony.practice ? "В демо-комнату" : "В комнату") {
                        buzz("light")
                        done()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                }
            }
        }
        .onAppear(perform: run)
    }

    private var background: some View {
        ZStack {
            Color(hex: 0x09080b)
            RadialGradient(colors: [(ceremony.iWon ? gold : Color(hex: 0x6b4a2a)).opacity(0.45), .clear], center: .init(x: 0.5, y: 0.38), startRadius: 10, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    private func player(name: String, face: URL?, score: Int, winner: Bool, gap: CGFloat, left: Bool) -> some View {
        // корона прилетает: из-за спины проигравшего, если места поменялись, иначе сверху
        let fromX: CGFloat = ceremony.swap ? (left ? gap : -gap) : 0
        var crownOffset = CGSize(width: fromX, height: -190)
        var crownAngle: Double = -14
        var crownScale: CGFloat = 1
        if crownStage == 1 { crownOffset = CGSize(width: fromX / 2, height: -170); crownAngle = 200; crownScale = 1.6 }
        if crownStage >= 2 { crownOffset = .zero; crownAngle = 346; crownScale = 1 }
        var poopOffset: CGFloat = -420
        var poopScale = CGSize(width: 0.6, height: 0.6)
        if poopStage == 1 { poopOffset = 0; poopScale = CGSize(width: 1.18, height: 0.8) }
        if poopStage >= 2 { poopOffset = 0; poopScale = CGSize(width: 1, height: 1) }
        return VStack(spacing: 10) {
            ZStack(alignment: .top) {
                Face(url: face, name: name, size: 96, ring: winner ? gold : .white.opacity(0.2))
                    .scaleEffect(x: !winner && squish ? 1.08 : 1, y: !winner && squish ? 0.9 : 1, anchor: .bottom)
                if winner {
                    CrownGlyph(size: 70)
                        .rotationEffect(.degrees(crownAngle))
                        .scaleEffect(crownScale)
                        .offset(x: crownOffset.width + 12, y: crownOffset.height - 40)
                        .opacity(crownStage == 0 && ceremony.swap ? 0.85 : 1)
                } else {
                    Text("💩")
                        .font(.system(size: 52))
                        .scaleEffect(x: poopScale.width, y: poopScale.height, anchor: .bottom)
                        .rotationEffect(.degrees(poopStage == 0 ? -30 : -12))
                        .offset(x: 6, y: poopOffset - 44)
                        .opacity(poopStage == 0 ? 0 : 1)
                }
            }
            .frame(height: 140, alignment: .bottom)
            Text(name)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Text("\(score)")
                .font(Theme.display(34))
                .foregroundStyle(winner ? gold : .white)
                .monospacedDigit()
        }
        .frame(width: gap)
    }

    private func run() {
        born = Date()
        sfx("slam")
        buzz("heavy")
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { shown = true }
        if UIAccessibility.isReduceMotionEnabled {
            crownStage = 2
            poopStage = 2
        }
        after(0.6) { withAnimation(.easeInOut(duration: 0.75)) { crownStage = 1 } }
        after(1.35) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { crownStage = 2 }
            sfx("sparkle")
            buzz(ceremony.iWon ? "success" : "medium")
            if ceremony.iWon {
                sfx("victory")
                sfx("crowd", 0.8)
            }
        }
        after(1.9) { withAnimation(.easeIn(duration: 0.5)) { poopStage = 1 } }
        after(2.4) {
            sfx("poop")
            buzz(ceremony.iWon ? "light" : "heavy")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { poopStage = 2; squish = true }
        }
        after(2.75) { withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { squish = false } }
        if !ceremony.iWon { after(3.1) { sfx("sad") } }
    }

    private func after(_ s: Double, _ fn: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: fn)
    }
}

/// Конфетти победителю — 60 бумажек, падающих и кувыркающихся
struct Confetti: View {
    let born: Date
    private let colors = [Color(hex: 0xefc767), Color(hex: 0xfff3c8), Color(hex: 0xff5fae), Color(hex: 0x4cc9ff), Color(hex: 0x3ef08a)]
    private struct Bit { var x: Double; var d: Double; var s: Double; var sw: Double; var spin: Double }
    /// Один и тот же набор при каждой перерисовке, иначе бумажки прыгали бы
    private static let seeds: [Bit] = {
        var rnd = SeededRandom(seed: 20261120)
        var out: [Bit] = []
        for _ in 0..<60 {
            let x = rnd.next()
            let d = rnd.range(1.4, 2.2)
            let s = rnd.range(0.6, 1.4)
            let sw = rnd.range(-60, 60)
            let spin = rnd.range(2, 9)
            out.append(Bit(x: x, d: d, s: s, sw: sw, spin: spin))
        }
        return out
    }()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(born) - 1.5
            Canvas { g, size in
                guard t > 0 else { return }
                for (i, p) in Confetti.seeds.enumerated() {
                    let k = t / (p.d * 2.2)
                    if k > 1.2 { continue }
                    let y = -30 + CGFloat(k) * (size.height + 60)
                    let x = CGFloat(p.x) * size.width + CGFloat(sin(t * 2 + Double(i)) * p.sw)
                    var c = g
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(t * p.spin))
                    c.scaleBy(x: CGFloat(cos(t * p.spin * 0.7)), y: 1)
                    c.opacity = k > 0.9 ? max(0, (1.2 - k) / 0.3) : 1
                    c.fill(Path(CGRect(x: -4 * p.s, y: -2.5 * p.s, width: 8 * p.s, height: 5 * p.s)), with: .color(colors[i % colors.count]))
                }
            }
        }
        .ignoresSafeArea()
    }
}
