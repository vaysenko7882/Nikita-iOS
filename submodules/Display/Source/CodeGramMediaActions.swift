import UIKit

/// The system action sheet is shared by disappearing photo/video viewers.
public func codeGramMediaActions(saveTitle: String, startTitle: String, cancelTitle: String,
    canStart: Bool, sourceView: UIView, save: @escaping () -> Void,
    start: @escaping () -> Void) -> UIAlertController {
    let controller = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    controller.overrideUserInterfaceStyle = .dark
    controller.addAction(UIAlertAction(title: saveTitle, style: .default, handler: { [weak controller] _ in codeGramDismissMediaActions(controller, perform: save) }))
    if canStart {
        controller.addAction(UIAlertAction(title: startTitle, style: .default, handler: { [weak controller] _ in codeGramDismissMediaActions(controller, perform: start) }))
    }
    controller.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
    let anchor = codeGramMediaPopoverAnchor(in: sourceView)
    controller.popoverPresentationController?.sourceView = anchor
    controller.popoverPresentationController?.sourceRect = anchor.bounds
    return controller
}

// UIAlertAction may run before, during or after UIKit's automatic dismissal.
// Keep the action exactly once in each state, including an already-closed sheet.
public func codeGramDismissMediaActions(_ controller: UIAlertController?, perform: @escaping () -> Void) {
    guard let controller, controller.presentingViewController != nil else { perform(); return }
    if controller.isBeingDismissed, let coordinator = controller.transitionCoordinator {
        if !coordinator.animate(alongsideTransition: nil, completion: { _ in DispatchQueue.main.async(execute: perform) }) {
            DispatchQueue.main.async(execute: perform)
        }
    } else {
        controller.dismiss(animated: true, completion: perform)
    }
}

private final class CodeGramMediaPopoverAnchorView: UIView {}

/// iOS may morph a popover's source view. Never use the entire gallery/chat as
/// that source: reuse one tiny, transparent anchor owned by the presenting view.
public func codeGramMediaPopoverAnchor(in sourceView: UIView) -> UIView {
    let anchor: UIView
    if let existing = sourceView.subviews.first(where: { $0 is CodeGramMediaPopoverAnchorView }) {
        anchor = existing
    } else {
        anchor = CodeGramMediaPopoverAnchorView()
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        sourceView.addSubview(anchor)
    }
    anchor.frame = CGRect(x: sourceView.bounds.midX - 1,
        y: sourceView.bounds.maxY - max(2, sourceView.safeAreaInsets.bottom) - 2, width: 2, height: 2)
    return anchor
}
