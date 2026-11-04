import UIKit

private final class CodeGramPlainAlertButton: UIButton {
    var measurementWidth: CGFloat = 0 {
        didSet { if oldValue != self.measurementWidth { self.invalidateIntrinsicContentSize() } }
    }

    override var intrinsicContentSize: CGSize {
        guard self.measurementWidth > 0, let label = self.titleLabel else { return super.intrinsicContentSize }
        let fitted = label.sizeThatFits(CGSize(width: max(1, self.measurementWidth - 24), height: .greatestFiniteMagnitude))
        return CGSize(width: ceil(fitted.width) + 24, height: max(48, ceil(fitted.height) + 24))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layer.cornerRadius = min(28, self.bounds.height * 0.5)
        guard let label = self.titleLabel else { return }
        label.frame = self.titleFrame(in: self.bounds)
    }

    private func titleFrame(in contentRect: CGRect) -> CGRect {
        // A button can lay out before Auto Layout has given it a size.
        // Insetting that zero/tiny rectangle produces CGRect.null, whose
        // infinite origin must never reach the label's layer.
        guard contentRect.minX.isFinite, contentRect.minY.isFinite,
            contentRect.width.isFinite, contentRect.height.isFinite,
            contentRect.width > 24, contentRect.height > 24 else { return .zero }
        let rect = CGRect(x: contentRect.minX + 12, y: contentRect.minY + 12,
            width: contentRect.width - 24, height: contentRect.height - 24)
        let fitted = self.titleLabel?.sizeThatFits(CGSize(width: max(1, rect.width), height: .greatestFiniteMagnitude)) ?? rect.size
        return CGRect(x: rect.minX, y: contentRect.midY - min(rect.height, fitted.height) * 0.5, width: rect.width, height: min(rect.height, fitted.height))
    }
}

/// An action model for the app's matte dialogs. UIKit's alert presentation is
/// intentionally not used: on current SDKs its surface is Liquid Glass.
public final class CodeGramPlainAlertAction {
    public let title: String?
    public let style: UIAlertAction.Style
    public var isEnabled: Bool = true { didSet { self.enabledChanged?(self.isEnabled) } }
    fileprivate var enabledChanged: ((Bool) -> Void)?
    fileprivate var handler: ((CodeGramPlainAlertAction) -> Void)?

    public init(title: String?, style: UIAlertAction.Style, handler: ((CodeGramPlainAlertAction) -> Void)? = nil) {
        self.title = title
        self.style = style
        self.handler = handler
    }
}

/// A public-UIKit dialog with an opaque surface, scrollable Dynamic Type
/// content and normal UIViewController dismissal. It has no visual-effect or
/// private UIKit hierarchy and does not ask the OS to build a glass sheet.
public final class CodeGramPlainAlertController: UIViewController {
    public let preferredStyle: UIAlertController.Style
    public private(set) var actions: [CodeGramPlainAlertAction] = []
    private var fields: [UITextField] = []
    public var textFields: [UITextField]? { return self.fields.isEmpty ? nil : self.fields }
    public var message: String? { didSet { self.updateContents() } }
    public override var title: String? { didSet { self.updateContents() } }

    private let dimView = UIControl()
    private let panel = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private var keyboardFrame: CGRect?
    private var observers: [NSObjectProtocol] = []
    private var actionHandled = false

