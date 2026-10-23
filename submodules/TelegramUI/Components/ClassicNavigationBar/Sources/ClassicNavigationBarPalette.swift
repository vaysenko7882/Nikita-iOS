import Foundation
import UIKit
import Display

public struct ClassicNavigationBarPalette: Equatable {
    public var overallDarkAppearance: Bool
    public var primaryTextColor: UIColor
    public var glassButtonColor: UIColor

    public var buttonColor: UIColor
    public var disabledButtonColor: UIColor
    public var backgroundColor: UIColor
    public var separatorColor: UIColor
    public var badgeBackgroundColor: UIColor
    public var badgeTextColor: UIColor

    public init(overallDarkAppearance: Bool, primaryTextColor: UIColor, glassButtonColor: UIColor, buttonColor: UIColor, disabledButtonColor: UIColor, backgroundColor: UIColor, separatorColor: UIColor, badgeBackgroundColor: UIColor, badgeTextColor: UIColor) {
        self.overallDarkAppearance = overallDarkAppearance
        self.primaryTextColor = primaryTextColor
        self.glassButtonColor = glassButtonColor
        self.buttonColor = buttonColor
        self.disabledButtonColor = disabledButtonColor
        self.backgroundColor = backgroundColor
        self.separatorColor = separatorColor
        self.badgeBackgroundColor = badgeBackgroundColor
        self.badgeTextColor = badgeTextColor
    }

    func matches(_ theme: NavigationBarTheme) -> Bool {
        if ClassicNavigationBarPalette.isScreenOwnTheme(theme) {
            return false
        }
        return self.overallDarkAppearance == theme.overallDarkAppearance && self.primaryTextColor.argb == theme.primaryTextColor.argb && self.glassButtonColor.argb == theme.buttonColor.argb
    }

    private static func isScreenOwnTheme(_ theme: NavigationBarTheme) -> Bool {
        let hasClearBadge = theme.badgeBackgroundColor.argb == UIColor.clear.argb
        let hasWhiteButtons = theme.buttonColor.argb == UIColor.white.argb
        let isBuiltFromAppTheme = theme.disabledButtonColor.argb == theme.buttonColor.withMultipliedAlpha(0.5).argb
        return hasClearBadge && hasWhiteButtons && !isBuiltFromAppTheme
    }

    public static func ==(lhs: ClassicNavigationBarPalette, rhs: ClassicNavigationBarPalette) -> Bool {
        if lhs.overallDarkAppearance != rhs.overallDarkAppearance {
            return false
        }
        let lhsColors: [UIColor] = [lhs.primaryTextColor, lhs.glassButtonColor, lhs.buttonColor, lhs.disabledButtonColor, lhs.backgroundColor, lhs.separatorColor, lhs.badgeBackgroundColor, lhs.badgeTextColor]
        let rhsColors: [UIColor] = [rhs.primaryTextColor, rhs.glassButtonColor, rhs.buttonColor, rhs.disabledButtonColor, rhs.backgroundColor, rhs.separatorColor, rhs.badgeBackgroundColor, rhs.badgeTextColor]
        return lhsColors.map(\.argb) == rhsColors.map(\.argb)
    }
}

public final class ClassicNavigationBarPaletteSource {
    public static let shared = ClassicNavigationBarPaletteSource()

    private let lock = NSLock()
    private var palettes: [ClassicNavigationBarPalette] = []
    private let bars = NSHashTable<ClassicNavigationBarImpl>.weakObjects()

    private init() {
    }

    public func update(palette: ClassicNavigationBarPalette) {
        assert(Thread.isMainThread)
        self.lock.lock()
        if self.palettes.first == palette {
            self.lock.unlock()
            return
        }
        self.palettes.removeAll(where: { $0 == palette })
        self.palettes.insert(palette, at: 0)
        if self.palettes.count > 4 {
            self.palettes.removeLast(self.palettes.count - 4)
        }
        let bars = self.bars.allObjects
        self.lock.unlock()

        for bar in bars {
            bar.paletteSourceUpdated()
        }
    }

