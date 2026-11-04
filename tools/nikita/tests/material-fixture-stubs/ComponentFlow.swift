// Immediate property-setting adapters, not material or layout implementations.
import UIKit

public struct ComponentTransition {
    public enum Animation {
        case none
        public var isImmediate: Bool { true }
    }
    public let animation: Animation
    public static var immediate: ComponentTransition { ComponentTransition(animation: .none) }
    public init(animation: Animation = .none) { self.animation = animation }
    public func withAnimation(_ animation: Animation) -> ComponentTransition { ComponentTransition(animation: animation) }
    public func setFrame(view: UIView, frame: CGRect) { view.frame = frame }
    public func setFrame(layer: CALayer, frame: CGRect) { layer.frame = frame }
    public func setBounds(view: UIView, bounds: CGRect) { view.bounds = bounds }
    public func setPosition(view: UIView, position: CGPoint) { view.center = position }
    public func setAlpha(view: UIView, alpha: CGFloat, completion: ((Bool) -> Void)? = nil) { view.alpha = alpha; completion?(true) }
    public func setScale(view: UIView, scale: CGFloat) { view.transform = CGAffineTransform(scaleX: scale, y: scale) }
    public func setCornerRadius(layer: CALayer, cornerRadius: CGFloat) { layer.cornerRadius = cornerRadius }
    public func setBackgroundColor(view: UIView, color: UIColor) { view.backgroundColor = color }
    public func setShapeLayerPath(layer: CAShapeLayer, path: CGPath) { layer.path = path }
    public func animateView(_ update: () -> Void) { update() }
    public func animateAlpha(view: UIView, from: CGFloat, to: CGFloat) { view.alpha = to }
    public func animateScale(view: UIView, from: CGFloat, to: CGFloat) { view.transform = CGAffineTransform(scaleX: to, y: to) }
}