    public init(title: String?, message: String?, preferredStyle: UIAlertController.Style) {
        self.preferredStyle = preferredStyle
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    public func addAction(_ action: CodeGramPlainAlertAction) {
        self.actions.append(action)
        self.updateContents()
    }

    public func addTextField(configurationHandler: ((UITextField) -> Void)? = nil) {
        let field = UITextField()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .none
        field.backgroundColor = .tertiarySystemGroupedBackground
        field.textColor = .label
        field.layer.cornerRadius = 14
        field.layer.cornerCurve = .continuous
        field.clipsToBounds = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        field.leftViewMode = .always
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        field.addTarget(self, action: #selector(self.finishEditing(_:)), for: .editingDidEndOnExit)
        configurationHandler?(field)
        self.fields.append(field)
        self.updateContents()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear
        self.view.accessibilityViewIsModal = true
        self.dimView.backgroundColor = UIColor(white: 0, alpha: 0.5)
        self.dimView.addTarget(self, action: #selector(self.outsidePressed), for: .touchUpInside)
        self.view.addSubview(self.dimView)
        self.panel.accessibilityIdentifier = "CodeGram.alert.panel"
        self.panel.backgroundColor = .secondarySystemBackground
        self.panel.isOpaque = true
        self.panel.layer.cornerRadius = 32
        self.panel.layer.cornerCurve = .continuous
        self.panel.clipsToBounds = true
        self.view.addSubview(self.panel)
        self.scrollView.alwaysBounceVertical = false
        self.scrollView.keyboardDismissMode = .interactive
        if #available(iOS 26.0, *) {
            self.scrollView.topEdgeEffect.isHidden = true
            self.scrollView.bottomEdgeEffect.isHidden = true
            self.scrollView.leftEdgeEffect.isHidden = true
            self.scrollView.rightEdgeEffect.isHidden = true
        }
        self.panel.addSubview(self.scrollView)
        self.contentStack.axis = .vertical
        self.contentStack.alignment = .fill
        self.contentStack.spacing = 14
        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.contentStack)
        NSLayoutConstraint.activate([
            self.contentStack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor),
            self.contentStack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor),
            self.contentStack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor),
            self.contentStack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor),
            self.contentStack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor)
        ])
        self.titleLabel.font = .preferredFont(forTextStyle: .headline)
        self.messageLabel.font = .preferredFont(forTextStyle: .body)
        for label in [self.titleLabel, self.messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textColor = .label
            label.textAlignment = .center
        }
        self.observers.append(NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.contentStack.arrangedSubviews.forEach { $0.invalidateIntrinsicContentSize() }
            self?.view.setNeedsLayout()
        })
        self.observers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            self.keyboardFrame = self.view.convert(frame, from: nil)
            self.view.setNeedsLayout()
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            UIView.animate(withDuration: duration, animations: { self.view.layoutIfNeeded() })
        })
        self.updateContents()
    }

    public override func viewWillAppear(_ animated: Bool) {
        // Resolve the visible presenter so app-selected appearance and accent
        // also apply to this opaque, modern rounded surface.
        var source = self.presentingViewController
        if let tabs = source as? UITabBarController { source = tabs.selectedViewController }
        if let navigation = source as? UINavigationController { source = navigation.topViewController }
        if let source {
            self.view.tintColor = source.view.tintColor
            if self.overrideUserInterfaceStyle == .unspecified,
                source.traitCollection.userInterfaceStyle != .unspecified {
                self.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
            }
        }
        self.updateContents()
        super.viewWillAppear(animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.fields.first?.becomeFirstResponder()
    }

    private func updateContents() {
        guard self.isViewLoaded else { return }
        for view in self.contentStack.arrangedSubviews {
            self.contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        self.titleLabel.text = self.title
        self.messageLabel.text = self.message
        if let title = self.title, !title.isEmpty { self.contentStack.addArrangedSubview(self.titleLabel) }
        if let message = self.message, !message.isEmpty { self.contentStack.addArrangedSubview(self.messageLabel) }
        for field in self.fields { self.contentStack.addArrangedSubview(field) }
        for (index, action) in self.actions.enumerated() {
            let button = CodeGramPlainAlertButton(frame: .zero)
            if #available(iOS 15.0, *) { button.configuration = nil }
            button.backgroundColor = .tertiarySystemGroupedBackground
            button.layer.cornerRadius = 24
            button.layer.cornerCurve = .continuous
            button.clipsToBounds = true
            button.titleLabel?.font = .preferredFont(forTextStyle: action.style == .cancel ? .headline : .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.setTitle(action.title, for: .normal)
            button.setTitleColor(action.style == .destructive ? .systemRed : self.view.tintColor, for: .normal)
            button.setTitleColor(.secondaryLabel, for: .disabled)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            button.isEnabled = action.isEnabled
            action.enabledChanged = { [weak button] in button?.isEnabled = $0 }
            button.tag = index
            button.addTarget(self, action: #selector(self.actionPressed(_:)), for: .touchUpInside)
            self.contentStack.addArrangedSubview(button)
        }
        self.view.setNeedsLayout()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.dimView.frame = self.view.bounds
        let safe = self.view.bounds.inset(by: self.view.safeAreaInsets)
        var bottom = safe.maxY
        if let keyboardFrame = self.keyboardFrame, keyboardFrame.minY.isFinite,
            keyboardFrame.intersects(self.view.bounds), keyboardFrame.width > 0 {
            bottom = min(bottom, keyboardFrame.minY)
        }
        let availableHeight = max(1, bottom - safe.minY - 16)
        let maximumWidth: CGFloat = self.preferredStyle == .alert ? 340 : 520
        let width = max(1, min(maximumWidth, safe.width - 32))
        let contentWidth = max(1, width - 40)
        for label in [self.titleLabel, self.messageLabel] {
            if abs(label.preferredMaxLayoutWidth - contentWidth) > 0.25 {
                label.preferredMaxLayoutWidth = contentWidth
            }
        }
        for case let button as CodeGramPlainAlertButton in self.contentStack.arrangedSubviews {
            button.measurementWidth = contentWidth
        }
        // Measure at the final width while retaining the current height.
        // Expanding to the maximum height and shrinking again on every pass
        // continually invalidates UIScrollView's guides during presentation.
        if abs(self.scrollView.bounds.width - contentWidth) > 0.25 {
            self.scrollView.frame = CGRect(x: 20, y: 20, width: contentWidth, height: max(1, self.scrollView.bounds.height))
            self.scrollView.layoutIfNeeded()
        }
        let fitting = self.contentStack.systemLayoutSizeFitting(CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = min(availableHeight, fitting.height.isFinite ? max(40, fitting.height + 40) : availableHeight)
        let y = self.preferredStyle == .actionSheet ? bottom - height - 8 : safe.minY + (bottom - safe.minY - height) * 0.5
        let panelFrame = CGRect(x: safe.midX - width * 0.5, y: max(safe.minY + 8, y), width: width, height: height)
        if self.panel.frame != panelFrame { self.panel.frame = panelFrame }
        let scrollFrame = CGRect(x: 20, y: 20, width: contentWidth, height: max(1, height - 40))
        if self.scrollView.frame != scrollFrame { self.scrollView.frame = scrollFrame }
    }

    @objc private func actionPressed(_ button: UIButton) {
        guard self.actions.indices.contains(button.tag) else { return }
        self.perform(self.actions[button.tag])
    }

    @objc private func outsidePressed() {
        guard self.preferredStyle == .actionSheet else { return }
        if let cancel = self.actions.first(where: { $0.style == .cancel }) { self.perform(cancel) }
        else { self.dismiss(animated: true) }
    }

    @objc private func finishEditing(_ field: UITextField) { field.resignFirstResponder() }

    private func perform(_ action: CodeGramPlainAlertAction) {
        guard action.isEnabled, !self.actionHandled else { return }
        self.actionHandled = true
        self.view.endEditing(true)
        let handler = action.handler
        // Alert actions often capture the alert to read its text fields. Drop
        // those closures when finishing so a dismissed dialog cannot retain
        // itself through the action array.
        for item in self.actions { item.handler = nil; item.enabledChanged = nil }
        self.dismiss(animated: true) { [self] in
            withExtendedLifetime(self) { handler?(action) }
        }
    }
}

/// The matte action sheet is shared by disappearing photo/video viewers.
public func codeGramMediaActions(saveTitle: String, startTitle: String, cancelTitle: String,
    canStart: Bool, sourceView: UIView, save: @escaping () -> Void,
    start: @escaping () -> Void) -> CodeGramPlainAlertController {
    let controller = CodeGramPlainAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    controller.overrideUserInterfaceStyle = sourceView.traitCollection.userInterfaceStyle
    controller.addAction(CodeGramPlainAlertAction(title: saveTitle, style: .default, handler: { [weak controller] _ in codeGramDismissMediaActions(controller, perform: save) }))
    if canStart {
        controller.addAction(CodeGramPlainAlertAction(title: startTitle, style: .default, handler: { [weak controller] _ in codeGramDismissMediaActions(controller, perform: start) }))
    }
    controller.addAction(CodeGramPlainAlertAction(title: cancelTitle, style: .cancel))
    return controller
}

// UIAlertAction may run before, during or after UIKit's automatic dismissal.
// Keep the action exactly once in each state, including an already-closed sheet.
public func codeGramDismissMediaActions(_ controller: UIViewController?, perform: @escaping () -> Void) {
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
