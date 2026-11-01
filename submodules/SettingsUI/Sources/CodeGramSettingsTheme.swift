import UIKit

enum CodeGramSettingsTheme {
    private static let icons = NSCache<NSString, UIImage>()
    static var background: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? .black : .systemGroupedBackground }
    }
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
        // The glass owns feedback. A separate selection overlay hides it.
        cell.selectionStyle = .none
    }
    static func configure(_ table: UITableView) {
        table.backgroundColor = self.background
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 88
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.tintColor = .label
    }
}

/// Install native glass synchronously, once. UIKit handles accessibility and
/// adaptation; archive power policy must not remove the user's interface.
class CodeGramMaterialView: UIVisualEffectView {
    init(radius: CGFloat = 24) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            super.init(effect: glass)
            self.cornerConfiguration = .corners(radius: .fixed(radius))
        } else {
            super.init(effect: UIBlurEffect(style: .systemMaterial))
            self.layer.cornerRadius = radius
            self.layer.cornerCurve = .continuous
            self.clipsToBounds = true
        }
        // Host labels/controls in contentView. Do not clip, scale or fade the
        // native interactive surface, or detach its content from the effect.
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The search field stays a system UISearchBar. Its public background-image API
/// makes room for one real glass surface, with the field hosted inside its content.
final class CodeGramSearchView: CodeGramMaterialView {
    let searchBar = UISearchBar()
    init() {
        super.init(radius: 26)
        self.searchBar.placeholder = "Поиск"
        self.searchBar.searchBarStyle = .minimal
        self.searchBar.backgroundImage = UIImage()
        self.searchBar.setSearchFieldBackgroundImage(UIImage(), for: .normal)
        self.searchBar.searchTextField.backgroundColor = .clear
        self.searchBar.searchTextField.font = .preferredFont(forTextStyle: .body)
        self.searchBar.searchTextField.adjustsFontForContentSizeCategory = true
        self.searchBar.searchTextField.autocorrectionType = .no
        self.searchBar.tintColor = .label
        self.contentView.addSubview(self.searchBar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.searchBar.frame = self.bounds
    }
}

/// A custom control uses the glass's own elasticity, including its content.
/// Taps on embedded switches remain independent of the card's navigation action.
class CodeGramDashboardSurface: CodeGramMaterialView, UIGestureRecognizerDelegate {
    var action: (() -> Void)?
    init() {
        super.init(radius: 24)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.pressed))
        tap.cancelsTouchesInView = false; tap.delegate = self
        self.addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func applyPalette(dark: Bool) { /* The native effect follows interface traits. */ }
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

