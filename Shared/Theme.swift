import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// Цвет, который сам переключается между светлой и тёмной темой.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Палитра из веб-версии: один зелёный для «в сети», остальное — нейтральное.
enum Palette {
    static let page = Color(light: 0xFFFFFF, dark: 0x000000)
    static let panel = Color(light: 0xF4F4F6, dark: 0x151517)
    static let panel2 = Color(light: 0xEAEAEE, dark: 0x222226)
    static let ink = Color(light: 0x161618, dark: 0xF5F5F7)
    static let ink2 = Color(light: 0x6B6B73, dark: 0x9B9BA3)
    static let ink3 = Color(light: 0xA9A9B1, dark: 0x5E5E66)
    static let hair = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.085)

    static let on = Color(light: 0x19A653, dark: 0x30D158)
    static let onGlow = Color(light: 0x34C759, dark: 0x30D158)
    static let onSoft = Color(light: 0xE8F7EC, dark: 0x0E2516)
    static let off = Color(light: 0xE7E7EC, dark: 0x2C2C31)
    static let offDot = Color(light: 0xA9A9B1, dark: 0x6A6A72)
    static let future = Color(light: 0xF4F4F6, dark: 0x151517)
    static let warn = Color(light: 0xE39A00, dark: 0xF2AA22)

    static let chatBG = Color(light: 0xE8EEE4, dark: 0x0B110D)
    static let chatDot = Color(light: 0x284628, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.05)
    static let bubble = Color(light: 0xDAF6CC, dark: 0x1C4627)
    static let bubbleMeta = Color(light: 0x2E7A42, dark: 0x8AD7A0)
    static let pill = Color(light: 0x1C281C, dark: 0xFFFFFF, lightAlpha: 0.085, darkAlpha: 0.085)
    static let pillInk = Color(light: 0x4F5A52, dark: 0xAAB4AD)

    static func state(_ state: String) -> Color {
        switch state {
        case "online": return on
        case "offline": return offDot
        default: return ink3
        }
    }
}

extension Font {
    /// Скруглённый SF — для цифр и заголовков.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
