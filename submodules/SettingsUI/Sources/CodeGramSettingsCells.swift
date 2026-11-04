import UIKit

/// Complete constraints from the cell to every visible label let UITableView
/// measure multiline switch rows instead of overflowing a fixed-height row.
class CodeGramSurfaceCell: UITableViewCell {
    let surface = CodeGramSurfaceView(radius: 22)
    let bodyView = UIView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        CodeGramSettingsTheme.prepare(self)
        self.clipsToBounds = false; self.contentView.clipsToBounds = false
        self.contentView.addSubview(self.surface)
        self.surface.contentView.addSubview(self.bodyView)
        self.surface.translatesAutoresizingMaskIntoConstraints = false
        self.bodyView.translatesAutoresizingMaskIntoConstraints = false
        let minimum = self.surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        minimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            self.surface.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 4),
            self.surface.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -4),
            self.surface.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            self.surface.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.bodyView.topAnchor.constraint(equalTo: self.surface.topAnchor),
            self.bodyView.bottomAnchor.constraint(equalTo: self.surface.bottomAnchor),
            self.bodyView.leadingAnchor.constraint(equalTo: self.surface.leadingAnchor),
            self.bodyView.trailingAnchor.constraint(equalTo: self.surface.trailingAnchor), minimum
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func updateWrappingWidth(_ width: CGFloat) {}
    func setWrappingWidth(_ width: CGFloat, for label: UILabel) {
        let width = max(1, width)
        if abs(label.preferredMaxLayoutWidth - width) > 0.25 {
            label.preferredMaxLayoutWidth = width
        }
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        // The content host has no intrinsic width while UITableView performs
        // its fitting pass. Give multiline labels their final wrapping width
        // before asking Auto Layout for the height.
        self.updateWrappingWidth(targetSize.width)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.updateWrappingWidth(self.contentView.bounds.width)
    }
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        self.refreshSelection()
    }
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        self.refreshSelection()
    }
    private func refreshSelection() {
        self.surface.backgroundColor = self.isHighlighted || self.isSelected ? CodeGramSettingsTheme.selectedSurface : CodeGramSettingsTheme.surface
    }
    func install(_ view: UIView) {
        self.bodyView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.bodyView.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: self.bodyView.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: self.bodyView.topAnchor, constant: 14),
            view.bottomAnchor.constraint(equalTo: self.bodyView.bottomAnchor, constant: -14)
        ])
    }
}

final class CodeGramValueSwitch: UISwitch {
    var changed: ((Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.onTintColor = .systemGray
        self.thumbTintColor = .white
        self.addTarget(self, action: #selector(self.updateValue), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func updateValue() { self.changed?(self.isOn) }
}

/// Supply a bitmap thumb so UIKit cannot substitute an interactive glass knob.
final class CodeGramValueSlider: UISlider {
    private var thumbColor: UIColor?
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.minimumTrackTintColor = .label
        self.maximumTrackTintColor = .systemGray3
        self.refreshThumb()
        if #available(iOS 17.0, *) {
            self.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CodeGramValueSlider, _: UITraitCollection) in view.refreshThumb() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() { super.layoutSubviews(); self.refreshThumb() }
    private func refreshThumb() {
        let color = UIColor.label.resolvedColor(with: self.traitCollection)
        guard color != self.thumbColor else { return }
        self.thumbColor = color
        let image = UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { _ in
            color.setFill(); UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 24, height: 24)).fill()
        }
        self.setThumbImage(image, for: .normal)
        self.setThumbImage(image, for: .highlighted)
    }
}

