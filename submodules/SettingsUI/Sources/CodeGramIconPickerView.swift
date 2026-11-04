import UIKit

struct CodeGramAppIconChoice {
    let name: String?
    let title: String
    let background: UIColor
    let light: Bool
    var previewName: String { (self.name ?? "CGOriginal") + "Preview" }
    static let all: [CodeGramAppIconChoice] = [
        .init(name: nil, title: "Оригинал", background: .black, light: false),
        .init(name: "CGClip", title: "Скрепка", background: UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1), light: false),
        .init(name: "CGPaper", title: "Бумага", background: UIColor(red: 0.98, green: 0.94, blue: 0.88, alpha: 1), light: true),
        .init(name: "CGEcho", title: "Эхо", background: UIColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1), light: false),
        .init(name: "CGRift", title: "Разлом", background: UIColor(red: 0.03, green: 0.09, blue: 0.02, alpha: 1), light: false),
        .init(name: "CGSlice", title: "Разрез", background: UIColor(red: 0.15, green: 0.02, blue: 0.03, alpha: 1), light: false),
        .init(name: "CGPixel", title: "Пиксели", background: UIColor(red: 0.12, green: 0.02, blue: 0.05, alpha: 1), light: false),
        .init(name: "CGChrome", title: "Хром", background: UIColor(red: 0.65, green: 0.02, blue: 0.03, alpha: 1), light: false),
        .init(name: "CGStairs", title: "Лестницы", background: UIColor(red: 0.09, green: 0.08, blue: 0.06, alpha: 1), light: false)
    ]
}

