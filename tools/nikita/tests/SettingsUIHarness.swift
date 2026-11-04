import UIKit

private let appearanceInfo = "Liquid Glass отключён во всём приложении."
private let badgeInfo = "Показывает капсулу CODEGRAM у выреза экрана. Выключите, чтобы её скрыть."
private let phoneInfo = "Скрывает ваш номер только на экране настроек этого приложения. Настройки видимости номера для других пользователей не меняются."

private func preserveHarnessException(_ exception: NSException) {
    let text = "\(exception.name.rawValue): \(exception.reason ?? "")\n" + exception.callStackSymbols.joined(separator: "\n")
    let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? text.write(to: output.appendingPathComponent("uncaught-exception.txt"), atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

private func toggle(_ value: Bool = true) -> CodeGramValueSwitch {
    let control = CodeGramValueSwitch(); control.isOn = value; return control
}
private func fixtureCells() -> [UITableViewCell] {
    let field = UITextField(); field.placeholder = "Ключ доступа с твоего VPS"
    return [
        CodeGramTextCell(title: "Непрозрачное оформление", detail: appearanceInfo, symbol: "rectangle.on.rectangle"),
        CodeGramTextCell(title: "Показывать в строке статуса", detail: badgeInfo, symbol: "capsule", control: toggle()),
        CodeGramTextCell(title: "Вкладки, профили и истории", symbol: "rectangle.3.group", disclosure: true),
        CodeGramTextCell(title: "Скрывать номер телефона в настройках", detail: phoneInfo, symbol: "phone", control: toggle(false)),
        CodeGramSliderCell(title: "Доля обработанного голоса", symbol: "circle.lefthalf.filled", value: 0.65, range: 0 ... 1, format: { "\(Int($0 * 100))%" }, changed: { _ in }),
        CodeGramFieldCell(field: field, symbol: "key")
    ]
}

private final class FixtureTable: UIViewController, UITableViewDataSource {
    let table = UITableView(frame: .zero, style: .insetGrouped)
    var cells: [UITableViewCell] = []
    override func loadView() {
        self.view = self.table
        CodeGramSettingsTheme.configure(self.table)
        self.table.contentInsetAdjustmentBehavior = .never
        self.table.dataSource = self
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.cells.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { self.cells[indexPath.row] }
    func show(_ cells: [UITableViewCell]) { self.cells = cells; self.table.reloadData(); self.table.layoutIfNeeded() }
}

private final class HarnessController: UIViewController {
    private var failures: [String] = []
    private var checks = 0
    private let table = FixtureTable()
    private let search = CodeGramSearchView()
    private let dashboard = UIScrollView()
    private var cards: [UIView] = []
    private var recordingStyle: UIUserInterfaceStyle = .dark
    private var recordingIconPicker: CodeGramIconPickerView?
    private var didStart = false
    private let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black; self.overrideUserInterfaceStyle = .dark
        self.addChild(self.table); self.view.addSubview(self.table.view); self.table.didMove(toParent: self)
        self.view.addSubview(self.dashboard); self.view.addSubview(self.search)
        CodeGramSettingsTheme.disableScrollEdgeEffects(self.dashboard)
        self.dashboard.isHidden = true; self.search.isHidden = true
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !self.didStart else { return }
        self.didStart = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runChecks(); self.startRecording(style: .dark) }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = self.view.safeAreaInsets.top
        self.table.view.frame = CGRect(x: 0, y: top, width: self.view.bounds.width, height: self.view.bounds.height - top)
        self.dashboard.frame = self.table.view.frame
        self.search.frame = CGRect(x: 16, y: top + 12, width: self.view.bounds.width - 32, height: 54)
    }
    private func expect(_ value: Bool, _ message: String) {
        self.checks += 1
        if !value { self.failures.append(message); print("UI REGRESSION: \(message)") }
    }
    private func stage(_ value: String) {
        let report: [String: Any] = ["stage": value, "checks": self.checks, "failures": self.failures]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: self.output.appendingPathComponent("runtime-progress.json"), options: .atomic)
        }
        FileHandle.standardError.write(Data(("UI HARNESS STAGE: " + value + "\n").utf8))
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { self.descendants($0) } }
    private func isVisible(_ view: UIView, within root: UIView) -> Bool {
        guard view.window != nil else { return false }
        var current: UIView? = view
        var belongsToRoot = false
        while let node = current {
            if node.isHidden || node.alpha < 0.01 { return false }
            if node === root { belongsToRoot = true }
            current = node.superview
        }
        return belongsToRoot
    }
    private func expectSolid(_ surface: CodeGramSurfaceView, context: String) {
        self.expect(surface.isOpaque, "surface must be opaque: \(context)")
        self.expect(abs(surface.alpha - 1) < 0.001, "surface alpha changes its content: \(context)")
        let background = surface.backgroundColor?.resolvedColor(with: surface.traitCollection)
        self.expect((background?.cgColor.alpha ?? 0) > 0.999, "surface has no opaque background: \(context)")
        let activeEffects = self.descendants(surface).compactMap { $0 as? UIVisualEffectView }.filter {
            $0.effect != nil && self.isVisible($0, within: surface)
        }
        self.expect(activeEffects.isEmpty, "visible visual effect inside solid surface: \(context)")
    }
    private func contrast(_ foreground: UIColor, over background: UIColor, traits: UITraitCollection) -> Double {
        func rgba(_ color: UIColor) -> (Double, Double, Double, Double) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return (Double(r), Double(g), Double(b), Double(a))
        }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            let values = [r, g, b].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let (r, g, b, a) = rgba(foreground)
        let (br, bg, bb, _) = rgba(background)
        let text = luminance(r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a))
        let backdrop = luminance(br, bg, bb)
        return (max(text, backdrop) + 0.05) / (min(text, backdrop) + 0.05)
    }
    private func expectPlainScroll(_ scroll: UIScrollView, context: String) {
        if #available(iOS 26.0, *) {
            self.expect([scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect].allSatisfy { $0.isHidden }, "scroll edge effect remains enabled: \(context)")
        }
    }
    private func expectPlainAlert(_ alert: CodeGramPlainAlertController, context: String) {
        alert.view.layoutIfNeeded()
        self.expect(alert.traitCollection.userInterfaceStyle == self.recordingStyle, "alert does not follow the recorded appearance: \(context)")
        guard let panel = self.descendants(alert.view).first(where: { $0.accessibilityIdentifier == "CodeGram.alert.panel" }) else {
            self.expect(false, "missing production alert panel: \(context)")
            return
        }
        self.expect(panel.isOpaque && (panel.backgroundColor?.resolvedColor(with: panel.traitCollection).cgColor.alpha ?? 0) > 0.999, "alert panel is not opaque: \(context)")
        if let scroll = panel.subviews.compactMap({ $0 as? UIScrollView }).first {
            self.expectPlainScroll(scroll, context: context)
        } else { self.expect(false, "missing production dialog scroller: \(context)") }
        self.expect(self.descendants(panel).compactMap { $0 as? UIVisualEffectView }.allSatisfy { $0.effect == nil || !self.isVisible($0, within: panel) }, "alert contains a visible visual effect: \(context)")
        let actionTitles = Set(alert.actions.compactMap { $0.title })
        for button in self.descendants(panel).compactMap({ $0 as? UIButton }).filter({ actionTitles.contains($0.currentTitle ?? "") }) {
            for contentRect in [CGRect.zero, CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: 24, height: 24), CGRect(x: 0, y: 0, width: 25, height: 48), CGRect.null, CGRect.infinite] {
                let rect = button.titleRect(forContentRect: contentRect)
                self.expect(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width >= 0 && rect.height >= 0, "dialog button returned invalid title geometry: \(context)")
            }
        }
        for label in self.descendants(panel).compactMap({ $0 as? UILabel }).filter({ !($0.text ?? "").isEmpty }) {
            let rect = label.convert(label.bounds, to: panel)
            var ancestor = label.superview
            var scroll: UIScrollView?
            while let view = ancestor, view !== panel {
                if let candidate = view as? UIScrollView { scroll = candidate; break }
                ancestor = view.superview
            }
            let insidePanel = panel.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            let scrollable = scroll.map { $0.isScrollEnabled && $0.contentSize.height > $0.bounds.height + 1 && $0.contentLayoutGuide.layoutFrame.insetBy(dx: -1, dy: -1).contains(label.convert(label.bounds, to: $0)) } ?? false
            let insideWidth = rect.minX >= -1 && rect.maxX <= panel.bounds.width + 1
            self.expect(insideWidth && (insidePanel || scrollable), "alert label is neither visible nor reachable by scrolling: \(label.text ?? "") \(context)")
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
            self.expect(label.bounds.height + 1 >= needed, "alert label is clipped: \(label.text ?? "") \(context)")
        }
    }
    private func expectOpaqueBar(_ appearance: UIBarAppearance?, traits: UITraitCollection, context: String) {
        guard let appearance else { self.expect(false, "missing system bar appearance: \(context)"); return }
        self.expect(appearance.backgroundEffect == nil, "system bar has a visual effect: \(context)")
        self.expect((appearance.backgroundColor?.resolvedColor(with: traits).cgColor.alpha ?? 0) > 0.999, "system bar background is not opaque: \(context)")
    }
    private func checkClassicStartup() {
        ClassicDesign.isEnabled = false
        self.expect(ClassicDesign.isEnabled, "saved preference can reactivate glass")
        ClassicDesign.isEnabled = true
        self.expect(ClassicDesign.isEnabled, "classic layout must remain enabled")
        if #available(iOS 26.0, *) {
            let item = UINavigationItem(title: "Native matte policy")
            let left = UIBarButtonItem(title: "Left", style: .plain, target: nil, action: nil)
            let right = UIBarButtonItem(title: "Right", style: .plain, target: nil, action: nil)
            let back = UIBarButtonItem(title: "Back", style: .plain, target: nil, action: nil)
            item.leftBarButtonItem = left
            item.setRightBarButtonItems([right], animated: false)
            item.backBarButtonItem = back
            for button in [left, right, back] {
                self.expect(button.hidesSharedBackground && !button.sharesBackground, "native navigation item retained its glass pill")
            }
            let another = UIBarButtonItem(title: "Another", style: .plain, target: nil, action: nil)
            item.setLeftBarButtonItems([another], animated: false)
            self.expect(another.hidesSharedBackground && !another.sharesBackground, "native left-item array bypassed matte policy")
        }
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        let tabs = UITabBar(frame: CGRect(x: 0, y: 48, width: 320, height: 49))
        self.view.addSubview(toolbar); self.view.addSubview(tabs)
        for style in [UIUserInterfaceStyle.dark, .light] {
            toolbar.overrideUserInterfaceStyle = style; tabs.overrideUserInterfaceStyle = style
            toolbar.layoutIfNeeded(); tabs.layoutIfNeeded()
            self.expect(!toolbar.isTranslucent && !tabs.isTranslucent, "system bars are translucent: \(style.rawValue)")
            self.expectOpaqueBar(toolbar.standardAppearance, traits: toolbar.traitCollection, context: "toolbar/\(style.rawValue)")
            self.expectOpaqueBar(toolbar.scrollEdgeAppearance, traits: toolbar.traitCollection, context: "toolbar edge/\(style.rawValue)")
            self.expectOpaqueBar(tabs.standardAppearance, traits: tabs.traitCollection, context: "tab bar/\(style.rawValue)")
            self.expectOpaqueBar(tabs.scrollEdgeAppearance, traits: tabs.traitCollection, context: "tab bar edge/\(style.rawValue)")
            if let navigation = self.navigationController?.navigationBar {
                navigation.overrideUserInterfaceStyle = style
                self.expect(!navigation.isTranslucent, "navigation bar is translucent: \(style.rawValue)")
                self.expectOpaqueBar(navigation.standardAppearance, traits: navigation.traitCollection, context: "navigation/\(style.rawValue)")
                self.expectOpaqueBar(navigation.scrollEdgeAppearance, traits: navigation.traitCollection, context: "navigation edge/\(style.rawValue)")
            } else { self.expect(false, "missing production startup navigation bar") }
        }
        self.navigationController?.navigationBar.overrideUserInterfaceStyle = .unspecified
        toolbar.removeFromSuperview(); tabs.removeFromSuperview()
    }
    private func runChecks() {
        self.checkClassicStartup()
        self.expectPlainScroll(self.table.table, context: "settings table")
        self.expectPlainScroll(self.dashboard, context: "dashboard")
        for width in [320.0, 375.0, 440.0, 768.0] {
            for category in [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
                for style in [UIUserInterfaceStyle.dark, .light] {
                    autoreleasepool {
                        let traits = UITraitCollection { traits in
                            traits.userInterfaceStyle = style
                            traits.preferredContentSizeCategory = category
                        }
                        let fixture = FixtureTable()
                        self.addChild(fixture)
                        fixture.traitOverrides.userInterfaceStyle = style
                        fixture.traitOverrides.preferredContentSizeCategory = category
                        self.view.addSubview(fixture.view); fixture.didMove(toParent: self)
                        fixture.view.frame = CGRect(x: 0, y: 0, width: width, height: 16000)
                        traits.performAsCurrent { fixture.show(fixtureCells()) }
                        fixture.view.layoutIfNeeded()
                        let context = "\(width)/\(category.rawValue)/\(style.rawValue)"
                        for (index, cell) in fixture.cells.enumerated() {
                            cell.layoutIfNeeded()
                            guard let cell = cell as? CodeGramSurfaceCell else { self.expect(false, "missing production cell"); continue }
                            self.expect(fixture.table.rectForRow(at: IndexPath(row: index, section: 0)).height >= 60, "collapsed row \(index) \(context)")
                            let labels = self.descendants(cell.bodyView).compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier?.hasPrefix("CodeGram.") == true }
                            for label in labels {
                                let rect = label.convert(label.bounds, to: cell.bodyView)
                                self.expect(cell.bodyView.bounds.insetBy(dx: -1, dy: -1).contains(rect), "label outside solid surface: \(label.text ?? "") \(context) \(rect)/\(cell.bodyView.bounds)")
                                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                                self.expect(label.bounds.height + 1 >= needed, "clipped text: \(label.text ?? "") \(context) bounds=\(label.bounds), needed=\(needed), maxWidth=\(label.preferredMaxLayoutWidth)")
                                self.expect(label.isDescendant(of: cell.surface.contentView), "text detached from solid surface")
                                if let foreground = label.textColor, let background = cell.surface.backgroundColor {
                                    let minimum = label.accessibilityIdentifier == "CodeGram.title" ? 4.5 : 3.0
                                    self.expect(self.contrast(foreground, over: background, traits: label.traitCollection) >= minimum, "text lacks contrast on solid surface: \(label.text ?? "") \(context)")
                                }
                            }
                            if labels.count > 1 {
                                let first = labels[0].convert(labels[0].bounds, to: cell.bodyView)
                                let second = labels[1].convert(labels[1].bounds, to: cell.bodyView)
                                self.expect(!first.intersects(second), "overlapping text \(context)")
                            }
                            for control in self.descendants(cell.bodyView).compactMap({ $0 as? UISwitch }) {
                                self.expect(control.bounds.width + 1 >= control.intrinsicContentSize.width, "compressed native switch \(context)")
                                let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: cell)
                                let hit = cell.hitTest(point, with: nil)
                                self.expect(hit === control || hit?.isDescendant(of: control) == true, "switch cannot receive touches \(context)")
                            }
                            self.expectSolid(cell.surface, context: "cell \(index) \(context)")
                        }
                        self.expect(CodeGramSettingsTheme.background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) == .black, "dark backdrop is not black")
                        fixture.willMove(toParent: nil); fixture.view.removeFromSuperview(); fixture.removeFromParent()
                    }
                }
            }
        }
        if let path = Bundle.main.url(forResource: "icons", withExtension: "json"), let data = try? Data(contentsOf: path), let names = try? JSONDecoder().decode([String].self, from: data) {
            for name in names { self.expect(CodeGramSettingsTheme.symbol(name) != nil, "missing SF Symbol: \(name)") }
        } else { self.expect(false, "missing icon manifest") }
        var changed = false
        let control = toggle(); control.changed = { changed = $0 }; control.sendActions(for: .valueChanged)
        self.expect(changed, "switch action disconnected")
        let card = CodeGramDashboardTile(destination: .privacy)
        var opened = false; card.action = { opened = true }
        self.expect(card.accessibilityActivate() && opened, "card action disconnected")
        card.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        self.view.addSubview(card)
        self.search.isHidden = false
        for style in [UIUserInterfaceStyle.dark, .light] {
            card.overrideUserInterfaceStyle = style
            self.search.overrideUserInterfaceStyle = style
            card.layoutIfNeeded(); self.search.layoutIfNeeded()
            self.expectSolid(card, context: "dashboard/\(style.rawValue)")
            self.expectSolid(self.search, context: "search/\(style.rawValue)")
        }
        card.removeFromSuperview()
        self.search.isHidden = true; self.search.overrideUserInterfaceStyle = .unspecified
        self.expect(self.search.textField.isDescendant(of: self.search.contentView), "search detached from solid surface")
        var query: String?
        self.search.onTextChanged = { query = $0 }
        self.search.textField.text = "архив"
        self.search.textField.sendActions(for: .editingChanged)
        self.expect(query == "архив", "plain search text changes are disconnected")
        self.search.cancelButton.sendActions(for: .touchUpInside)
        self.expect(query == "" && (self.search.textField.text ?? "").isEmpty, "plain search cancel does not clear the query")
        self.search.onTextChanged = nil
    }
    private func startRecording(style: UIUserInterfaceStyle) {
        self.recordingStyle = style
        self.overrideUserInterfaceStyle = style
        self.navigationController?.overrideUserInterfaceStyle = style
        self.view.backgroundColor = CodeGramSettingsTheme.background
        self.recordingIconPicker?.removeFromSuperview(); self.recordingIconPicker = nil
        self.cards.forEach { $0.removeFromSuperview() }; self.cards.removeAll()
        self.dashboard.setContentOffset(.zero, animated: false)
        self.dashboard.isHidden = true; self.search.isHidden = true
        self.search.setShowsCancelButton(false, animated: false)
        self.table.view.isHidden = false
        self.showAppearance()
    }
    private func phase(_ baseName: String, after seconds: TimeInterval = 3, next: @escaping () -> Void) {
        let name = baseName + (self.recordingStyle == .dark ? "-dark" : "-light")
        self.stage(name)
        try? name.write(to: self.output.appendingPathComponent("phase.txt"), atomically: true, encoding: .utf8)
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let captured = FileManager.default.fileExists(atPath: self.output.appendingPathComponent("captured-" + name).path)
            if (captured && Date().timeIntervalSince(started) >= seconds) || Date().timeIntervalSince(started) > 120 {
                if !captured { self.expect(false, "Missing recorded phase: \(name)") }
                timer.invalidate(); next()
            }
        }
    }
    private func showAppearance() {
        self.title = "Оформление"
        self.table.show(Array(fixtureCells().prefix(3)))
        self.phase("appearance") { self.showPrivacy() }
    }
    private func showPrivacy() {
        self.title = "Приватность"
        self.table.show([CodeGramTextCell(title: "Режим призрака", symbol: "eye.slash", disclosure: true), fixtureCells()[3]])
        self.phase("privacy") { self.showVoice() }
    }
    private func showVoice() {
        self.title = "Студия голоса"
        self.table.show([
            CodeGramTextCell(title: "Изменять голос", symbol: "mic.badge.plus", control: toggle()),
            CodeGramSliderCell(title: "Высота", symbol: "arrow.up.and.down", value: -6.7, range: -12 ... 12, format: { String(format: "%+.1f полутонов", $0) }, changed: { _ in }),
            CodeGramSliderCell(title: "Тон", symbol: "tuningfork", value: 0, range: -1 ... 1, format: { "\(Int($0 * 100))%" }, changed: { _ in }),
            CodeGramSliderCell(title: "Сила робота", symbol: "cpu", value: 0.25, range: 0 ... 1, format: { "\(Int($0 * 100))%" }, changed: { _ in }),
            CodeGramSliderCell(title: "Частота", symbol: "waveform.path", value: 68, range: 20 ... 160, format: { "\(Int($0)) Гц" }, changed: { _ in })
        ])
        self.phase("voice") { self.showTextEntry() }
    }
    private func showTextEntry() {
        self.stage("text-entry-create")
        let alert = CodeGramPlainAlertController(title: "Свой голос", message: "Название сохранённого пресета", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Название"
            field.text = "Радио"
        }
        var calls = 0
        var continued = false
        func next() {
            guard !continued else { return }
            continued = true
            self.showVideoError()
        }
        alert.addAction(CodeGramPlainAlertAction(title: "Сохранить", style: .default, handler: { [weak alert] _ in
            calls += 1
            self.expect(calls == 1, "plain dialog action ran more than once")
            self.expect(alert?.presentingViewController == nil, "plain dialog action ran before dismissal")
            self.expect(alert?.textFields?.first?.text == "Радио", "weak dialog capture lost entered text after dismissal")
            next()
        }))
        alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel))
        self.stage("text-entry-present")
        self.present(alert, animated: true) {
            self.stage("text-entry-presented")
            alert.textFields?.first?.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.stage("text-entry-check")
                self.expectPlainAlert(alert, context: "text entry")
                self.expect(alert.textFields?.first?.isFirstResponder == true, "plain dialog field could not receive focus")
                self.phase("text-entry", after: 1) {
                    guard let save = self.descendants(alert.view).compactMap({ $0 as? UIButton }).first(where: { $0.titleLabel?.text == "Сохранить" }) else {
                        self.expect(false, "plain dialog Save button is missing")
                        alert.dismiss(animated: false) { next() }
                        return
                    }
                    save.sendActions(for: .touchUpInside)
                    save.sendActions(for: .touchUpInside)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak alert = alert] in
                        if calls == 0 {
                            self.expect(false, "plain dialog Save action was lost")
                            if let alert, alert.presentingViewController != nil {
                                alert.dismiss(animated: false) { next() }
                            } else { next() }
                        }
                    }
                }
            }
        }
    }
    private func showVideoError() {
        self.stage("video-error-create")
        let message = "VPS не смог определить адрес сервера видео. Проверь DNS на VPS.\n\nКод: video_dns_error · VPS: 5.2.0 · Этап: ссылка и DNS · Процесс: 1 · Класс: TransportError\n\nСсылка сохранена в черновике."
        let alert = CodeGramPlainAlertController(title: "Видео не отправлено", message: message, preferredStyle: .alert)
        var copies = 0
        var copied: String?
        var continued = false
        func next() {
            guard !continued else { return }
            continued = true
            self.showMediaActions()
        }
        alert.addAction(CodeGramPlainAlertAction(title: "Скопировать ошибку", style: .default, handler: { [weak alert] _ in
            copies += 1; copied = message
            self.expect(copies == 1 && copied == message, "diagnostic copy action must run once with the displayed message")
            self.expect(alert?.presentingViewController == nil, "diagnostic copy action ran before dismissal")
            next()
        }))
        alert.addAction(CodeGramPlainAlertAction(title: "Оставить черновик", style: .cancel))
        self.expect(alert.actions.map { $0.title ?? "" } == ["Скопировать ошибку", "Оставить черновик"], "video error is missing diagnostic and draft actions")
        self.present(alert, animated: true) {
            self.expectPlainAlert(alert, context: "video error")
            self.phase("video-error", after: 1) {
                guard let button = self.descendants(alert.view).compactMap({ $0 as? UIButton }).first(where: { $0.titleLabel?.text == "Скопировать ошибку" }) else {
                    self.expect(false, "diagnostic copy button is missing")
                    alert.dismiss(animated: false) { next() }
                    return
                }
                if let scroll = self.descendants(alert.view).compactMap({ $0 as? UIScrollView }).first {
                    scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll), animated: false)
                }
                alert.view.layoutIfNeeded()
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: alert.view)
                let hit = alert.view.hitTest(point, with: nil)
                self.expect(hit === button || hit?.isDescendant(of: button) == true, "diagnostic copy button cannot receive touches")
                button.sendActions(for: .touchUpInside)
                button.sendActions(for: .touchUpInside)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak alert = alert] in
                    if copies == 0 {
                        self.expect(false, "diagnostic copy action was lost")
                        if let alert, alert.presentingViewController != nil {
                            alert.dismiss(animated: false) { next() }
                        } else { next() }
                    }
                }
            }
        }
    }
    private func showDashboard() {
        self.title = "CodeGram"
        self.table.view.isHidden = true; self.dashboard.isHidden = false; self.search.isHidden = false
        let width = self.view.bounds.width - 32, half = (width - 10) / 2
        let ghost = CodeGramQuickCard(title: "Призрак", symbol: "codegram.ghost"); ghost.update(isOn: true)
        let archive = CodeGramQuickCard(title: "Архив", symbol: "archivebox"); archive.update(isOn: true)
        ghost.frame = CGRect(x: 16, y: 82, width: half, height: 68); archive.frame = CGRect(x: half + 26, y: 82, width: half, height: 68)
        self.cards = [ghost, archive]
        for (index, destination) in [CodeGramDestination.privacy, .messages, .appearance, .voice].enumerated() {
            let tile = CodeGramDashboardTile(destination: destination)
            let height = tile.preferredHeight(width: half)
            tile.frame = CGRect(x: 16 + CGFloat(index % 2) * (half + 10), y: 160 + CGFloat(index / 2) * (height + 10), width: half, height: height)
            self.cards.append(tile)
        }
        self.cards.forEach { self.dashboard.addSubview($0) }
        self.dashboard.contentSize = CGSize(width: self.view.bounds.width, height: 900)
        self.phase("dashboard") {
            self.dashboard.setContentOffset(CGPoint(x: 0, y: 180), animated: true)
            self.phase("scroll", after: 2) {
                self.dashboard.setContentOffset(.zero, animated: true)
                self.phase("return", after: 2) {
                    self.search.setShowsCancelButton(true, animated: true)
                    self.search.textField.becomeFirstResponder()
                    self.phase("search", after: 3) { self.showIconCarousel() }
                }
            }
        }
    }
    private func showMediaActions() {
        self.search.textField.resignFirstResponder()
        let sheet = codeGramMediaActions(saveTitle: "Сохранить", startTitle: "Начать отсчёт", cancelTitle: "Отмена",
            canStart: true, sourceView: self.view, save: {}, start: {})
        self.expect(sheet.actions.map { $0.title ?? "" } == ["Сохранить", "Начать отсчёт", "Отмена"], "Unopened media is missing explicit actions")
        self.present(sheet, animated: true) {
            self.expectPlainAlert(sheet, context: "unopened media actions")
            self.phase("media-actions", after: 1) {
                var firstCalls = 0
                codeGramDismissMediaActions(sheet) {
                    firstCalls += 1
                    self.expect(firstCalls == 1 && sheet.presentingViewController == nil, "Presented action must run once after dismissal")
                    let started = codeGramMediaActions(saveTitle: "Сохранить", startTitle: "Начать отсчёт", cancelTitle: "Отмена",
                        canStart: false, sourceView: self.view, save: {}, start: {})
                    self.expect(started.actions.count == 2, "Existing countdown must not offer a second start")
                    self.present(started, animated: true) {
                        self.expectPlainAlert(started, context: "started media actions")
                        self.phase("media-actions-started", after: 1) {
                            var closedCalls = 0
                            let closed = CodeGramPlainAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                            codeGramDismissMediaActions(closed) { closedCalls += 1 }
                            self.expect(closedCalls == 1, "Already closed action must not be lost")
                            var closingCalls = 0
                            started.dismiss(animated: true)
                            codeGramDismissMediaActions(started) {
                                closingCalls += 1
                                self.expect(closingCalls == 1 && started.presentingViewController == nil, "Closing action must wait for the actual transition")
                                self.showDashboard()
                            }
                        }
                    }
                }
            }
        }
    }
    private func showIconCarousel() {
        self.search.textField.resignFirstResponder()
        self.search.isHidden = true; self.table.view.isHidden = true; self.dashboard.isHidden = true
        // Run the state sweep offscreen. Recording a fresh production instance
        // avoids carrying stress-test button transitions into the visual path.
        let picker = CodeGramIconPickerView(currentName: "CGRift")
        picker.frame = CGRect(x: 0,y: 0,width: self.view.bounds.width,height: 1000)
        picker.layoutIfNeeded()
        self.expectPlainScroll(picker.scrollView, context: "icon carousel")
        self.expect(picker.selectedIndex == 4,"Picker must open on the actually installed alternate icon")
        var applied = 0
        picker.onApply = { _ in applied += 1 }
        for choice in CodeGramAppIconChoice.all { self.expect(UIImage(named: choice.previewName) != nil,"Missing bundled preview for \(choice.title)") }
        for index in CodeGramAppIconChoice.all.indices {
            picker.select(index: index,animated: false); picker.layoutIfNeeded()
            self.expect(picker.selectedIndex == index,"Carousel selection differs from centered icon")
            self.expect(picker.pageControl.currentPage == index,"Page dots differ from preview")
            self.expect(picker.applyButton.frame.minY > picker.detailLabel.frame.maxY,"Apply button overlaps the icon description")
        }
        self.expect(applied == 0,"Scrolling must never apply an icon without an explicit press")
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r,green: &g,blue: &b,alpha: &a)
            let channels = [r,g,b].map { value -> Double in
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value+0.055)/1.055,2.4)
            }
            return channels[0]*0.2126 + channels[1]*0.7152 + channels[2]*0.0722
        }
        for index in 0 ..< (CodeGramAppIconChoice.all.count-1) {
            for fraction in [0.0,0.25,0.5,0.75,1.0] {
                picker.scrollView.setContentOffset(CGPoint(x: (CGFloat(index)+CGFloat(fraction))*156-picker.scrollView.contentInset.left,y: 0),animated: false)
                let text = luminance(picker.titleLabel.textColor), backdrop = luminance(picker.backgroundColor ?? .black)
                self.expect((max(text,backdrop)+0.05)/(min(text,backdrop)+0.05) >= 4.5,"Primary carousel text disappears during a background transition")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { self.recordIconCarousel() }
    }
    private func recordIconCarousel() {
        let picker = CodeGramIconPickerView(currentName: "CGRift")
        self.recordingIconPicker = picker
        self.view.addSubview(picker)
        picker.frame = CGRect(x: 0,y: self.view.safeAreaInsets.top,width: self.view.bounds.width,height: 1000)
        picker.layoutIfNeeded()
        var applied = 0
        picker.onApply = { _ in applied += 1 }
        picker.select(index: 0,animated: false)
        self.phase("icons-original",after: 2) {
            picker.select(index: 1,animated: true)
            self.phase("icons-clip",after: 2) {
                picker.select(index: 2,animated: true)
                self.phase("icons-paper",after: 2) {
                    picker.select(index: 6,animated: true)
                    self.phase("icons-pixel",after: 2) {
                        picker.select(index: 7,animated: true)
                        self.phase("icons-chrome",after: 2) {
                            picker.select(index: 8,animated: true)
                            self.phase("icons-stairs",after: 2) {
                                picker.applyButton.sendActions(for: .touchUpInside)
                                self.expect(applied == 1,"Apply must run exactly once")
                                picker.setApplying(false,appliedName: "CGStairs",succeeded: true)
                                self.expect(!picker.applyButton.isEnabled,"Applied icon must be marked as installed")
                                self.expect(picker.applyButton.configuration?.title == "Установлена","Applied icon must have the installed title")
                                DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                                    self.phase("icons-applied",after: 2) { self.finish() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func finish() {
        self.search.textField.resignFirstResponder()
        if self.recordingStyle == .dark {
            self.startRecording(style: .light)
            return
        }
        let report: [String: Any] = ["checks": self.checks, "failures": self.failures, "ios": UIDevice.current.systemVersion, "recorded_styles": ["dark", "light"], "production_sources": ["ClassicDesign.swift", "CodeGramSettingsTheme.swift", "CodeGramSettingsCells.swift", "CodeGramDashboardComponents.swift", "CodeGramIconPickerView.swift", "CodeGramMediaActions.swift"], "scope": "Native opaque production surfaces, light/dark recordings and table self-sizing; not an authenticated full app session or a physical-device thermal test"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: self.output.appendingPathComponent("result.json"), options: .atomic) }
    }
}

private final class HarnessSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        NSSetUncaughtExceptionHandler(preserveHarnessException)
        ClassicDesign.installOpaqueSystemAppearance()
        let window = UIWindow(windowScene: scene)
        let controller = HarnessController()
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        window.rootViewController = navigation
        window.makeKeyAndVisible(); self.window = window
    }
}
@main private final class HarnessAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "UIRegression", sessionRole: connectingSceneSession.role)
        config.delegateClass = HarnessSceneDelegate.self; return config
    }
}

