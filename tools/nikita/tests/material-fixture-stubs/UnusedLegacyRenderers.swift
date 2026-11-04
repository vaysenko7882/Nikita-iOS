import UIKit
import ComponentFlow

// These are only inactive-branch type signatures. They do not supply geometry.
final class LegacyGlassView: UIView {
    enum Style { case normal, clear }
    override init(frame: CGRect) { preconditionFailure("Legacy sampled glass must not be constructed") }
    required init?(coder: NSCoder) { fatalError("unsupported fixture coder") }
    func update(size: CGSize, shape: GlassBackgroundView.Shape, style: Style, transition: ComponentTransition) {
        preconditionFailure("Legacy sampled glass must not execute")
    }
}
final class GlassHighlightGestureRecognizer: UIGestureRecognizer {
    weak var highlightContainerView: UIView?
}