/// Preview work follows native scrolling; no display links, looping effects or timers.
final class CodeGramIconPickerView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let pageControl = UIPageControl()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let applyButton = UIButton(type: .system)
    private let brandLabel = UILabel()
    private var images: [UIButton] = []
    private let stride: CGFloat = 156
    private var previousWidth: CGFloat = 0
    private(set) var selectedIndex: Int
    private var appliedName: String?
    private var busy = false
    private var buttonState = ""
    var onApply: ((CodeGramAppIconChoice) -> Void)?
    var onSelection: ((CodeGramAppIconChoice) -> Void)?
    var onPalette: ((UIColor) -> Void)?

    init(currentName: String?) {
        self.appliedName = currentName
        self.selectedIndex = CodeGramAppIconChoice.all.firstIndex(where: { $0.name == currentName }) ?? 0
        super.init(frame: .zero)
        self.backgroundColor = CodeGramAppIconChoice.all[self.selectedIndex].background
        self.accessibilityIdentifier = "CodeGram.iconPicker"
        CodeGramSettingsTheme.disableScrollEdgeEffects(self.scrollView)
        self.scrollView.delegate = self
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.decelerationRate = .fast
        self.scrollView.alwaysBounceHorizontal = true
        self.scrollView.accessibilityIdentifier = "CodeGram.iconCarousel"
        self.addSubview(self.scrollView)
        for (index, choice) in CodeGramAppIconChoice.all.enumerated() {
            let button = UIButton(type: .custom)
            button.setImage(UIImage(named: choice.previewName), for: .normal)
            button.imageView?.contentMode = .scaleAspectFill
            button.layer.cornerRadius = 29
            button.layer.cornerCurve = .continuous
            button.clipsToBounds = true
            button.tag = index
            button.accessibilityLabel = choice.title
            button.accessibilityIdentifier = "CodeGram.appIcon.\(choice.name ?? "default")"
            button.addTarget(self, action: #selector(self.iconTapped(_:)), for: .touchUpInside)
            self.images.append(button)
            self.scrollView.addSubview(button)
        }
        self.pageControl.numberOfPages = self.images.count
        self.pageControl.backgroundStyle = .minimal
        self.pageControl.allowsContinuousInteraction = false
        self.pageControl.addTarget(self, action: #selector(self.pageChanged), for: .valueChanged)
        self.brandLabel.text = "CodeGram"
        self.brandLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .bold))
        self.titleLabel.font = .preferredFont(forTextStyle: .title2)
        self.titleLabel.text = CodeGramAppIconChoice.all[self.selectedIndex].title
        self.detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        self.detailLabel.text = "Листай и выбирай свою иконку"
        for label in [self.brandLabel, self.titleLabel, self.detailLabel] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            self.addSubview(label)
        }
        self.addSubview(self.pageControl)
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 26, bottom: 16, trailing: 26)
        self.applyButton.configuration = configuration
        self.applyButton.addTarget(self, action: #selector(self.applyPressed), for: .touchUpInside)
        self.applyButton.accessibilityIdentifier = "CodeGram.applyAppIcon"
        self.addSubview(self.applyButton)
        self.updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = self.bounds.width
        let top = max(28, min(90, self.bounds.height * 0.12))
        self.scrollView.frame = CGRect(x: 0, y: top, width: width, height: 174)
        let inset = max(0, (width - self.stride) / 2)
        let contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        if self.scrollView.contentInset != contentInset { self.scrollView.contentInset = contentInset }
        let contentSize = CGSize(width: self.stride * CGFloat(self.images.count), height: 174)
        if self.scrollView.contentSize != contentSize { self.scrollView.contentSize = contentSize }
        for (index, image) in self.images.enumerated() {
            image.transform = .identity
            image.bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
            image.center = CGPoint(x: CGFloat(index) * self.stride + self.stride / 2, y: 87)
        }
        if self.previousWidth != width {
            self.previousWidth = width
            self.scrollView.setContentOffset(CGPoint(x: CGFloat(self.selectedIndex) * self.stride - inset, y: 0), animated: false)
        }
        var y = self.scrollView.frame.maxY + 16
        for label in [self.brandLabel, self.titleLabel] {
            let size = label.sizeThatFits(CGSize(width: max(1, width - 48), height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: 24, y: y, width: max(0, width - 48), height: size.height)
            y += size.height + 14
        }
        self.pageControl.frame = CGRect(x: 16, y: y, width: max(0, width - 32), height: 30)
        y += 42
        let detailSize = self.detailLabel.sizeThatFits(CGSize(width: max(1, width - 48), height: .greatestFiniteMagnitude))
        self.detailLabel.frame = CGRect(x: 24, y: y, width: max(0, width - 48), height: detailSize.height)
        y += detailSize.height + 30
        let buttonSize = self.applyButton.sizeThatFits(CGSize(width: max(1, width - 48), height: 100))
        self.applyButton.frame = CGRect(x: 24, y: y, width: max(0, width - 48), height: max(54, buttonSize.height))
        self.updateAppearance()
    }

    func select(index: Int, animated: Bool) {
        let index = max(0, min(self.images.count - 1, index))
        self.scrollView.setContentOffset(CGPoint(x: CGFloat(index) * self.stride - self.scrollView.contentInset.left, y: 0), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }
    func setApplying(_ applying: Bool, appliedName: String? = nil, succeeded: Bool = false) {
        self.busy = applying
        if succeeded { self.appliedName = appliedName }
        self.updateAppearance()
    }
    @objc private func iconTapped(_ sender: UIButton) { self.select(index: sender.tag, animated: true) }
    @objc private func pageChanged() { self.select(index: self.pageControl.currentPage, animated: true) }
    @objc private func applyPressed() {
        guard !self.busy else { return }
        self.onApply?(CodeGramAppIconChoice.all[self.selectedIndex])
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { self.updateAppearance() }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let position = (targetContentOffset.pointee.x + scrollView.contentInset.left) / self.stride
        let index = max(0, min(self.images.count - 1, Int(position.rounded())))
        targetContentOffset.pointee.x = CGFloat(index) * self.stride - scrollView.contentInset.left
    }
    private func updateAppearance() {
        guard !self.images.isEmpty, self.previousWidth > 0 else { return }
        let position = max(0, min(CGFloat(self.images.count - 1), (self.scrollView.contentOffset.x + self.scrollView.contentInset.left) / self.stride))
        let index = Int(position.rounded())
        let lower = Int(position), upper = min(self.images.count - 1, lower + 1)
        let fraction = position - CGFloat(lower)
        func blend(_ a: UIColor, _ b: UIColor) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return UIColor(red: ar+(br-ar)*fraction, green: ag+(bg-ag)*fraction, blue: ab+(bb-ab)*fraction, alpha: 1)
        }
        self.backgroundColor = blend(CodeGramAppIconChoice.all[lower].background, CodeGramAppIconChoice.all[upper].background)
        if let backgroundColor = self.backgroundColor { self.onPalette?(backgroundColor) }
        // Blending black and white text makes it disappear on the intermediate
        // gray background. Keep primary text contrasting throughout the gesture.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        _ = self.backgroundColor?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let foreground: UIColor = luminance > 0.179 ? .black : .white
        for label in [self.brandLabel, self.titleLabel, self.detailLabel] { label.textColor = foreground }
        self.detailLabel.alpha = 0.66
        self.pageControl.currentPageIndicatorTintColor = foreground
        self.pageControl.pageIndicatorTintColor = foreground.withAlphaComponent(0.22)
        let choice = CodeGramAppIconChoice.all[index]
        if self.titleLabel.text != choice.title { self.titleLabel.text = choice.title; self.setNeedsLayout() }
        if self.pageControl.currentPage != index { self.pageControl.currentPage = index }
        let buttonState = "\(index):\(self.busy):\(self.appliedName ?? "default")"
        if self.buttonState != buttonState {
            self.buttonState = buttonState
            var configuration = self.applyButton.configuration
            configuration?.baseBackgroundColor = choice.light ? .black : .white
            configuration?.background.visualEffect = nil
            configuration?.background.backgroundColor = choice.light ? .black : .white
            configuration?.baseForegroundColor = choice.background
            configuration?.title = self.busy ? "Применяю…" : choice.name == self.appliedName ? "Установлена" : "Использовать эту иконку"
            self.applyButton.configuration = configuration
            self.applyButton.isEnabled = !self.busy && choice.name != self.appliedName
        }
        for (i, image) in self.images.enumerated() {
            let distance = min(1, abs(CGFloat(i) - position))
            let scale = 1 - distance * 0.27
            image.transform = CGAffineTransform(scaleX: scale, y: scale)
            image.alpha = 1 - distance * 0.55
            image.accessibilityTraits = i == index ? [.button, .selected] : [.button]
        }
        if self.selectedIndex != index {
            self.selectedIndex = index
            self.onSelection?(choice)
        }
    }
}

