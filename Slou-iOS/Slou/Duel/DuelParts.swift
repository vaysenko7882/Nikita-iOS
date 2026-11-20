import SwiftUI

/// Корона «слоу» — та же, что на сайте, нарисована линиями
struct CrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 50, sy = rect.height / 34
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(3, 7))
        path.addLine(to: p(15, 14))
        path.addLine(to: p(25, 2))
        path.addLine(to: p(35, 14))
        path.addLine(to: p(47, 7))
        path.addLine(to: p(42, 30))
        path.addLine(to: p(8, 30))
        path.closeSubpath()
        return path
    }
}

struct CrownGlyph: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            CrownShape().fill(LinearGradient(colors: [Color(hex: 0xfff1b8), Color(hex: 0xefc767), Color(hex: 0xc9952e)], startPoint: .top, endPoint: .bottom))
            CrownShape().stroke(Color(hex: 0x211c18), style: StrokeStyle(lineWidth: max(1.5, size * 0.06), lineJoin: .round))
            Capsule().fill(Color(hex: 0x44331e)).frame(width: size * 0.56, height: max(1.5, size * 0.05)).offset(y: size * 0.2)
            Circle().fill(Color(hex: 0xfff3c8)).frame(width: size * 0.1, height: size * 0.1).offset(y: -size * 0.3)
        }
        .frame(width: size, height: size * 0.68)
        .shadow(color: Color(hex: 0xefc767).opacity(0.45), radius: size * 0.2)
    }
}

/// Портрет игрока с сервера; пока грузится — первая буква имени
struct Face: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44
    var king = false
    var ring: Color = .white.opacity(0.18)

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.16))
            Text(String(name.prefix(1)).uppercased())
                .font(Theme.display(size * 0.42))
                .foregroundStyle(.white.opacity(0.7))
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    Group {
                        if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring, lineWidth: max(1, size * 0.04)))
        .overlay(alignment: .top) {
            if king {
                CrownGlyph(size: size * 0.62)
                    .rotationEffect(.degrees(-12))
                    .offset(x: size * 0.18, y: -size * 0.36)
            }
        }
    }
}

/// Три бегущие точки «жду…»
struct WaitDots: View {
    var color: Color = .white
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let k = (sin(t * 6 - Double(i) * 0.9) + 1) / 2
                    Circle().fill(color.opacity(0.35 + 0.65 * k)).frame(width: 6, height: 6).offset(y: CGFloat(-3 * k))
                }
            }
        }
        .frame(height: 12)
    }
}

/// Кнопка, которую нужно подержать: случайно не сдашься
struct HoldButton: View {
    let title: String
    var seconds: Double = 0.9
    let action: () -> Void
    @State private var pressing = false
    @State private var progress: CGFloat = 0

    var body: some View {
        Text(pressing ? "Держи…" : title)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                GeometryReader { geo in
                    Capsule().fill(Theme.danger.opacity(0.85))
                        .frame(width: geo.size.width * progress)
                }
            }
            .slouGlass(in: Capsule(), interactive: true)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: seconds, maximumDistance: 40, perform: {
                buzz("heavy")
                action()
            }, onPressingChanged: { on in
                pressing = on
                if on {
                    buzz("light")
                    withAnimation(.linear(duration: seconds)) { progress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            })
            .accessibilityLabel(title)
            .accessibilityAction { action() }
    }
}
