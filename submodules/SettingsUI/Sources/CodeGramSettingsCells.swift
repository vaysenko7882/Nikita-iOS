import UIKit

/// Complete constraints from the cell to every visible label let UITableView
/// measure multiline switch rows instead of overflowing a fixed-height row.
class CodeGramGlassCell: UITableViewCell {
    let glass = CodeGramMaterialView(radius: 22)
    let bodyView = UIView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        CodeGramSettingsTheme.prepare(self)
        self.clipsToBounds = false; self.contentView.clipsToBounds = false
        self.contentView.addSubview(self.glass)
        self.glass.contentView.addSubview(self.bodyView)
        self.glass.translatesAutoresizingMaskIntoConstraints = false
        self.bodyView.translatesAutoresizingMaskIntoConstraints = false
        let minimum = self.glass.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        minimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            self.glass.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 4),
            self.glass.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -4),
            self.glass.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            self.glass.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.bodyView.topAnchor.constraint(equalTo: self.glass.topAnchor),
            self.bodyView.bottomAnchor.constraint(equalTo: self.glass.bottomAnchor),
            self.bodyView.leadingAnchor.constraint(equalTo: self.glass.leadingAnchor),
            self.bodyView.trailingAnchor.constraint(equalTo: self.glass.trailingAnchor), minimum
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func updateWrappingWidth(_ width: CGFloat) {}
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        // A glass content host has no intrinsic width while UITableView performs
        // its fitting pass. Give multiline labels their final wrapping width
        // before asking Auto Layout for the height.
        self.updateWrappingWidth(targetSize.width)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.updateWrappingWidth(self.contentView.bounds.width)
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
        self.addTarget(self, action: #selector(self.updateValue), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func updateValue() { self.changed?(self.isOn) }
}

final class CodeGramTextCell: CodeGramGlassCell {
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
        self.caption.preferredMaxLayoutWidth = max(1, width - 32 - self.iconWidth - 12 - (accessory > 0 ? accessory + 12 : 0))
        self.detailLabel.preferredMaxLayoutWidth = max(1, width - 32)
    }
}

final class CodeGramFieldCell: CodeGramGlassCell {
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

final class CodeGramSliderCell: CodeGramGlassCell {
    private let caption = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
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
        self.caption.preferredMaxLayoutWidth = max(1, width - 72)
        self.valueLabel.preferredMaxLayoutWidth = max(1, width - 72)
    }
    @objc private func valueChanged() {
        let value = Double(self.slider.value)
        self.valueLabel.text = self.format(value); self.slider.accessibilityValue = self.format(value)
        self.changed(value)
    }
}
