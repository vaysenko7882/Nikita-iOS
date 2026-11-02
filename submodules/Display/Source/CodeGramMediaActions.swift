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
    controller.popoverPresentationController?.sourceView = sourceView
    controller.popoverPresentationController?.sourceRect = CGRect(x: sourceView.bounds.midX,
        y: sourceView.bounds.maxY - 1, width: 1, height: 1)
    return controller
}

// UIAlertAction may run before, during or after UIKit's automatic dismissal.
// Keep the action exactly once in each state, including an already-closed sheet.
func codeGramDismissMediaActions(_ controller: UIAlertController?, perform: @escaping () -> Void) {
    guard let controller, controller.presentingViewController != nil else { perform(); return }
    if controller.isBeingDismissed, let coordinator = controller.transitionCoordinator {
        if !coordinator.animate(alongsideTransition: nil, completion: { _ in perform() }) {
            DispatchQueue.main.async(execute: perform)
        }
    } else {
        controller.dismiss(animated: true, completion: perform)
    }
}
