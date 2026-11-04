import Foundation
import UIKit
import Display
import ComponentFlow

/// The shared classic surface is matte. It never samples or refracts content
/// behind it; all glass consumers retain their existing content/shape hosts.
final class ClassicGlassMaterialView: UIView {
    private let colorView: UIView
    private var color: UIColor?

    override init(frame: CGRect) {
        self.colorView = UIView()
        self.colorView.isUserInteractionEnabled = false
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.layer.cornerCurve = .circular
        self.addSubview(self.colorView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var shapeFollowingViews: [UIView] { return [self.colorView] }

    func update(size: CGSize, color: UIColor, transition: ComponentTransition) {
        let effectiveColor: UIColor = color.alpha > .ulpOfOne ? color.withAlphaComponent(1.0) : .clear
        if self.color != effectiveColor {
            self.color = effectiveColor
            transition.setBackgroundColor(view: self.colorView, color: effectiveColor)
        }
        transition.setFrame(view: self.colorView, frame: CGRect(origin: .zero, size: size))
    }
}

extension GlassBackgroundView {
    public static var classicPanelColor: (_ isDark: Bool) -> UIColor = { isDark in
        if isDark {
            return UIColor(rgb: 0x1d1d1d, alpha: 0.9)
        } else {
            return UIColor(rgb: 0xf2f2f2, alpha: 0.9)
        }
    }

    static func classicMaterialColor(tintColor: TintColor, isDark: Bool) -> UIColor {
        let clearColor: UIColor = isDark ? UIColor(white: 0.0, alpha: 0.35) : GlassBackgroundView.classicPanelColor(false)
        switch tintColor.kind {
        case .panel:
            return GlassBackgroundView.classicPanelColor(isDark)
        case .clear:
            return clearColor
        case let .custom(style, color):
            if color.alpha >= 0.5 {
                return color
            }
            let base: UIColor
            switch style {
            case .default:
                base = GlassBackgroundView.classicPanelColor(isDark)
            case .clear:
                base = clearColor
            }
            return classicColor(color, over: base)
        }
    }
}

private func classicColor(_ top: UIColor, over bottom: UIColor) -> UIColor {
    var tr: CGFloat = 0.0, tg: CGFloat = 0.0, tb: CGFloat = 0.0, ta: CGFloat = 0.0
    var br: CGFloat = 0.0, bg: CGFloat = 0.0, bb: CGFloat = 0.0, ba: CGFloat = 0.0
    guard top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta), bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else {
        return bottom
    }
    if ta <= .ulpOfOne {
        return bottom
    }
    let alpha = ta + ba * (1.0 - ta)
    if alpha <= .ulpOfOne {
        return UIColor(white: 0.0, alpha: 0.0)
    }
    func channel(_ t: CGFloat, _ b: CGFloat) -> CGFloat {
        return (t * ta + b * ba * (1.0 - ta)) / alpha
    }
    return UIColor(red: channel(tr, br), green: channel(tg, bg), blue: channel(tb, bb), alpha: alpha)
}
