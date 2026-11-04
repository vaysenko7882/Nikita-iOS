// Fixture adapters only. Material/view/clipping geometry comes from the
// production GlassBackgroundView and ClassicGlassMaterialView sources.
import UIKit

open class SimpleLayer: CALayer {
    public override init() { super.init() }
    public override init(layer: Any) { super.init(layer: layer) }
    required public init?(coder: NSCoder) { fatalError("unsupported fixture coder") }
}

public extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
    var alpha: CGFloat { self.cgColor.alpha }
    func mixedWith(_ other: UIColor, alpha: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        other.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        return UIColor(red: r + (rr-r)*alpha, green: g + (gg-g)*alpha, blue: b + (bb-b)*alpha, alpha: a + (aa-a)*alpha)
    }
}

public extension CALayer {
    static func luminanceToAlpha() -> AnyObject? {
        preconditionFailure("Backdrop filter factory must not execute in an opaque-material fixture")
    }
}

public extension UIImageView {
    func setMonochromaticEffect(tintColor: UIColor?) {
        preconditionFailure("Unused legacy image adapter must not execute in material geometry fixtures")
    }
}

public extension UIImage {
    convenience init?(bundleImageName: String) {
        preconditionFailure("Legacy glass-edge assets must not execute in opaque-material fixtures")
    }
}

public func generateImage(_ size: CGSize, rotatedContext: (CGSize, CGContext) -> Void) -> UIImage? {
    // Non-selected legacy image helpers still typecheck. These adapters never
    // replace the production material or clipping implementation.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { rotatedContext(size, $0.cgContext) }
}
