import SwiftUI
import SafariServices
import UIKit

// MARK: Статус

/// Мягкая расходящаяся волна вокруг точки «в сети».
struct PulseHalo: View {
    var color: Color = Palette.onGlow
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .scaleEffect(animate ? 2.6 : 1)
            .opacity(animate ? 0 : 0.45)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

struct StatusDot: View {
    let state: String
    var size: CGFloat = 12
    var pulses = true

    var body: some View {
        ZStack {
            switch state {
            case "online":
                if pulses { PulseHalo() }
                Circle().fill(Palette.on)
            case "offline":
                Circle().fill(Palette.offDot)
            default:
                Circle().strokeBorder(Palette.ink3, style: StrokeStyle(lineWidth: max(1.5, size / 7), dash: [2.4, 2]))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Кольцо вокруг аватара: зелёное в сети, пунктир — статус неизвестен.
struct AvatarRing: View {
    let state: String

    var body: some View {
        switch state {
        case "online":
            Circle().stroke(Palette.on, lineWidth: 2.5)
        case "offline":
            Circle().stroke(Palette.offDot.opacity(0.45), lineWidth: 2.5)
        default:
            Circle().stroke(Palette.ink3, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
    }
}

struct InitialsAvatar: View {
    let name: String

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { word -> String? in
            guard let first = word.first else { return nil }
            return String(first).uppercased()
        }
        let joined = letters.joined()
        return joined.isEmpty ? "A" : joined
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(light: 0xFFB56E, dark: 0xFFB56E), Color(light: 0xFF7A55, dark: 0xFF7A55)],
                           startPoint: .top, endPoint: .bottom)
            Text(initials)
                .font(.rounded(20, .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct AvatarView: View {
    let profile: Profile?
    let url: URL?

    var body: some View {
        ZStack {
            InitialsAvatar(name: profile?.name ?? "")
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .clipShape(Circle())
    }
}

// MARK: Общие элементы

struct SectionHeader: View {
    let title: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.rounded(26))
                .tracking(-0.5)
                .foregroundStyle(Palette.ink)
            if let note {
                Text(note)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }
}

struct FactChip: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.rounded(15))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Palette.panel, in: Capsule())
        .fixedSize()
    }
}

struct NoticeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Palette.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.page)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Palette.ink, in: Capsule())
            .padding(.horizontal, 24)
    }
}

struct PanelButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Переписка

/// Пузырь исходящего сообщения с хвостиком, как в Telegram.
struct BubbleShape: Shape {
    var radius: CGFloat = 18
    var tail: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - tail, height: rect.height)
        let r = min(radius, body.height / 2, body.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + r), control: CGPoint(x: body.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - 14))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: body.maxY), control: CGPoint(x: body.maxX + 1, y: body.maxY - 3))
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - r), control: CGPoint(x: body.minX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addQuadCurve(to: CGPoint(x: body.minX + r, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
        path.closeSubpath()
        return path
    }
}

/// «Печатает…» — три точки. Анимацию ведёт система, без пересчёта экрана на каждый кадр.
struct TypingDots: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 4.5, height: 4.5)
                    .opacity(animate ? 1 : 0.3)
                    .offset(y: animate ? -2 : 0)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

/// Обои чата: мягкий цвет и редкая точечная сетка. Рисуются один раз.
struct ChatWallpaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.chatBG))
            var dots = Path()
            let step: CGFloat = 18
            var y: CGFloat = 9
            while y < size.height {
                var x: CGFloat = 9
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(Palette.chatDot))
        }
    }
}

struct ServicePill: View {
    let text: String
    var bold = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: bold ? .semibold : .regular))
            .foregroundStyle(Palette.pillInk)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Palette.pill, in: Capsule())
    }
}

// MARK: UIKit-обёртки

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
