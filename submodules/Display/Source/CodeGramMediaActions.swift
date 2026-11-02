import UIKit

/// The system action sheet is shared by disappearing photo/video viewers.
public func codeGramMediaActions(saveTitle: String, startTitle: String, cancelTitle: String,
    canStart: Bool, sourceView: UIView, save: @escaping () -> Void,
    start: @escaping () -> Void) -> UIAlertController {
    let controller = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    controller.addAction(UIAlertAction(title: saveTitle, style: .default, handler: { _ in save() }))
    if canStart {
        controller.addAction(UIAlertAction(title: startTitle, style: .default, handler: { _ in start() }))
    }
    controller.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
    controller.popoverPresentationController?.sourceView = sourceView
    controller.popoverPresentationController?.sourceRect = CGRect(x: sourceView.bounds.midX,
        y: sourceView.bounds.maxY - 1, width: 1, height: 1)
    return controller
}
