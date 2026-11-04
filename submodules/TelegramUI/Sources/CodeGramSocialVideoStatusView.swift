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
    private let contentView = UIScrollView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var presentation = Presentation(mode: .preparing, title: "Видео", detail: "Подготовка…", count: 1)
    private var observers: [NSObjectProtocol] = []
    override var isHidden: Bool { didSet { self.updateSpinner() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.accessibilityIdentifier = "CodeGram.videoSendStatus"
        self.isOpaque = true
        self.layer.cornerRadius = 18
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        self.contentView.delaysContentTouches = false
        self.contentView.alwaysBounceVertical = false
        self.contentView.accessibilityIdentifier = "CodeGram.videoSendScroll"
        if #available(iOS 26.0, *) {
            self.contentView.topEdgeEffect.isHidden = true
            self.contentView.bottomEdgeEffect.isHidden = true
            self.contentView.leftEdgeEffect.isHidden = true
            self.contentView.rightEdgeEffect.isHidden = true
        }

        self.addSubview(self.contentView)

        self.titleLabel.font = .preferredFont(forTextStyle: .footnote)
        self.titleLabel.numberOfLines = 2
        self.detailLabel.font = .preferredFont(forTextStyle: .caption1)
        self.detailLabel.numberOfLines = 2
        for label in [self.titleLabel, self.detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            self.contentView.addSubview(label)
        }
        self.contentView.addSubview(self.spinner)
        for button in [self.primaryButton, self.copyButton, self.closeButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            self.contentView.addSubview(button)
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
    private struct ActionLayout {
        let below: Bool
        let rowHeight: CGFloat
        let rows: [[(UIButton, CGFloat)]]
        var width: CGFloat { self.rows.first?.reduce(0, { $0 + $1.1 }) ?? 0 }
    }
    private func actionLayout(width: CGFloat) -> ActionLayout {
        let buttons = [self.primaryButton, self.copyButton, self.closeButton].filter { !$0.isHidden }
        let available = max(44, width - 16)
        var rowHeight: CGFloat = 44
        let measured: [(UIButton, CGFloat)] = buttons.map { button in
            let textSize = button.titleLabel?.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
            rowHeight = max(rowHeight, ceil(textSize.height + 16))
            return (button, min(available, max(44, ceil(textSize.width + 20))))
        }
        let total = measured.reduce(CGFloat(0), { $0 + $1.1 })
        let below = !buttons.isEmpty && (self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory || width - 50 - total < 140)
        if !below { return ActionLayout(below: false, rowHeight: rowHeight, rows: measured.isEmpty ? [] : [measured]) }
        var rows: [[(UIButton, CGFloat)]] = []
        var row: [(UIButton, CGFloat)] = []
        var used: CGFloat = 0
        for item in measured {
            if !row.isEmpty && used + item.1 > available { rows.append(row); row = []; used = 0 }
            row.append(item); used += item.1
        }
        if !row.isEmpty { rows.append(row) }
        return ActionLayout(below: true, rowHeight: rowHeight, rows: rows)
    }
    func preferredHeight(width: CGFloat) -> CGFloat {
        let actions = self.actionLayout(width: width)
        let labelsWidth = max(44, width - 50 - (actions.below ? 0 : actions.width + 8))
        let title = self.titleLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        let detail = self.detailLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        let labelsHeight = max(58, ceil(title + detail + 23))
        return labelsHeight + (actions.below ? CGFloat(actions.rows.count) * actions.rowHeight + 6 : 0)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.contentView.frame = self.bounds
        let naturalHeight = self.preferredHeight(width: self.bounds.width)
        let size = CGSize(width: self.bounds.width, height: max(self.bounds.height, naturalHeight))
        self.contentView.contentSize = size
        self.contentView.isScrollEnabled = naturalHeight > self.bounds.height + 0.5
        self.contentView.showsVerticalScrollIndicator = self.contentView.isScrollEnabled
        let actions = self.actionLayout(width: size.width)
        let controlsHeight = CGFloat(actions.rows.count) * actions.rowHeight
        var y = actions.below ? size.height - controlsHeight - 6 : (size.height - actions.rowHeight) * 0.5
        for row in actions.rows {
            var x = size.width - 8 - row.reduce(0, { $0 + $1.1 })
            for (button, width) in row {
                button.frame = CGRect(x: x, y: y, width: width, height: actions.rowHeight)
                x += width
            }
            y += actions.rowHeight
        }
        let labelsWidth = max(1, size.width - 50 - (actions.below ? 0 : actions.width + 8))
        let titleHeight = self.titleLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        let detailHeight = self.detailLabel.sizeThatFits(CGSize(width: labelsWidth, height: .greatestFiniteMagnitude)).height
        self.titleLabel.frame = CGRect(x: 38, y: 9, width: labelsWidth, height: titleHeight)
        self.detailLabel.frame = CGRect(x: 38, y: 12 + titleHeight, width: labelsWidth, height: detailHeight)
        self.spinner.frame = CGRect(x: 12, y: 13, width: 18, height: 18)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != self.traitCollection.preferredContentSizeCategory {
            self.setNeedsLayout()
        }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); self.updateSpinner() }
    private func updateSpinner() {
        let spinning = !self.isHidden && self.window != nil && UIApplication.shared.applicationState == .active && !UIAccessibility.isReduceMotionEnabled &&
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
