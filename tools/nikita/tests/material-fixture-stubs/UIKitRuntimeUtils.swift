import UIKit
// Only signatures needed to typecheck inactive native-glass branches. Any
// accidental construction proves that the material policy failed and traps.
public final class EffectSettingsContainerView: UIView {
    public var lumaMin: Double = 0
    public var lumaMax: Double = 0
    public var glassBlurRadius: Double = 0
    public static var morphGlassBlurRadius: Double = 0
    public override init(frame: CGRect) { preconditionFailure("Native glass container must not be constructed") }
    required public init?(coder: NSCoder) { fatalError("unsupported fixture coder") }
    public static func applyGlassBlurRadius(_ radius: Double, toLayerTree: CALayer, depth: Int) {
        preconditionFailure("Private backdrop settings must not execute")
    }
}
