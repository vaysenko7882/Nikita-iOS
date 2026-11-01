import Foundation
import TelegramCore
import UIKit

enum CodeGramSettingsTheme {
    private static let icons = NSCache<NSString, UIImage>()
    static var background: UIColor {
        return UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemGroupedBackground }
    }
    static var surface: UIColor {
        return UIColor { $0.userInterfaceStyle == .dark ? .tertiarySystemBackground : .secondarySystemGroupedBackground }
    }
    static func symbol(_ name: String) -> UIImage? {
        if let image = self.icons.object(forKey: name as NSString) { return image }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { _ in
            UIColor(white: 0.38, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 32, height: 32), cornerRadius: 10).fill()
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))?
                .withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 7, y: 7, width: 18, height: 18))
        }.withRenderingMode(.alwaysOriginal)
        self.icons.setObject(image, forKey: name as NSString)
        return image
    }
    static func icon(for title: String) -> String {
        let title = title.lowercased()
        for (word, icon) in [("голос", "waveform"), ("пресет", "waveform"), ("высот", "waveform.path"),
            ("тон", "slider.horizontal.3"), ("робот", "cpu"), ("эхо", "waveform.path"), ("тишин", "speaker.slash"),
            ("номер", "phone"), ("онлайн", "eye.slash"), ("прочт", "checkmark.message"), ("истор", "clock"),
            ("архив", "archivebox"), ("удал", "trash"), ("сохран", "square.and.arrow.down"),
            ("памят", "internaldrive"), ("файл", "doc"), ("фото", "photo"), ("аватар", "person.crop.circle"),
            ("групп", "person.2"), ("канал", "megaphone"), ("диалог", "bubble.left.and.bubble.right"),
            ("плашк", "capsule"), ("режим", "leaf"), ("энерго", "leaf"), ("сервер", "server.rack"),
            ("vps", "server.rack"), ("фильтр", "line.3.horizontal.decrease"), ("скры", "eye.slash"),
            ("сброс", "arrow.counterclockwise"), ("обнов", "arrow.clockwise"), ("назван", "textformat"),
            ("имя", "textformat"), ("доступ", "lock.open"), ("рамк", "square.dashed"), ("цвет", "paintpalette"),
            ("прозрач", "circle.lefthalf.filled"), ("затемн", "circle.lefthalf.filled"), ("поиск", "magnifyingglass")] {
            if title.contains(word) { return icon }
        }
        return "slider.horizontal.3"
    }
    static func prepare(_ cell: UITableViewCell) {
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.tintColor = .label
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        let title = cell.textLabel?.text ?? cell.accessibilityLabel ?? "Настройка"
        let name = cell.imageView?.accessibilityIdentifier ?? self.icon(for: title)
        if !(cell is CodeGramIconProvidingCell) { cell.imageView?.image = self.symbol(name) }
        cell.imageView?.tintColor = .white
        cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        if cell.backgroundView == nil { cell.backgroundView = CodeGramRowSurface() }
        cell.selectedBackgroundView = UIView()
        cell.selectedBackgroundView?.backgroundColor = .tertiarySystemFill
    }
    static func configure(_ table: UITableView) {
        table.backgroundColor = self.background
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 68
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.tintColor = .label
    }
}

/// Custom cells draw their own white icon and keep their content constraints.
protocol CodeGramIconProvidingCell {}

final class CodeGramMaterialView: UIView {
    private let material = UIVisualEffectView()
    private let radius: CGFloat
    private var reduced: Bool?
    private var observers: [NSObjectProtocol] = []
    init(radius: CGFloat = 24) {
        self.radius = radius
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.layer.cornerRadius = radius; self.layer.cornerCurve = .continuous; self.clipsToBounds = true
        self.addSubview(self.material)
        self.material.isUserInteractionEnabled = false
        self.material.layer.cornerRadius = radius; self.material.clipsToBounds = true
        if #available(iOS 26.0, *) { self.material.cornerConfiguration = .corners(radius: .fixed(radius)) }
        _ = ProcessInfo.processInfo.thermalState
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        self.refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { for observer in self.observers { NotificationCenter.default.removeObserver(observer) } }
    func refresh() {
        let reduced = CodeGramEnergyPolicy.current.usesReducedEffects || UIAccessibility.isReduceTransparencyEnabled
        guard reduced != self.reduced else { return }
        self.reduced = reduced
        self.backgroundColor = reduced ? CodeGramSettingsTheme.surface : .clear
        if reduced { self.material.effect = nil }
        else if #available(iOS 26.0, *) { self.material.effect = UIGlassEffect(style: .regular) }
        else { self.material.effect = UIBlurEffect(style: .systemMaterial) }
    }
    override func layoutSubviews() { super.layoutSubviews(); self.material.frame = self.bounds }
}

private final class CodeGramRowSurface: UIView {
    private let surface = CodeGramMaterialView(radius: 22)
    override init(frame: CGRect) { super.init(frame: frame); self.addSubview(self.surface) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() { super.layoutSubviews(); self.surface.frame = self.bounds.insetBy(dx: 0, dy: 4) }
}