final class CodeGramTextCell: CodeGramSurfaceCell {
    private let caption = UILabel()
    private let detailLabel = UILabel()
    private var iconWidth: CGFloat = 28
    private var headingControl: UIView?
    private var showsDisclosure = false
    init(title: String, detail: String? = nil, symbol: String, image: UIImage? = nil, control: UIView? = nil, disclosure: Bool = false) {
        super.init(style: .default, reuseIdentifier: nil)
        let icon = UIImageView(image: image ?? CodeGramSettingsTheme.symbol(symbol))
        icon.contentMode = .scaleAspectFit; icon.tintColor = .label
        icon.accessibilityIdentifier = "CodeGram.icon.\(symbol)"; icon.isAccessibilityElement = false
        let size: CGFloat = image == nil ? 28 : 44
        self.iconWidth = size; self.headingControl = control; self.showsDisclosure = disclosure
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: size), icon.heightAnchor.constraint(equalToConstant: size)])
        if image != nil { icon.layer.cornerRadius = 22; icon.clipsToBounds = true; icon.contentMode = .scaleAspectFill }
        let caption = self.caption
        caption.text = title; caption.textColor = .label
        caption.font = .preferredFont(forTextStyle: .body); caption.adjustsFontForContentSizeCategory = true
        caption.numberOfLines = 0; caption.lineBreakMode = .byWordWrapping
        caption.accessibilityIdentifier = "CodeGram.title"
        caption.setContentCompressionResistancePriority(.required, for: .vertical)
        let heading = UIStackView(arrangedSubviews: [icon, caption])
        heading.axis = .horizontal; heading.alignment = .center; heading.spacing = 12
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.accessibilityLabel = title; heading.addArrangedSubview(control)
        } else if disclosure {
            let arrow = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
            arrow.tintColor = .tertiaryLabel; arrow.contentMode = .scaleAspectFit
            arrow.widthAnchor.constraint(equalToConstant: 12).isActive = true
            heading.addArrangedSubview(arrow)
        }
        let stack = UIStackView(arrangedSubviews: [heading])
        stack.axis = .vertical; stack.spacing = 7
        if let detail, !detail.isEmpty {
            let label = self.detailLabel
            label.text = detail; label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .footnote); label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0; label.lineBreakMode = .byWordWrapping
            label.accessibilityIdentifier = "CodeGram.detail"
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            stack.addArrangedSubview(label)
        }
        self.install(stack)
        if control == nil {
            self.isAccessibilityElement = true
            self.accessibilityLabel = [title, detail].compactMap { $0 }.joined(separator: ", ")
            self.accessibilityTraits = disclosure ? .button : .staticText
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateWrappingWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let accessory = self.headingControl.map { max(0, $0.intrinsicContentSize.width) } ?? (self.showsDisclosure ? 12 : 0)
        self.setWrappingWidth(width - 32 - self.iconWidth - 12 - (accessory > 0 ? accessory + 12 : 0), for: self.caption)
        self.setWrappingWidth(width - 32, for: self.detailLabel)
    }
}

final class CodeGramFieldCell: CodeGramSurfaceCell {
    init(field: UITextField, symbol: String) {
        super.init(style: .default, reuseIdentifier: nil)
        field.removeFromSuperview()
        field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        let icon = UIImageView(image: CodeGramSettingsTheme.symbol(symbol))
        icon.contentMode = .scaleAspectFit; icon.tintColor = .label
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let stack = UIStackView(arrangedSubviews: [icon, field])
        stack.axis = .horizontal; stack.alignment = .center; stack.spacing = 12
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        self.install(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class CodeGramSliderCell: CodeGramSurfaceCell {
    private let caption = UILabel()
    private let valueLabel = UILabel()
    private let slider = CodeGramValueSlider()
    private let changed: (Double) -> Void
    private let format: (Double) -> String
    init(title: String, symbol: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String, changed: @escaping (Double) -> Void) {
        self.changed = changed; self.format = format
        super.init(style: .default, reuseIdentifier: nil)
        let icon = UIImageView(image: CodeGramSettingsTheme.symbol(symbol))
        icon.contentMode = .scaleAspectFit; icon.tintColor = .label
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let caption = self.caption
        caption.text = title; caption.textColor = .label; caption.numberOfLines = 0; caption.lineBreakMode = .byWordWrapping
        caption.font = .preferredFont(forTextStyle: .body); caption.adjustsFontForContentSizeCategory = true
        caption.accessibilityIdentifier = "CodeGram.title"
        self.valueLabel.font = .preferredFont(forTextStyle: .footnote); self.valueLabel.adjustsFontForContentSizeCategory = true
        self.valueLabel.textColor = .secondaryLabel; self.valueLabel.numberOfLines = 0; self.valueLabel.text = format(value)
        self.valueLabel.accessibilityIdentifier = "CodeGram.detail"
        let labels = UIStackView(arrangedSubviews: [caption, self.valueLabel])
        labels.axis = .vertical; labels.spacing = 3
        let heading = UIStackView(arrangedSubviews: [icon, labels])
        heading.axis = .horizontal; heading.alignment = .center; heading.spacing = 12
        self.slider.minimumValue = Float(range.lowerBound); self.slider.maximumValue = Float(range.upperBound)
        self.slider.value = Float(value); self.slider.tintColor = .label
        self.slider.accessibilityLabel = title; self.slider.accessibilityValue = format(value)
        self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [heading, self.slider])
        stack.axis = .vertical; stack.spacing = 8
        self.install(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateWrappingWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        self.setWrappingWidth(width - 72, for: self.caption)
        self.setWrappingWidth(width - 72, for: self.valueLabel)
    }
    @objc private func valueChanged() {
        let value = Double(self.slider.value)
        self.valueLabel.text = self.format(value); self.slider.accessibilityValue = self.format(value)
        self.changed(value)
    }
}

