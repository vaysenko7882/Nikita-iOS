import UIKit

private let appearanceInfo = "Возвращает оформление Telegram до Liquid Glass. Применяется после перезапуска приложения."
private let badgeInfo = "Показывает капсулу CODEGRAM у выреза экрана. Выключите, чтобы её скрыть."
private let phoneInfo = "Скрывает ваш номер только на экране настроек этого приложения. Настройки видимости номера для других пользователей не меняются."

private func toggle(_ value: Bool = true) -> CodeGramValueSwitch {
    let control = CodeGramValueSwitch(); control.isOn = value; return control
}
private func fixtureCells() -> [UITableViewCell] {
    let field = UITextField(); field.placeholder = "Ключ доступа с твоего VPS"
    return [
        CodeGramTextCell(title: "Классический дизайн", detail: appearanceInfo, symbol: "rectangle.on.rectangle", control: toggle(false)),
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
    private let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black; self.overrideUserInterfaceStyle = .dark
        self.addChild(self.table); self.view.addSubview(self.table.view); self.table.didMove(toParent: self)
        self.view.addSubview(self.dashboard); self.view.addSubview(self.search)
        self.dashboard.isHidden = true; self.search.isHidden = true
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runChecks(); self.showAppearance() }
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
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { self.descendants($0) } }
    private func runChecks() {
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
                            guard let cell = cell as? CodeGramGlassCell else { self.expect(false, "missing production cell"); continue }
                            self.expect(fixture.table.rectForRow(at: IndexPath(row: index, section: 0)).height >= 60, "collapsed row \(index) \(context)")
                            let labels = self.descendants(cell.bodyView).compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier?.hasPrefix("CodeGram.") == true }
                            for label in labels {
                                let rect = label.convert(label.bounds, to: cell.bodyView)
                                self.expect(cell.bodyView.bounds.insetBy(dx: -1, dy: -1).contains(rect), "label outside glass: \(label.text ?? "") \(context) \(rect)/\(cell.bodyView.bounds)")
                                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                                self.expect(label.bounds.height + 1 >= needed, "clipped text: \(label.text ?? "") \(context) bounds=\(label.bounds), needed=\(needed), maxWidth=\(label.preferredMaxLayoutWidth)")
                                self.expect(label.isDescendant(of: cell.glass.contentView), "text detached from native material")
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
                            if #available(iOS 26.0, *) {
                                self.expect((cell.glass.effect as? UIGlassEffect)?.isInteractive == true, "native interactive glass missing")
                            }
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
        if #available(iOS 26.0, *) {
            self.expect((self.search.effect as? UIGlassEffect)?.isInteractive == true, "search is not native interactive glass")
        }
        self.expect(self.search.searchBar.isDescendant(of: self.search.contentView), "search detached from glass")
    }
    private func phase(_ name: String, after seconds: TimeInterval = 3, next: @escaping () -> Void) {
        try? name.write(to: self.output.appendingPathComponent("phase.txt"), atomically: true, encoding: .utf8)
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let captured = FileManager.default.fileExists(atPath: self.output.appendingPathComponent("captured-" + name).path)
            if (captured && Date().timeIntervalSince(started) >= seconds) || Date().timeIntervalSince(started) > 25 {
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
        self.phase("voice") { self.showDashboard() }
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
                    self.search.searchBar.setShowsCancelButton(true, animated: true)
                    self.search.searchBar.searchTextField.becomeFirstResponder()
                    self.phase("search", after: 3) { self.finish() }
                }
            }
        }
    }
    private func finish() {
        self.search.searchBar.resignFirstResponder()
        let report: [String: Any] = ["checks": self.checks, "failures": self.failures, "ios": UIDevice.current.systemVersion, "production_sources": ["CodeGramSettingsTheme.swift", "CodeGramSettingsCells.swift", "CodeGramDashboardComponents.swift"], "scope": "Native production controls and table self-sizing, not an authenticated full app session or a physical-device thermal test"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: self.output.appendingPathComponent("result.json"), options: .atomic) }
    }
}

private final class HarnessSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
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