    func palette(matching theme: NavigationBarTheme) -> ClassicNavigationBarPalette? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        for palette in self.palettes {
            if palette.matches(theme) {
                return palette
            }
        }
        return nil
    }

    func register(_ bar: ClassicNavigationBarImpl) {
        self.lock.lock()
        self.bars.add(bar)
        self.lock.unlock()
    }
}

struct ClassicNavigationBarColors: Equatable {
    var buttonColor: UIColor
    var disabledButtonColor: UIColor
    var primaryTextColor: UIColor
    var backgroundColor: UIColor?
    var separatorColor: UIColor
    var enableBlur: Bool
    var badgeBackgroundColor: UIColor
    var badgeTextColor: UIColor

    init(theme: NavigationBarTheme, palette: ClassicNavigationBarPalette?) {
        var hidesBackground = false
        if let edgeEffectColor = theme.edgeEffectColor, edgeEffectColor.alpha == 0.0 {
            hidesBackground = true
        }
        let hidesBadge = theme.badgeBackgroundColor.alpha == 0.0

        self.primaryTextColor = theme.primaryTextColor
        if let palette {
            self.buttonColor = palette.buttonColor
            self.disabledButtonColor = palette.disabledButtonColor
            self.backgroundColor = hidesBackground ? nil : palette.backgroundColor
            self.separatorColor = hidesBackground ? .clear : palette.separatorColor
            self.enableBlur = !hidesBackground && palette.backgroundColor.alpha < 1.0
            self.badgeBackgroundColor = hidesBadge ? .clear : palette.badgeBackgroundColor
            self.badgeTextColor = hidesBadge ? .clear : palette.badgeTextColor
        } else {
            if theme.disabledButtonColor.argb == theme.buttonColor.withMultipliedAlpha(0.5).argb {
                self.buttonColor = theme.accentButtonColor
                self.disabledButtonColor = theme.accentButtonColor.withMultipliedAlpha(0.5)
            } else {
                self.buttonColor = theme.buttonColor
                self.disabledButtonColor = theme.disabledButtonColor
            }
            if hidesBackground {
                self.backgroundColor = nil
                self.separatorColor = .clear
                self.enableBlur = false
            } else if let edgeEffectColor = theme.edgeEffectColor, theme.overallDarkAppearance, edgeEffectColor.alpha < 1.0, edgeEffectColor.argb & 0x00ffffff == 0 {
                self.backgroundColor = edgeEffectColor
                self.separatorColor = UIColor(white: 0.0, alpha: 0.8)
                self.enableBlur = false
            } else {
                let backgroundColor = theme.edgeEffectColor ?? (theme.overallDarkAppearance ? UIColor(rgb: 0x1c1c1d) : UIColor(rgb: 0xf7f7f7))
                let resolvedBackgroundColor = backgroundColor.alpha < 1.0 ? backgroundColor : backgroundColor.withAlphaComponent(0.94)
                self.backgroundColor = resolvedBackgroundColor
                self.separatorColor = theme.overallDarkAppearance ? UIColor(white: 1.0, alpha: 0.12) : UIColor(rgb: 0xc8c7cc)
                self.enableBlur = resolvedBackgroundColor.alpha < 1.0
            }
            self.badgeBackgroundColor = theme.badgeBackgroundColor
            self.badgeTextColor = theme.badgeTextColor
        }
    }

    static func ==(lhs: ClassicNavigationBarColors, rhs: ClassicNavigationBarColors) -> Bool {
        if (lhs.backgroundColor == nil) != (rhs.backgroundColor == nil) {
            return false
        }
        if let lhsBackground = lhs.backgroundColor, let rhsBackground = rhs.backgroundColor, lhsBackground.argb != rhsBackground.argb {
            return false
        }
        if lhs.enableBlur != rhs.enableBlur {
            return false
        }
        let lhsColors: [UIColor] = [lhs.buttonColor, lhs.disabledButtonColor, lhs.primaryTextColor, lhs.separatorColor, lhs.badgeBackgroundColor, lhs.badgeTextColor]
        let rhsColors: [UIColor] = [rhs.buttonColor, rhs.disabledButtonColor, rhs.primaryTextColor, rhs.separatorColor, rhs.badgeBackgroundColor, rhs.badgeTextColor]
        return lhsColors.map(\.argb) == rhsColors.map(\.argb)
    }
}
