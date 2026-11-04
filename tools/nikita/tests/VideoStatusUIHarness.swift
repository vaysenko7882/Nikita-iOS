import UIKit

private func preserveVideoHarnessException(_ exception: NSException) {
    let value = "\(exception.name.rawValue): \(exception.reason ?? "")\n" + exception.callStackSymbols.joined(separator: "\n")
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? value.write(to: root.appendingPathComponent("uncaught-exception.txt"), atomically: true, encoding: .utf8)
}

private final class VideoStatusHarnessController: UIViewController {
    private let banner = CodeGramSocialVideoStatusView()
    private let editor = UITextView()
    private let conversation = UILabel()
    private let ordinaryAction = UIButton(type: .system)
    private var editorHeight: NSLayoutConstraint?
    private var failures: [String] = []
    private var checks = 0
    private var started = false
    private var primaryCalls = 0
    private var copyCalls = 0
    private var dismissCalls = 0
    private var ordinaryCalls = 0
    private var recordingStyle: UIUserInterfaceStyle = .dark
    private var currentMode: CodeGramSocialVideoStatusView.Mode = .preparing
    private let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.conversation.text = "Чат остаётся доступным\nПодготовка видео идёт в фоне"
        self.conversation.numberOfLines = 0
        self.conversation.font = .preferredFont(forTextStyle: .body)
        self.conversation.textColor = .secondaryLabel
        self.editor.font = .preferredFont(forTextStyle: .body)
        self.editor.adjustsFontForContentSizeCategory = true
        self.editor.backgroundColor = .secondarySystemBackground
        self.editor.textColor = .label
        self.editor.layer.cornerRadius = 18
        self.editor.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        self.editor.accessibilityIdentifier = "CodeGram.fixtureComposer"
        self.ordinaryAction.setTitle("Обычное сообщение", for: .normal)
        self.ordinaryAction.addTarget(self, action: #selector(self.ordinaryPressed), for: .touchUpInside)
        self.view.addSubview(self.conversation); self.view.addSubview(self.ordinaryAction)
        self.view.addSubview(self.editor); self.view.addSubview(self.banner)
        self.editor.translatesAutoresizingMaskIntoConstraints = false
        let height = self.editor.heightAnchor.constraint(equalToConstant: 64)
        self.editorHeight = height
        NSLayoutConstraint.activate([
            self.editor.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            self.editor.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            self.editor.bottomAnchor.constraint(equalTo: self.view.keyboardLayoutGuide.topAnchor, constant: -12),
            height
        ])
        self.banner.layoutChanged = { [weak self] in
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        }
        self.banner.primaryAction = { [weak self] in self?.primaryCalls += 1 }
        self.banner.copyAction = { [weak self] in self?.copyCalls += 1 }
        self.banner.dismissAction = { [weak self] in self?.dismissCalls += 1 }
        self.show(.preparing)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = self.view.safeAreaInsets
        let width = min(640, max(1, self.view.bounds.width - safe.left - safe.right - 32))
        self.banner.frame = CGRect(x: (self.view.bounds.width - width) / 2, y: safe.top + 12, width: width, height: self.banner.preferredHeight(width: width))
        self.banner.layoutIfNeeded()
        self.ordinaryAction.frame = CGRect(x: self.banner.frame.minX, y: self.banner.frame.maxY + 12, width: width, height: 44)
        self.conversation.frame = CGRect(x: self.banner.frame.minX + 8, y: self.ordinaryAction.frame.maxY + 12, width: width - 16, height: 70)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !self.started else { return }
        self.started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.runChecks()
            self.record(style: .dark)
        }
    }
    @objc private func ordinaryPressed() { self.ordinaryCalls += 1 }
    private func expect(_ value: Bool, _ message: String) {
        self.checks += 1
        if !value { self.failures.append(message); FileHandle.standardError.write(Data(("UI REGRESSION: " + message + "\n").utf8)) }
    }
    private func stage(_ name: String) {
        let value: [String: Any] = ["stage": name, "checks": self.checks, "failures": self.failures]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: self.output.appendingPathComponent("runtime-progress.json"), options: .atomic)
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { self.descendants($0) } }
    private func visible(_ view: UIView, in root: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            if current === root { return true }
            node = current.superview
        }
        return false
    }
    private func button(_ id: String, in view: UIView) -> UIButton? { self.descendants(view).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id } }
    private func show(_ mode: CodeGramSocialVideoStatusView.Mode, target: CodeGramSocialVideoStatusView? = nil, count: Int = 1) {
        let target = target ?? self.banner
        let title: String
        let detail: String
        switch mode {
        case .preparing: title = "Готовим видео"; detail = "Можно продолжать переписку"
        case .enqueueing: title = "Отправляем видео"; detail = "Передаём файл в очередь Telegram"
        case .failed: title = "Видео не отправлено"; detail = "TikTok временно недоступен. Можно повторить запрос."
        case .cancelled: title = "Отправка отменена"; detail = "Ссылка доступна для повторной отправки"
        }
        target.update(.init(mode: mode, title: title, detail: detail, count: count), background: .secondarySystemBackground, foreground: .label, secondary: .secondaryLabel, accent: .systemBlue)
        if target === self.banner {
            self.currentMode = mode
            self.view.setNeedsLayout(); self.view.layoutIfNeeded()
        }
    }
    private func expectBanner(_ banner: CodeGramSocialVideoStatusView, mode: CodeGramSocialVideoStatusView.Mode, isNotice: Bool = false, context: String) {
        banner.layoutIfNeeded()
        self.expect(banner.isOpaque && (banner.backgroundColor?.resolvedColor(with: banner.traitCollection).cgColor.alpha ?? 0) > 0.999, "banner is not opaque: \(context)")
        self.expect(abs(banner.layer.cornerRadius - 18) < 0.1, "banner rounding changed: \(context)")
        self.expect(self.descendants(banner).compactMap { $0 as? UIVisualEffectView }.allSatisfy { $0.effect == nil || !self.visible($0, in: banner) }, "banner introduced a glass material: \(context)")
        let primary = self.button("CodeGram.videoSendPrimary", in: banner)
        let copy = self.button("CodeGram.videoSendCopy", in: banner)
        let dismiss = self.button("CodeGram.videoSendDismiss", in: banner)
        self.expect(primary != nil && copy != nil && dismiss != nil, "production status actions missing: \(context)")
        self.expect(primary?.isHidden == (mode == .enqueueing || isNotice), "wrong primary visibility: \(context)")
        let hideCopy = isNotice || (mode != .failed && mode != .cancelled)
        self.expect(copy?.isHidden == hideCopy, "wrong copy visibility: \(context)")
        self.expect(dismiss?.isHidden == (isNotice ? false : hideCopy), "wrong dismiss visibility: \(context)")
        self.expect(primary?.currentTitle == (mode == .failed || mode == .cancelled ? "Повторить" : "Отменить"), "wrong primary title: \(context)")
        for view in self.descendants(banner).filter({ !$0.isHidden }) {
            let rect = view.convert(view.bounds, to: banner)
            self.expect(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width >= 0 && rect.height >= 0, "invalid banner geometry: \(context)")
        }
        if isNotice {
            for spinner in self.descendants(banner).compactMap({ $0 as? UIActivityIndicatorView }) {
                self.expect(!spinner.isAnimating && spinner.isHidden, "queue notice displayed a preparing spinner: \(context)")
            }
        }
        let allActionButtons = [primary, copy, dismiss].compactMap { $0 }
        let actionButtons = allActionButtons.filter { !$0.isHidden }
        for action in actionButtons {
            self.expect(banner.bounds.insetBy(dx: -1, dy: -1).contains(action.convert(action.bounds, to: banner)), "status action outside banner: \(context)")
            self.expect(action.bounds.width >= 44 && action.bounds.height >= 44, "status action has a small touch target: \(context)")
            if let label = action.titleLabel, !(label.text ?? "").isEmpty {
                let needed = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                self.expect(label.bounds.width + 1 >= needed.width && label.bounds.height + 1 >= needed.height, "Dynamic Type action title clipped: \(label.text ?? "") \(context)")
            }
            let point = action.convert(CGPoint(x: action.bounds.midX, y: action.bounds.midY), to: banner)
            let hit = banner.hitTest(point, with: nil)
            self.expect(hit === action || hit?.isDescendant(of: action) == true, "status action does not receive touches: \(context)")
        }
        for index in actionButtons.indices {
            for second in actionButtons.indices where second > index {
                self.expect(!actionButtons[index].convert(actionButtons[index].bounds, to: banner).intersects(actionButtons[second].convert(actionButtons[second].bounds, to: banner)), "status actions overlap: \(context)")
            }
        }
        let previews = self.descendants(banner).compactMap({ $0 as? UILabel }).filter { label in
            !allActionButtons.contains(where: { label.isDescendant(of: $0) })
        }
        self.expect(previews.count >= 2, "missing production status preview labels: \(context)")
        for label in previews {
            let rect = label.convert(label.bounds, to: banner)
            self.expect(banner.bounds.insetBy(dx: -1, dy: -1).contains(rect), "status label outside banner: \(context)")
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            self.expect(label.bounds.height + 1 >= needed.height, "status preview label vertically clipped: \(context)")
            for action in actionButtons { self.expect(!rect.intersects(action.convert(action.bounds, to: banner)), "action overlaps status text: \(context)") }
        }
        if #available(iOS 26.0, *) {
            for scroll in self.descendants(banner).compactMap({ $0 as? UIScrollView }) {
                self.expect([scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect].allSatisfy { $0.isHidden }, "status scroll retained a glass edge: \(context)")
            }
        }
    }
    private func showQueueNotice(target: CodeGramSocialVideoStatusView? = nil) {
        let target = target ?? self.banner
        target.update(.init(mode: .cancelled, title: "Очередь заполнена", detail: "Ссылка осталась в поле. Отправь её позже.", count: 0, isNotice: true), background: .secondarySystemBackground, foreground: .label, secondary: .secondaryLabel, accent: .systemBlue)
        if target === self.banner {
            self.currentMode = .cancelled
            self.view.setNeedsLayout(); self.view.layoutIfNeeded()
        }
    }
    private func expectTyping() {
        self.expect(self.editor.isFirstResponder, "preparing a video dismissed the composer")
        let before = self.editor.text ?? ""
        self.editor.selectedRange = NSRange(location: before.utf16.count, length: 0)
        self.editor.insertText(" Ещё сообщение.")
        self.expect(self.editor.text == before + " Ещё сообщение.", "chat typing failed while status was visible")
        let point = self.editor.convert(CGPoint(x: self.editor.bounds.midX, y: self.editor.bounds.midY), to: self.view)
        let hit = self.view.hitTest(point, with: nil)
        self.expect(hit === self.editor || hit?.isDescendant(of: self.editor) == true, "status overlay intercepted a composer touch: hit=\(String(describing: hit)) point=\(point) editor=\(self.editor.frame) bounds=\(self.editor.bounds)")
        self.expect(!self.banner.frame.intersects(self.editor.frame), "status banner covers the composer")
        self.expect(self.presentedViewController == nil, "status displayed a modal blocker")
    }
    private func runChecks() {
        self.stage("matrix")
        for style in [UIUserInterfaceStyle.dark, .light] {
            for category in [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
                for width in [CGFloat(288), 343, 408, 608] {
                    let traits = UITraitCollection { $0.userInterfaceStyle = style; $0.preferredContentSizeCategory = category }
                    traits.performAsCurrent {
                        let fixture = CodeGramSocialVideoStatusView()
                        fixture.traitOverrides.userInterfaceStyle = style
                        fixture.traitOverrides.preferredContentSizeCategory = category
                        self.view.addSubview(fixture)
                        for mode in [CodeGramSocialVideoStatusView.Mode.preparing, .enqueueing, .failed, .cancelled] {
                            self.show(mode, target: fixture, count: 3)
                            fixture.frame = CGRect(x: 16, y: 120, width: width, height: fixture.preferredHeight(width: width))
                            fixture.layoutIfNeeded()
                            self.expectBanner(fixture, mode: mode, context: "\(width)/\(category.rawValue)/\(style.rawValue)/\(mode)")
                        }
                        self.showQueueNotice(target: fixture)
                        fixture.frame = CGRect(x: 16, y: 120, width: width, height: fixture.preferredHeight(width: width))
                        fixture.layoutIfNeeded()
                        self.expectBanner(fixture, mode: .cancelled, isNotice: true, context: "notice/\(width)/\(category.rawValue)/\(style.rawValue)")
                        fixture.removeFromSuperview()
                    }
                }
            }
        }
        let accessibility = UITraitCollection { $0.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        accessibility.performAsCurrent {
            let fixture = CodeGramSocialVideoStatusView()
            fixture.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            self.view.addSubview(fixture)
            self.show(.failed, target: fixture)
            fixture.frame = CGRect(x: 16, y: 120, width: 288, height: 120)
            fixture.layoutIfNeeded()
            if let scroll = self.descendants(fixture).compactMap({ $0 as? UIScrollView }).first(where: { $0.accessibilityIdentifier == "CodeGram.videoSendScroll" }) {
                self.expect(scroll.contentSize.height > scroll.bounds.height, "capped status does not scroll its AX content")
                for id in ["CodeGram.videoSendPrimary", "CodeGram.videoSendCopy", "CodeGram.videoSendDismiss"] {
                    if let action = self.button(id, in: fixture) {
                        scroll.scrollRectToVisible(action.convert(action.bounds, to: scroll), animated: false)
                        fixture.layoutIfNeeded()
                        let point = action.convert(CGPoint(x: action.bounds.midX, y: action.bounds.midY), to: fixture)
                        let hit = fixture.hitTest(point, with: nil)
                        self.expect(fixture.bounds.contains(point) && (hit === action || hit?.isDescendant(of: action) == true), "capped status action is not reachable: \(id)")
                    } else { self.expect(false, "missing capped production status action") }
                }
            } else { self.expect(false, "missing capped-height production status scroller") }
            fixture.removeFromSuperview()
        }
        var primary = 0, copies = 0, dismissed = 0
        let fixture = CodeGramSocialVideoStatusView()
        self.view.addSubview(fixture)
        fixture.primaryAction = { primary += 1 }; fixture.copyAction = { copies += 1 }; fixture.dismissAction = { dismissed += 1 }
        for mode in [CodeGramSocialVideoStatusView.Mode.preparing, .failed, .cancelled] {
            self.show(mode, target: fixture)
            fixture.frame = CGRect(x: 16, y: 120, width: 320, height: fixture.preferredHeight(width: 320))
            fixture.layoutIfNeeded()
            self.button("CodeGram.videoSendPrimary", in: fixture)?.sendActions(for: .touchUpInside)
            if mode != .preparing {
                self.button("CodeGram.videoSendCopy", in: fixture)?.sendActions(for: .touchUpInside)
                self.button("CodeGram.videoSendDismiss", in: fixture)?.sendActions(for: .touchUpInside)
            }
        }
        self.expect(primary == 3 && copies == 2 && dismissed == 2, "cancel/retry/copy/dismiss callbacks disconnected")
        if let spinner = self.descendants(fixture).compactMap({ $0 as? UIActivityIndicatorView }).first {
            self.show(.preparing, target: fixture)
            if !UIAccessibility.isReduceMotionEnabled && UIApplication.shared.applicationState == .active { self.expect(spinner.isAnimating, "active preparing spinner is not running") }
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            self.expect(!spinner.isAnimating, "spinner continued in the background")
            self.show(.preparing, target: fixture)
            fixture.isHidden = true
            self.expect(!spinner.isAnimating, "hidden status retained spinner animation")
            fixture.isHidden = false
            if !UIAccessibility.isReduceMotionEnabled && UIApplication.shared.applicationState == .active { self.expect(spinner.isAnimating, "visible preparing status did not restart its spinner") }
            fixture.removeFromSuperview()
            self.expect(!spinner.isAnimating, "offscreen status retained spinner animation")
        } else { self.expect(false, "missing production preparing spinner"); fixture.removeFromSuperview() }
    }
    private func phase(_ base: String, after seconds: TimeInterval = 1.5, next: @escaping () -> Void) {
        let name = base + (self.recordingStyle == .dark ? "-dark" : "-light")
        self.stage(name)
        try? name.write(to: self.output.appendingPathComponent("phase.txt"), atomically: true, encoding: .utf8)
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let captured = FileManager.default.fileExists(atPath: self.output.appendingPathComponent("captured-" + name).path)
            if (captured && Date().timeIntervalSince(started) >= seconds) || Date().timeIntervalSince(started) > 90 {
                if !captured { self.expect(false, "Missing native frame: \(name)") }
                timer.invalidate(); next()
            }
        }
    }
    private func record(style: UIUserInterfaceStyle) {
        self.recordingStyle = style
        self.overrideUserInterfaceStyle = style
        self.traitOverrides.preferredContentSizeCategory = .large
        self.editor.font = .preferredFont(forTextStyle: .body)
        self.editorHeight?.constant = 64
        self.editor.text = "https://vt.tiktok.com/example/"
        self.editor.becomeFirstResponder()
        self.show(.preparing, count: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.expectBanner(self.banner, mode: .preparing, context: "recorded preparing")
            self.expectTyping()
            self.ordinaryAction.sendActions(for: .touchUpInside)
            self.expect(self.ordinaryCalls > 0, "chat action stopped while video prepared")
            self.phase("preparing") {
                self.button("CodeGram.videoSendPrimary", in: self.banner)?.sendActions(for: .touchUpInside)
                self.show(.cancelled)
                self.expect(self.primaryCalls > 0, "cancel action did not run")
                self.expectTyping()
                self.phase("cancelled") {
                    self.button("CodeGram.videoSendPrimary", in: self.banner)?.sendActions(for: .touchUpInside)
                    self.show(.enqueueing)
                    self.expectTyping()
                    self.phase("enqueueing") { self.recordFailure() }
                }
            }
        }
    }
    private func recordFailure() {
        self.show(.failed)
        self.expectBanner(self.banner, mode: .failed, context: "recorded error")
        self.button("CodeGram.videoSendCopy", in: self.banner)?.sendActions(for: .touchUpInside)
        self.expect(self.copyCalls > 0, "copy diagnostic action did not run")
        self.expectTyping()
        self.phase("failed") {
            let draft = self.editor.text ?? ""
            self.showQueueNotice()
            self.expect(self.editor.text == draft, "queue-full notice consumed the draft")
            self.expectBanner(self.banner, mode: .cancelled, isNotice: true, context: "queue-full notice")
            self.expectTyping()
            self.phase("queue-full") {
                let dismissed = self.dismissCalls
                let draft = self.editor.text ?? ""
                self.button("CodeGram.videoSendDismiss", in: self.banner)?.sendActions(for: .touchUpInside)
                self.expect(self.dismissCalls == dismissed + 1, "queue notice Close callback did not run")
                self.banner.isHidden = true
                self.expect(self.editor.text == draft, "closing queue notice changed the draft")
                self.expectTyping()
                self.phase("queue-notice-dismissed") {
                    self.banner.isHidden = false
                    self.show(.preparing)
                    self.rotate(to: .landscapeRight) {
                        self.expectTyping()
                        self.expectBanner(self.banner, mode: .preparing, context: "landscape")
                        self.phase("landscape") {
                            self.rotate(to: .portrait) { self.recordAccessibility() }
                        }
                    }
                }
            }
        }
    }
    private func rotate(to orientation: UIInterfaceOrientationMask, next: @escaping () -> Void) {
        self.editor.resignFirstResponder()
        guard let scene = self.view.window?.windowScene else { self.expect(false, "missing scene for rotation"); next(); return }
        self.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
            self.expect(false, "native fixture rotation failed: \(error.localizedDescription)")
        }
        let began = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let landscape = self.view.bounds.width > self.view.bounds.height
            if landscape == (orientation == .landscapeRight) || Date().timeIntervalSince(began) > 8 {
                timer.invalidate()
                self.expect(landscape == (orientation == .landscapeRight), "native viewport did not rotate")
                self.view.setNeedsLayout(); self.view.layoutIfNeeded()
                self.editor.becomeFirstResponder()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            }
        }
    }
    private func recordAccessibility() {
        self.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        self.editor.font = .preferredFont(forTextStyle: .body)
        self.editorHeight?.constant = 100
        self.show(.failed)
        self.view.setNeedsLayout(); self.view.layoutIfNeeded()
        // Production font changes notify their parent on the next main turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.view.setNeedsLayout(); self.view.layoutIfNeeded()
            self.expectBanner(self.banner, mode: .failed, context: "recorded accessibility")
            self.expectTyping()
            self.phase("accessibility") {
                self.button("CodeGram.videoSendDismiss", in: self.banner)?.sendActions(for: .touchUpInside)
                self.banner.isHidden = true
                self.expect(self.dismissCalls > 0, "dismiss action did not run")
                self.expectTyping()
                self.phase("dismissed") {
                    self.banner.isHidden = false
                    if self.recordingStyle == .dark { self.record(style: .light) }
                    else { self.finish() }
                }
            }
        }
    }
    private func finish() {
        self.editor.resignFirstResponder()
        self.stage("complete")
        let report: [String: Any] = ["checks": self.checks, "failures": self.failures, "ios": UIDevice.current.systemVersion, "recorded_styles": ["dark", "light"], "production_sources": ["CodeGramSocialVideoStatusView.swift"], "scope": "Native production sender-only banner, native composer/action hit testing, callbacks, spinner lifecycle, real scene rotation and Dynamic Type; no authenticated download or Telegram delivery"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: self.output.appendingPathComponent("result.json"), options: .atomic)
        }
    }
}

private final class VideoStatusHarnessSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        NSSetUncaughtExceptionHandler(preserveVideoHarnessException)
        let window = UIWindow(windowScene: scene)
        let controller = VideoStatusHarnessController()
        controller.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
    }
}
@main private final class VideoStatusHarnessAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let value = UISceneConfiguration(name: "VideoStatusRegression", sessionRole: connectingSceneSession.role)
        value.delegateClass = VideoStatusHarnessSceneDelegate.self
        return value
    }
}
