import UIKit

/// Sender-only status. No modal, dimming view or keyboard interceptor.
final class CodeGramSocialVideoStatusView: UIView {
    enum Mode: Equatable { case preparing, enqueueing, failed, cancelled }
    struct Presentation {
        let mode: Mode
        let title: String
        let detail: String
        let count: Int
    }
    var primaryAction: (() -> Void)?
    var copyAction: (() -> Void)?
    var copyLinkAction: (() -> Void)?
    var dismissAction: (() -> Void)?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var presentation = Presentation(mode: .preparing, title: "Видео", detail: "Подготовка…", count: 1)
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.accessibilityIdentifier = "CodeGram.videoSendStatus"
        self.isOpaque = true
        self.layer.cornerRadius = 18
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        self.titleLabel.font = .preferredFont(forTextStyle: .footnote)
        self.titleLabel.numberOfLines = 2
        self.detailLabel.font = .preferredFont(forTextStyle: .caption1)
        self.detailLabel.numberOfLines = 2
        for label in [self.titleLabel, self.detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            self.addSubview(label)
        }
        self.addSubview(self.spinner)
        for button in [self.primaryButton, self.copyButton, self.closeButton] {
            button.configuration = nil
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            self.addSubview(button)
        }
        self.primaryButton.accessibilityIdentifier = "CodeGram.videoSendPrimary"
        self.copyButton.accessibilityIdentifier = "CodeGram.videoSendCopy"
        self.closeButton.accessibilityIdentifier = "CodeGram.videoSendDismiss"
        self.primaryButton.addTarget(self, action: #selector(self.primaryPressed), for: .touchUpInside)
        self.copyButton.addTarget(self, action: #selector(self.copyPressed), for: .touchUpInside)
        self.closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        self.closeButton.accessibilityLabel = "Убрать запись"
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
        let center = NotificationCenter.default
        self.observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.updateSpinner() },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.spinner.stopAnimating() },
            center.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateSpinner() }
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.observers.forEach(NotificationCenter.default.removeObserver) }

    func update(_ value: Presentation, background: UIColor, foreground: UIColor, secondary: UIColor, accent: UIColor) {
        self.presentation = value
        self.backgroundColor = background
        self.titleLabel.text = value.title + (value.count > 1 ? " · \(value.count)" : "")
        self.titleLabel.textColor = foreground
        self.detailLabel.text = value.detail
        self.detailLabel.textColor = secondary
        self.spinner.color = foreground
        self.primaryButton.setTitle(value.mode == .failed || value.mode == .cancelled ? "Повторить" : "Отменить", for: .normal)
        self.primaryButton.isHidden = value.mode == .enqueueing
        self.copyButton.setTitle(value.mode == .cancelled ? "Ссылка" : "Ошибка", for: .normal)
        self.copyButton.isHidden = value.mode != .failed && value.mode != .cancelled
        self.closeButton.isHidden = self.copyButton.isHidden
        for button in [self.primaryButton, self.copyButton] { button.setTitleColor(accent, for: .normal) }
        self.closeButton.tintColor = secondary
        self.titleLabel.accessibilityLabel = value.title
        self.detailLabel.accessibilityLabel = value.detail
        self.accessibilityHint = "Удерживай запись, чтобы скопировать исходную ссылку"
        self.updateSpinner()
        self.setNeedsLayout()
    }
    func showQueueFullNotice() {
        self.detailLabel.text = "Очередь заполнена. Ссылка осталась в поле."
    }
    private var usesSecondRow: Bool {
        (self.presentation.mode == .failed || self.presentation.mode == .cancelled) &&
        (self.bounds.width < 380 || self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
    }
    func preferredHeight(width: CGFloat) -> CGFloat {
        let failed = self.presentation.mode == .failed || self.presentation.mode == .cancelled
        let secondRow = failed && (width < 380 || self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
        let controls: CGFloat = secondRow ? 0 : failed ? 188 : self.presentation.mode == .enqueueing ? 8 : 88
        let labelsWidth = max(48, width - 48 - controls)
        let title = self.titleLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        let detail = self.detailLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        return max(58, ceil(title + detail + 23)) + (secondRow ? 36 : 0)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        let secondRow = self.usesSecondRow
        let controlsY = secondRow ? size.height - 36 : (size.height - 44) * 0.5
        var x = size.width - 8
        if !self.closeButton.isHidden { x -= 30; self.closeButton.frame = CGRect(x: x, y: controlsY, width: 30, height: secondRow ? 32 : 44) }
        if !self.copyButton.isHidden { x -= 61; self.copyButton.frame = CGRect(x: x, y: controlsY, width: 61, height: secondRow ? 32 : 44) }
        if !self.primaryButton.isHidden { x -= 79; self.primaryButton.frame = CGRect(x: x, y: controlsY, width: 79, height: secondRow ? 32 : 44) }
        let labelsWidth = max(1, (secondRow ? size.width - 12 : x - 8) - 38)
        let titleHeight = self.titleLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        let detailHeight = self.detailLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        self.titleLabel.frame = CGRect(x: 38, y: 9, width: labelsWidth, height: titleHeight)
        self.detailLabel.frame = CGRect(x: 38, y: 12 + titleHeight, width: labelsWidth, height: detailHeight)
        self.spinner.frame = CGRect(x: 12, y: 13, width: 18, height: 18)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); self.updateSpinner() }
    private func updateSpinner() {
        let spinning = self.window != nil && UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled &&
            (self.presentation.mode == .preparing || self.presentation.mode == .enqueueing)
        if spinning { self.spinner.startAnimating() } else { self.spinner.stopAnimating() }
        self.spinner.isHidden = !spinning
    }
    @objc private func primaryPressed() { self.primaryAction?() }
    @objc private func copyPressed() { self.copyAction?() }
    @objc private func closePressed() { self.dismissAction?() }
    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { self.copyLinkAction?() }
    }
}
