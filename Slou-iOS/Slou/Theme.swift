import SwiftUI
import UIKit

/// Цвета и шрифты «слоу». Всё чёрно-белое; круглый фирменный шрифт — только для заголовков и акцентов,
/// весь остальной текст — системный SF, как в родных приложениях айфона.
enum Theme {
    static let displayFontName = "SlouRounded-Black"

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(displayFontName, size: size, relativeTo: style)
    }

    /// Фон сайта (#141414) — одинаковый у заставки, у страницы и под ней, чтобы не было вспышек
    static let paper = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    static let paperUI = UIColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 1)
    /// Цвет букв логотипа на сайте (#f1eee7)
    static let ink = Color(red: 241 / 255, green: 238 / 255, blue: 231 / 255)
    static let background = Color.black
    static let surface = Color(white: 0.07)
    static let surface2 = Color(white: 0.11)
    static let surface3 = Color(white: 0.17)
    static let dim = Color(white: 0.56)
    static let line = Color.white.opacity(0.1)
    static let danger = Color(red: 1, green: 0.27, blue: 0.23)
}

// MARK: - Liquid Glass
// На iOS 26 — настоящее «жидкое стекло». На старых системах — матовое стекло с тонкой светлой гранью.

struct FallbackGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                    shape.stroke(Color.white.opacity(0.14), lineWidth: 0.75)
                }
            }
            .clipShape(shape)
    }
}

#if compiler(>=6.2)
extension View {
    @ViewBuilder
    func slouGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.modifier(FallbackGlass(shape: shape, tint: tint))
        }
    }
}

/// Группа стеклянных элементов: на iOS 26 они сливаются и перетекают друг в друга
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
#else
extension View {
    func slouGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        self.modifier(FallbackGlass(shape: shape, tint: tint))
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
#endif

// MARK: - Кнопки

/// Главное действие: белая капсула, чёрный текст
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(Color.white))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Второстепенное действие: стеклянная капсула
struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .contentShape(Capsule())
            .slouGlass(in: Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Круглая стеклянная кнопка с иконкой
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .slouGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Фон

/// Чёрный фон с двумя медленно плывущими мягкими пятнами света —
/// стеклу есть что преломлять, а экран остаётся спокойным
struct AmbientBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.addFilter(.blur(radius: min(size.width, size.height) * 0.16))
                let r = min(size.width, size.height) * 0.42
                let a = CGPoint(x: size.width * (0.28 + 0.1 * sin(t * 0.11)), y: size.height * (0.30 + 0.07 * cos(t * 0.09)))
                let b = CGPoint(x: size.width * (0.74 + 0.08 * cos(t * 0.13)), y: size.height * (0.62 + 0.08 * sin(t * 0.07)))
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.16)))
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - r * 0.8, y: b.y - r * 0.8, width: r * 1.6, height: r * 1.6)), with: .color(.white.opacity(0.11)))
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
