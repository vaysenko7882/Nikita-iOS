import UIKit

enum CodeGramSectionPosition: Equatable {
    case single, first, middle, last

    init(row: Int, count: Int) {
        if count <= 1 { self = .single }
        else if row == 0 { self = .first }
        else if row == count - 1 { self = .last }
        else { self = .middle }
    }
}

enum CodeGramSettingsTheme {
    private static let icons = NSCache<NSString, UIImage>()
    static var background: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? .black : .systemGroupedBackground }
    }
    static var surface: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.09, alpha: 1) : .secondarySystemGroupedBackground }
    }
    static var selectedSurface: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1) : .systemGray5 }
    }
    static var separator: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.87, alpha: 1) }
    }
    static var accent: UIColor { .systemBlue }
    static func symbol(_ name: String) -> UIImage? {
        if let image = self.icons.object(forKey: name as NSString) { return image }
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))?.withRenderingMode(.alwaysTemplate) else { return nil }
        self.icons.setObject(image, forKey: name as NSString)
        return image
    }
    static func prepare(_ cell: UITableViewCell) {
        cell.backgroundConfiguration = .clear()
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.tintColor = .label
        // The cell updates its opaque surface directly for selection feedback.
        cell.selectionStyle = .none
    }
    static func configure(_ table: UITableView) {
        self.disableScrollEdgeEffects(table)
        table.backgroundColor = self.background
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 64
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.sectionFooterHeight = UITableView.automaticDimension
        if #available(iOS 15.0, *) { table.sectionHeaderTopPadding = 8 }
        table.tintColor = .label
    }
    static func disableScrollEdgeEffects(_ scrollView: UIScrollView) {
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }
    }
}

/// A solid, theme-aware content host. No blur, refraction or interactive material.
class CodeGramSurfaceView: UIView {
    let contentView = UIView()
    private let separator = UIView()
    private let radius: CGFloat
    private(set) var sectionPosition: CodeGramSectionPosition = .single
    private var separatorInset: CGFloat = 60
    init(radius: CGFloat = 24) {
        self.radius = radius
        super.init(frame: .zero)
        self.isOpaque = true
        self.backgroundColor = CodeGramSettingsTheme.surface
        self.layer.cornerRadius = radius
        self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        self.contentView.backgroundColor = .clear
        self.addSubview(self.contentView)
        self.separator.backgroundColor = CodeGramSettingsTheme.separator
        self.separator.isUserInteractionEnabled = false
        self.separator.isAccessibilityElement = false
        self.separator.isHidden = true
        self.addSubview(self.separator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.contentView.frame = self.bounds
        let pixel = 1 / max(1, self.traitCollection.displayScale)
        self.separator.frame = CGRect(x: self.separatorInset, y: max(0, self.bounds.height - pixel), width: max(0, self.bounds.width - self.separatorInset), height: pixel)
    }
    func setSectionPosition(_ position: CodeGramSectionPosition, separatorInset: CGFloat = 60) {
        guard self.sectionPosition != position || self.separatorInset != separatorInset else { return }
        self.separatorInset = separatorInset
        if self.sectionPosition != position {
            self.sectionPosition = position
            self.layer.cornerRadius = position == .middle ? 0 : self.radius
            switch position {
            case .single: self.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            case .first: self.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            case .middle: self.layer.maskedCorners = []
            case .last: self.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            }
        }
        self.separator.isHidden = position == .single || position == .last
        self.setNeedsLayout()
    }
}

/// A plain text field keeps editing/accessibility without a system search material.
final class CodeGramSearchView: CodeGramSurfaceView, UITextFieldDelegate {
    let textField = UITextField()
    let cancelButton = UIButton(type: .system)
    private let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private var showsCancelButton = false
    var onTextChanged: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    init() {
        super.init(radius: 26)
        self.textField.placeholder = "Поиск"
        self.textField.borderStyle = .none
        self.textField.backgroundColor = .clear
        self.textField.textColor = .label
        self.textField.tintColor = .label
        self.textField.font = .preferredFont(forTextStyle: .body)
        self.textField.adjustsFontForContentSizeCategory = true
        self.textField.autocorrectionType = .no
        self.textField.autocapitalizationType = .none
        self.textField.returnKeyType = .search
        self.textField.clearButtonMode = .whileEditing
        self.textField.accessibilityLabel = "Поиск по настройкам CodeGram"
        self.textField.accessibilityIdentifier = "CodeGram.searchField"
        self.textField.delegate = self
        self.textField.addTarget(self, action: #selector(self.changed), for: .editingChanged)
        self.icon.tintColor = .secondaryLabel
        self.icon.contentMode = .scaleAspectFit
        self.icon.isUserInteractionEnabled = false
        self.icon.isAccessibilityElement = false
        self.cancelButton.configuration = nil
        self.cancelButton.setTitle("Отмена", for: .normal)
        self.cancelButton.setTitleColor(.label, for: .normal)
        self.cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        self.cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.cancelButton.accessibilityIdentifier = "CodeGram.cancelSearch"
        self.cancelButton.isHidden = true
        self.cancelButton.addTarget(self, action: #selector(self.cancelled), for: .touchUpInside)
        for view in [self.icon, self.textField, self.cancelButton] { self.contentView.addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let cancelWidth = self.showsCancelButton ? max(44, self.cancelButton.intrinsicContentSize.width + 12) : 0
        self.icon.frame = CGRect(x: 16, y: (self.bounds.height - 22) / 2, width: 22, height: 22)
        self.cancelButton.frame = CGRect(x: self.bounds.width - cancelWidth - 12, y: 0, width: cancelWidth, height: self.bounds.height)
        self.textField.frame = CGRect(x: 48, y: 0, width: max(1, self.bounds.width - 64 - (self.showsCancelButton ? cancelWidth + 8 : 0)), height: self.bounds.height)
    }
    func refreshPalette() { self.backgroundColor = CodeGramSettingsTheme.surface; self.setNeedsLayout() }
    func setShowsCancelButton(_ show: Bool, animated: Bool) {
        self.showsCancelButton = show
        self.cancelButton.isHidden = !show
        self.setNeedsLayout()
    }
    func textFieldDidBeginEditing(_ textField: UITextField) { self.setShowsCancelButton(true, animated: false) }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); self.onSubmit?(); return true }
    @objc private func changed() { self.onTextChanged?(self.textField.text ?? "") }
    @objc private func cancelled() {
        self.textField.text = nil
        self.textField.resignFirstResponder()
        self.setShowsCancelButton(false, animated: false)
        self.onTextChanged?("")
    }
}

/// Embedded switches keep their own actions; the rest of the card navigates.
class CodeGramDashboardSurface: CodeGramSurfaceView, UIGestureRecognizerDelegate {
    var action: (() -> Void)?
    init() {
        super.init(radius: 24)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.pressed))
        tap.cancelsTouchesInView = false; tap.delegate = self
        self.addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func applyPalette(dark: Bool) { self.backgroundColor = CodeGramSettingsTheme.surface }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }
    override func accessibilityActivate() -> Bool {
        guard let action else { return false }; action(); return true
    }
    @objc private func pressed() { self.action?() }
}


