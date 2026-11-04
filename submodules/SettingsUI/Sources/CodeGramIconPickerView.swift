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

/// The carousel and its short background accents do no work while idle.
final class CodeGramIconPickerView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let pageControl = UIPageControl()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let applyButton = UIButton(type: .system)
    /// Shared with the native fixture; the visual page interval is not an API constant.
    let pageStride: CGFloat = 210
    private let heroScrollView = UIScrollView()
    private let effectsView = CodeGramIconBackdropView(frame: .zero)
    private let brandLabel = UILabel()
    private var images: [UIButton] = []
    private var previousWidth: CGFloat = 0
    private var previousSize = CGSize.zero
    private var effectsVisible = true
    private var lastEffectIndex: Int
    private var observers: [NSObjectProtocol] = []
    private(set) var selectedIndex: Int
    private var appliedName: String?
    private var busy = false
    private var buttonState = ""
    var onApply: ((CodeGramAppIconChoice) -> Void)?
    var onSelection: ((CodeGramAppIconChoice) -> Void)?
    var onPalette: ((UIColor) -> Void)?
    var bottomInset: CGFloat = 0 { didSet { if oldValue != self.bottomInset { self.setNeedsLayout() } } }
    var activeBackgroundLayerCount: Int { self.effectsView.activeLayerCount }
    var lastBackgroundEffectName: String? { self.effectsView.lastEffectName }

    init(currentName: String?) {
        self.appliedName = currentName
        self.selectedIndex = CodeGramAppIconChoice.all.firstIndex(where: { $0.name == currentName }) ?? 0
        self.lastEffectIndex = self.selectedIndex
        super.init(frame: .zero)
        self.backgroundColor = CodeGramAppIconChoice.all[self.selectedIndex].background
        self.accessibilityIdentifier = "CodeGram.iconPicker"
        self.effectsView.isUserInteractionEnabled = false
        self.addSubview(self.effectsView)
        CodeGramSettingsTheme.disableScrollEdgeEffects(self.heroScrollView)
        self.heroScrollView.contentInsetAdjustmentBehavior = .never
        self.heroScrollView.showsVerticalScrollIndicator = false
        self.heroScrollView.alwaysBounceVertical = false
        self.heroScrollView.isDirectionalLockEnabled = true
        self.addSubview(self.heroScrollView)
        CodeGramSettingsTheme.disableScrollEdgeEffects(self.scrollView)
        self.scrollView.delegate = self
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.decelerationRate = .fast
        self.scrollView.alwaysBounceHorizontal = true
        self.scrollView.isDirectionalLockEnabled = true
        self.scrollView.accessibilityIdentifier = "CodeGram.iconCarousel"
        self.heroScrollView.addSubview(self.scrollView)
        for (index, choice) in CodeGramAppIconChoice.all.enumerated() {
            let button = UIButton(type: .custom)
            button.setImage(UIImage(named: choice.previewName), for: .normal)
            button.imageView?.contentMode = .scaleAspectFill
            button.layer.cornerRadius = 38
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
            self.heroScrollView.addSubview(label)
        }
        // The instruction and Apply stay at the bottom; only the hero can
        // scroll on a short display or at the largest accessibility sizes.
        self.detailLabel.removeFromSuperview()
        self.addSubview(self.detailLabel)
        self.heroScrollView.addSubview(self.pageControl)
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 26, bottom: 16, trailing: 26)
        self.applyButton.configuration = configuration
        self.applyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.applyButton.addTarget(self, action: #selector(self.applyPressed), for: .touchUpInside)
        self.applyButton.accessibilityIdentifier = "CodeGram.applyAppIcon"
        self.applyButton.accessibilityHint = self.detailLabel.text
        self.addSubview(self.applyButton)
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.effectsView.stop()
            })
        }
        self.observers.append(center.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buttonState = ""
            self?.setNeedsLayout()
        })
        self.updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.observers.forEach(NotificationCenter.default.removeObserver) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil { self.effectsView.stop() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = self.bounds.width
        guard width > 0, self.bounds.height > 0 else { return }
        if self.previousSize != self.bounds.size {
            self.previousSize = self.bounds.size
            self.effectsView.stop()
        }
        let side = max(24, max(self.safeAreaInsets.left, self.safeAreaInsets.right) + 16)
        let contentWidth = min(560, max(1, width - side * 2))
        let x = (width - contentWidth) * 0.5
        let safeBottom = max(self.safeAreaInsets.bottom, self.bottomInset)
        self.updateApplyButton(index: self.selectedIndex)
        let buttonSize = self.applyButton.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let buttonHeight = max(56, buttonSize.height)
        let buttonY = max(self.safeAreaInsets.top + 16, self.bounds.height - safeBottom - 18 - buttonHeight)
        self.applyButton.frame = CGRect(x: x, y: buttonY, width: contentWidth, height: buttonHeight)
        let detailSize = self.detailLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let showsInstruction = self.bounds.height - safeBottom >= buttonHeight + detailSize.height + 300
        self.detailLabel.isHidden = !showsInstruction
        self.detailLabel.frame = CGRect(x: x, y: buttonY - 16 - (showsInstruction ? detailSize.height : 0), width: contentWidth, height: showsInstruction ? detailSize.height : 0)
        let heroTop = self.safeAreaInsets.top
        let footerTop = showsInstruction ? self.detailLabel.frame.minY : self.applyButton.frame.minY
        let heroHeight = max(0, footerTop - 24 - heroTop)
        self.heroScrollView.frame = CGRect(x: 0, y: heroTop, width: width, height: heroHeight)
        self.effectsView.frame = self.heroScrollView.frame
        let previewSize = min(176, max(112, heroHeight * 0.55))
        let carouselHeight = previewSize + 52
        let carouselY = max(20, heroHeight * 0.46 - carouselHeight * 0.5)
        self.scrollView.frame = CGRect(x: 0, y: carouselY, width: width, height: carouselHeight)
        let inset = max(0, (width - self.pageStride) / 2)
        let contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        if self.scrollView.contentInset != contentInset { self.scrollView.contentInset = contentInset }
        let contentSize = CGSize(width: self.pageStride * CGFloat(self.images.count), height: carouselHeight)
        if self.scrollView.contentSize != contentSize { self.scrollView.contentSize = contentSize }
        for (index, image) in self.images.enumerated() {
            image.transform = .identity
            image.bounds = CGRect(x: 0, y: 0, width: previewSize, height: previewSize)
            image.center = CGPoint(x: CGFloat(index) * self.pageStride + self.pageStride / 2, y: carouselHeight * 0.5)
        }
        if self.previousWidth != width {
            self.previousWidth = width
            self.scrollView.setContentOffset(CGPoint(x: CGFloat(self.selectedIndex) * self.pageStride - inset, y: 0), animated: false)
        }
        var y = self.scrollView.frame.maxY + 12
        for label in [self.brandLabel, self.titleLabel] {
            let size = label.sizeThatFits(CGSize(width: max(1, width - 48), height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: 24, y: y, width: max(0, width - 48), height: size.height)
            y += size.height + 8
        }
        self.pageControl.frame = CGRect(x: 16, y: y, width: max(0, width - 32), height: 30)
        self.heroScrollView.contentSize = CGSize(width: width, height: max(heroHeight, self.pageControl.frame.maxY + 16))
        self.updateAppearance()
    }

    func select(index: Int, animated: Bool) {
        let index = max(0, min(self.images.count - 1, index))
        self.effectsView.stop()
        let animate = animated && !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
        self.scrollView.setContentOffset(CGPoint(x: CGFloat(index) * self.pageStride - self.scrollView.contentInset.left, y: 0), animated: animate)
        if !animate { self.updateAppearance(); self.playSelectionEffect() }
    }
    func setEffectsVisible(_ visible: Bool) {
        self.effectsVisible = visible
        if !visible { self.effectsView.stop() }
    }
    func setApplying(_ applying: Bool, appliedName: String? = nil, succeeded: Bool = false) {
        self.busy = applying
        if succeeded { self.appliedName = appliedName }
        self.updateAppearance()
    }
    @objc private func iconTapped(_ sender: UIButton) { self.select(index: sender.tag, animated: true) }
    @objc private func pageChanged() { self.select(index: self.pageControl.currentPage, animated: true) }
    @objc private func applyPressed() {
        guard !self.busy, CodeGramAppIconChoice.all[self.selectedIndex].name != self.appliedName else { return }
        self.onApply?(CodeGramAppIconChoice.all[self.selectedIndex])
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { self.updateAppearance() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { self.effectsView.stop() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { self.playSelectionEffect() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { self.playSelectionEffect() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { self.playSelectionEffect() }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let position = (targetContentOffset.pointee.x + scrollView.contentInset.left) / self.pageStride
        let index = max(0, min(self.images.count - 1, Int(position.rounded())))
        targetContentOffset.pointee.x = CGFloat(index) * self.pageStride - scrollView.contentInset.left
    }
    private func playSelectionEffect() {
        guard self.lastEffectIndex != self.selectedIndex else { return }
        self.lastEffectIndex = self.selectedIndex
        guard self.effectsVisible, self.window != nil, UIApplication.shared.applicationState == .active,
            !UIAccessibility.isReduceMotionEnabled, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let rect = self.scrollView.convert(self.scrollView.bounds, to: self.effectsView)
        self.effectsView.play(choice: CodeGramAppIconChoice.all[self.selectedIndex], center: CGPoint(x: rect.midX, y: rect.midY))
    }
    private func updateAppearance() {
        guard !self.images.isEmpty, self.previousWidth > 0 else { return }
        let position = max(0, min(CGFloat(self.images.count - 1), (self.scrollView.contentOffset.x + self.scrollView.contentInset.left) / self.pageStride))
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
        self.updateApplyButton(index: index)
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

    private func updateApplyButton(index: Int) {
        let choice = CodeGramAppIconChoice.all[index]
        let buttonState = "\(index):\(self.busy):\(self.appliedName ?? "default")"
        if self.buttonState != buttonState {
            self.buttonState = buttonState
            var configuration = self.applyButton.configuration
            configuration?.baseBackgroundColor = choice.light ? .black : .white
            configuration?.background.visualEffect = nil
            configuration?.background.backgroundColor = choice.light ? .black : .white
            configuration?.baseForegroundColor = choice.background
            configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.foregroundColor = choice.background
                attributes.font = UIFont.preferredFont(forTextStyle: .headline)
                return attributes
            }
            configuration?.titleLineBreakMode = .byWordWrapping
            configuration?.titleAlignment = .center
            configuration?.title = self.busy ? "Применяю…" : choice.name == self.appliedName ? "Установлена" : "Использовать эту иконку"
            self.applyButton.configuration = configuration
            self.applyButton.isEnabled = !self.busy && choice.name != self.appliedName
        }
    }
}

/// Small vector accents with a finite lifetime. No blur, refraction, images
/// sampled each frame, display link, repeating emitter or idle animation.
private final class CodeGramIconBackdropView: UIView {
    private var effectLayer: CALayer?
    private var cleanup: DispatchWorkItem?
    private var generation = 0
    private(set) var lastEffectName: String?
    var activeLayerCount: Int { self.effectLayer?.sublayers?.count ?? 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.cleanup?.cancel() }

    func stop() {
        self.generation += 1
        self.cleanup?.cancel()
        self.cleanup = nil
        self.effectLayer?.removeAllAnimations()
        self.effectLayer?.removeFromSuperlayer()
        self.effectLayer = nil
    }

    func play(choice: CodeGramAppIconChoice, center: CGPoint) {
        self.stop()
        guard self.bounds.width > 0, self.bounds.height > 0, center.x.isFinite, center.y.isFinite else { return }
        let host = CALayer()
        host.frame = self.bounds
        self.layer.addSublayer(host)
        self.effectLayer = host
        self.lastEffectName = choice.name ?? "CGOriginal"
        let color: UIColor = choice.light ? .black : .white
        let center = CGPoint(x: self.bounds.midX, y: max(70, min(self.bounds.height - 70, center.y)))
        let span = min(self.bounds.width * 0.7, 340)

        func add(_ layer: CALayer) {
            layer.opacity = 0
            host.addSublayer(layer)
        }
        func animate(_ layer: CALayer, _ movements: [CAAnimation] = [], delay: Double = 0, duration: Double = 0.85, strength: Double = 0.2) {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, strength, strength * 0.7, 0]
            opacity.keyTimes = [0, 0.16, 0.65, 1]
            let group = CAAnimationGroup()
            let animations = [opacity] + movements
            for animation in animations { animation.duration = duration }
            group.animations = animations
            group.duration = duration
            group.beginTime = CACurrentMediaTime() + delay
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            layer.add(group, forKey: "CodeGram.iconAccent")
        }
        func travel(_ key: String, _ from: CGFloat, _ to: CGFloat) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            return animation
        }
        func line(_ path: UIBezierPath, width: CGFloat = 2) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.frame = self.bounds
            layer.path = path.cgPath
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            add(layer)
            return layer
        }

        switch choice.name ?? "CGOriginal" {
        case "CGPixel":
            let tile: CGFloat = 26
            for row in 0 ..< 5 {
                for column in 0 ..< 7 {
                    let layer = CALayer()
                    layer.frame = CGRect(x: center.x + CGFloat(column - 3) * 46 - tile / 2,
                        y: center.y + CGFloat(row - 2) * 46 - tile / 2, width: tile, height: tile)
                    layer.backgroundColor = (row + column).isMultiple(of: 3) ? UIColor.systemPink.cgColor : color.cgColor
                    add(layer)
                    let opacity = CAKeyframeAnimation(keyPath: "opacity")
                    opacity.values = [0, 0.22, 0.1, 0]
                    opacity.keyTimes = [0, 0.12, 0.7, 1]
                    opacity.calculationMode = .discrete
                    let scale = travel("transform.scale", 0.45, 1)
                    opacity.duration = 0.7
                    scale.duration = 0.7
                    let group = CAAnimationGroup()
                    group.animations = [opacity, scale]
                    group.duration = 0.7
                    group.beginTime = CACurrentMediaTime() + Double((row * 3 + column) % 7) * 0.035
                    group.isRemovedOnCompletion = false
                    group.fillMode = .forwards
                    layer.add(group, forKey: "CodeGram.pixelAccent")
                }
            }
        case "CGPaper":
            for i in 0 ..< 7 {
                let layer = CAShapeLayer()
                let rect = CGRect(x: center.x - span / 2 + CGFloat(i) * span / 7,
                    y: center.y - 110 + CGFloat(i % 2) * 20, width: span / 9, height: 220)
                layer.frame = rect
                let path = UIBezierPath()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: rect.width, y: 12))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height))
                path.addLine(to: CGPoint(x: 0, y: rect.height - 12))
                path.close()
                layer.path = path.cgPath
                layer.fillColor = color.cgColor
                add(layer)
                animate(layer, [travel("transform.rotation.z", i.isMultiple(of: 2) ? -0.12 : 0.12, 0),
                    travel("transform.translation.y", 24, -10)], delay: Double(i) * 0.035, strength: 0.1)
            }
        case "CGChrome":
            for i in 0 ..< 3 {
                let layer = CAGradientLayer()
                layer.frame = CGRect(x: center.x - 45, y: center.y - 145, width: 90, height: 290)
                layer.colors = [UIColor.clear.cgColor, color.cgColor, UIColor.clear.cgColor]
                layer.locations = [0, 0.5, 1]
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
                layer.transform = CATransform3DMakeRotation(-0.4, 0, 0, 1)
                add(layer)
                animate(layer, [travel("transform.translation.x", -span * 0.7, span * 0.7)],
                    delay: Double(i) * 0.08, duration: 0.8, strength: 0.24 - Double(i) * 0.05)
            }
        case "CGEcho":
            for i in 0 ..< 3 {
                let layer = CAShapeLayer()
                layer.bounds = CGRect(x: 0, y: 0, width: 130, height: 130)
                layer.position = center
                layer.path = UIBezierPath(ovalIn: layer.bounds.insetBy(dx: 2, dy: 2)).cgPath
                layer.fillColor = UIColor.clear.cgColor
                layer.strokeColor = color.cgColor
                layer.lineWidth = 1.5
                add(layer)
                animate(layer, [travel("transform.scale", 0.75, 2.4)], delay: Double(i) * 0.1, strength: 0.24)
            }
        case "CGRift":
            for i in 0 ..< 10 {
                let left = i.isMultiple(of: 2)
                let layer = CALayer()
                layer.frame = CGRect(x: center.x + (left ? -span / 2 : 24),
                    y: center.y - 100 + CGFloat(i / 2) * 42, width: span / 2 - 24, height: 3)
                layer.backgroundColor = color.cgColor
                add(layer)
                animate(layer, [travel("transform.translation.x", left ? 18 : -18, left ? -38 : 38),
                    travel("transform.translation.y", 8, -8)], delay: Double(i / 2) * 0.035, strength: 0.2)
            }
        case "CGSlice":
            for i in 0 ..< 6 {
                let layer = CALayer()
                layer.frame = CGRect(x: center.x - span / 2 + CGFloat(i) * 46,
                    y: center.y - 80, width: 5, height: 160)
                layer.backgroundColor = color.cgColor
                layer.transform = CATransform3DMakeRotation(0.55, 0, 0, 1)
                layer.cornerRadius = 2.5
                add(layer)
                animate(layer, [travel("transform.translation.x", -35, 35),
                    travel("transform.translation.y", 30, -30)], delay: Double(i) * 0.035, strength: 0.2)
            }
        case "CGStairs":
            for i in 0 ..< 9 {
                let height = CGFloat(i + 1) * 24
                let layer = CALayer()
                layer.frame = CGRect(x: center.x - 156 + CGFloat(i) * 36,
                    y: center.y + 108 - height, width: 22, height: height)
                layer.backgroundColor = color.cgColor
                layer.cornerRadius = 3
                add(layer)
                animate(layer, [travel("transform.translation.y", 24, 0)], delay: Double(i) * 0.045, strength: 0.13)
            }
        case "CGClip":
            let path = UIBezierPath()
            path.move(to: CGPoint(x: center.x - 62, y: center.y + 80))
            path.addLine(to: CGPoint(x: center.x + 40, y: center.y - 54))
            path.addCurve(to: CGPoint(x: center.x + 82, y: center.y - 25),
                controlPoint1: CGPoint(x: center.x + 78, y: center.y - 104),
                controlPoint2: CGPoint(x: center.x + 124, y: center.y - 74))
            path.addLine(to: CGPoint(x: center.x - 18, y: center.y + 110))
            path.addCurve(to: CGPoint(x: center.x - 96, y: center.y + 54),
                controlPoint1: CGPoint(x: center.x - 64, y: center.y + 170),
                controlPoint2: CGPoint(x: center.x - 142, y: center.y + 116))
            path.addLine(to: CGPoint(x: center.x + 2, y: center.y - 76))
            let layer = line(path, width: 2.5)
            animate(layer, [travel("strokeEnd", 0, 1)], duration: 1, strength: 0.3)
        default:
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
            layer.position = center
            layer.path = UIBezierPath(roundedRect: layer.bounds.insetBy(dx: 2, dy: 2), cornerRadius: 56).cgPath
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = 2
            add(layer)
            animate(layer, [travel("transform.scale", 0.7, 1.35)], strength: 0.16)
        }
        let generation = self.generation
        let cleanup = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.stop()
        }
        self.cleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: cleanup)
    }
}

