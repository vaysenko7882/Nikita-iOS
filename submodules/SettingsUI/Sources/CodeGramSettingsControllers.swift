import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

final class CodeGramSettingsRow {
    private let makeCell: () -> UITableViewCell
    private var renderedCell: UITableViewCell?
    let action: (() -> Void)?
    init(cell: @escaping () -> UITableViewCell, action: (() -> Void)? = nil) {
        self.makeCell = cell; self.action = action
    }
    func cell() -> UITableViewCell {
        if let renderedCell { return renderedCell }
        let cell = self.makeCell(); self.renderedCell = cell; return cell
    }
}
struct CodeGramSettingsSection {
    var title: String?
    var footer: String?
    var rows: [CodeGramSettingsRow]
}
class CodeGramTableController: ViewController, UITableViewDataSource, UITableViewDelegate {
    let context: AccountContext
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    var sections: [CodeGramSettingsSection] = []
    var accountKey: String { String(self.context.account.peerId.id._internalGetInt64Value()) }
    init(context: AccountContext, title: String) {
        self.context = context
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = title
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "Назад", style: .plain, target: nil, action: nil)
        self.statusBar.statusBarStyle = context.sharedContext.currentPresentationData.with { $0 }.theme.rootController.statusBarStyle.style
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        let dark = self.context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance
        self.displayNode.view.overrideUserInterfaceStyle = dark ? .dark : .light
        self.displayNode.backgroundColor = dark ? .black : .systemGroupedBackground
        CodeGramSettingsTheme.configure(self.tableView)
        self.tableView.overrideUserInterfaceStyle = self.context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance ? .dark : .light
        self.tableView.contentInsetAdjustmentBehavior = .never
        self.tableView.keyboardDismissMode = .interactive
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 88
        self.tableView.dataSource = self; self.tableView.delegate = self
        self.displayNode.view.addSubview(self.tableView)
        self.reloadContent()
        self.displayNodeDidLoad()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.tableView.frame = CGRect(origin: .zero, size: layout.size)
        self.tableView.contentInset = UIEdgeInsets(top: self.cleanNavigationHeight, left: layout.safeInsets.left, bottom: layout.insets(options: .input).bottom + 16, right: layout.safeInsets.right)
        self.tableView.scrollIndicatorInsets = self.tableView.contentInset
    }
    func reloadContent() { self.sections = self.makeSections(); self.tableView.reloadData() }
    func makeSections() -> [CodeGramSettingsSection] { [] }
    func notice(_ message: String, title: String = "CodeGram") {
        let alert = CodeGramPlainAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(CodeGramPlainAlertAction(title: "ОК", style: .default))
        self.present(alert, animated: true)
    }
    func numberOfSections(in tableView: UITableView) -> Int { self.sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { self.sections[section].title }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { self.sections[section].footer }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        self.sections[indexPath.section].rows[indexPath.row].cell()
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); self.sections[indexPath.section].rows[indexPath.row].action?() }
    func textRow(_ title: String, detail: String? = nil, icon: String, action: (() -> Void)? = nil) -> CodeGramSettingsRow {
        CodeGramSettingsRow(cell: { CodeGramTextCell(title: title, detail: detail, symbol: icon, disclosure: action != nil) }, action: action)
    }
    func switchRow(_ title: String, value: Bool, detail: String? = nil, icon: String, enabled: Bool = true, changed: @escaping (Bool) -> Void) -> CodeGramSettingsRow {
        CodeGramSettingsRow(cell: {
            let toggle = CodeGramValueSwitch()
            toggle.isOn = value; toggle.isEnabled = enabled; toggle.changed = changed
            return CodeGramTextCell(title: title, detail: detail, symbol: icon, control: toggle)
        })
    }
    func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>, icon: String, format: @escaping (Double) -> String = { String(format: "%.0f%%", $0 * 100) }, changed: @escaping (Double) -> Void) -> CodeGramSettingsRow {
        CodeGramSettingsRow(cell: { CodeGramSliderCell(title: title, symbol: icon, value: value, range: range, format: format, changed: changed) })
    }
}


final class CodeGramVoiceController: CodeGramTableController {
    private var configuration = NikitaSettingsStore.shared.voiceConfiguration
    init(context: AccountContext) { super.init(context: context, title: "VoiceChanger") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func change(_ body: (inout NikitaVoiceConfiguration) -> Void) {
        body(&self.configuration); self.configuration = self.configuration.normalized
        NikitaSettingsStore.shared.voiceConfiguration = self.configuration
    }
    private func apply(_ value: NikitaVoiceConfiguration) {
        self.configuration = value.normalized; NikitaSettingsStore.shared.voiceConfiguration = self.configuration; self.reloadContent()
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        let c = self.configuration
        func symbol(_ effect: NikitaVoiceEffect) -> String {
            switch effect {
            case .off: return "mic"
            case .squeaky: return "arrow.up.circle"
            case .cartoon: return "theatermasks"
            case .deep: return "arrow.down.circle"
            case .robot: return "cpu"
            }
        }
        let presets: [(String, String, NikitaVoiceConfiguration)] = [("Естественный низкий", "waveform", .naturalDeep), ("Радио", "radio", .radio), ("Чистый высокий", "sparkles", .clearHigh), ("Пространство", "airplayaudio", .spacious)] + NikitaVoiceEffect.allCases.map { ($0.title, symbol($0), .preset($0)) }
        var presetRows = presets.map { name, icon, value in self.textRow(name, detail: c == value ? "Выбран" : nil, icon: icon, action: { [weak self] in self?.apply(value) }) }
        presetRows += NikitaSettingsStore.shared.voicePresets.map { preset in self.textRow(preset.title, detail: "Свой пресет · нажми, чтобы применить", icon: "bookmark", action: { [weak self] in self?.apply(preset.configuration) }) }
        presetRows.append(self.textRow("Сохранить свой пресет", icon: "plus.circle", action: { [weak self] in self?.savePreset() }))
        presetRows.append(self.textRow("Удалить свои пресеты", icon: "bookmark.slash", action: { [weak self] in
            guard let self else { return }
            let alert = CodeGramPlainAlertController(title: "Удалить свои пресеты?", message: "Текущие настройки голоса сохранятся.", preferredStyle: .alert)
            alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(CodeGramPlainAlertAction(title: "Удалить", style: .destructive, handler: { [weak self] _ in NikitaSettingsStore.shared.voicePresets = []; self?.reloadContent() }))
            self.present(alert, animated: true)
        }))
        return [
            CodeGramSettingsSection(title: "Голосовые сообщения", footer: "Настройки фиксируются при начале записи. Запиши голосовое и прослушай предпросмотр перед отправкой. Эффект работает на iPhone и не изменяет звонки.", rows: [self.switchRow("Изменять голос", value: c.enabled, icon: "mic.badge.plus", changed: { [weak self] value in self?.change { $0.enabled = value } })]),
            CodeGramSettingsSection(title: "Тембр", footer: "Высота меняется без изменения длительности. Отрицательный тон делает голос теплее, положительный — ярче.", rows: [
                self.sliderRow("Высота", value: c.pitchSemitones, range: -12 ... 12, icon: "arrow.up.and.down", format: { String(format: "%+.1f полутонов", $0) }, changed: { [weak self] value in self?.change { $0.pitchSemitones = value } }),
                self.sliderRow("Тон", value: c.tone, range: -1 ... 1, icon: "tuningfork", changed: { [weak self] value in self?.change { $0.tone = value } })]),
            CodeGramSettingsSection(title: "Робот", footer: "Кольцевая модуляция: доля эффекта и частота модулятора.", rows: [
                self.sliderRow("Сила робота", value: c.robotAmount, range: 0 ... 1, icon: "cpu", changed: { [weak self] value in self?.change { $0.robotAmount = value } }),
                self.sliderRow("Частота", value: c.robotFrequency, range: 20 ... 160, icon: "waveform.path", format: { String(format: "%.0f Гц", $0) }, changed: { [weak self] value in self?.change { $0.robotFrequency = value } })]),
            CodeGramSettingsSection(title: "Пространство", footer: nil, rows: [
                self.sliderRow("Эхо", value: c.echoAmount, range: 0 ... 0.6, icon: "dot.radiowaves.left.and.right", changed: { [weak self] value in self?.change { $0.echoAmount = value } }),
                self.sliderRow("Задержка", value: c.echoDelayMilliseconds, range: 20 ... 400, icon: "clock.arrow.circlepath", format: { String(format: "%.0f мс", $0) }, changed: { [weak self] value in self?.change { $0.echoDelayMilliseconds = value } })]),
            CodeGramSettingsSection(title: "Качество и баланс", footer: "Порог тишины приглушает тихий фон, но не заменяет нейросетевое шумоподавление. Компрессия выравнивает громкость. При искажениях уменьши усиление.", rows: [
                self.sliderRow("Усиление", value: c.gainDecibels, range: -12 ... 12, icon: "speaker.wave.3", format: { String(format: "%+.1f дБ", $0) }, changed: { [weak self] value in self?.change { $0.gainDecibels = value } }),
                self.sliderRow("Доля обработанного голоса", value: c.mix, range: 0 ... 1, icon: "circle.lefthalf.filled", changed: { [weak self] value in self?.change { $0.mix = value } }),
                self.sliderRow("Компрессия", value: c.compression, range: 0 ... 1, icon: "arrow.down.right.and.arrow.up.left", changed: { [weak self] value in self?.change { $0.compression = value } }),
                self.sliderRow("Порог тишины", value: c.gate, range: 0 ... 0.08, icon: "speaker.slash", format: { String(format: "%.1f%%", $0 * 100) }, changed: { [weak self] value in self?.change { $0.gate = value } })]),
            CodeGramSettingsSection(title: "Пресеты", footer: "До 24 своих вариантов. Применение пресета заменяет положения регуляторов.", rows: presetRows)
        ]
    }
    private func savePreset() {
        let alert = CodeGramPlainAlertController(title: "Свой голос", message: "Назови текущие настройки", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Название пресета" }
        alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(CodeGramPlainAlertAction(title: "Сохранить", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            var presets = NikitaSettingsStore.shared.voicePresets
            guard presets.count < 24 else { self.notice("Уже сохранено 24 пресета. Сначала удали ненужные."); return }
            presets.append(CodeGramVoicePreset(title: name, configuration: self.configuration)); NikitaSettingsStore.shared.voicePresets = presets; self.reloadContent()
        }))
        self.present(alert, animated: true)
    }
}

private final class CodeGramDeletedPreviewCell: CodeGramSurfaceCell {
    private let bubble = UIView()
    init() {
        super.init(style: .default, reuseIdentifier: nil)
        self.selectionStyle = .none
        self.bubble.backgroundColor = .systemBlue; self.bubble.layer.cornerRadius = 17
        let text = UILabel(); text.text = "Удалённое сообщение\nФото, текст или голосовое"; text.font = .systemFont(ofSize: 16); text.textColor = .white; text.numberOfLines = 2
        self.bodyView.addSubview(self.bubble); self.bubble.addSubview(text)
        self.bubble.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.bubble.leadingAnchor.constraint(equalTo: self.bodyView.leadingAnchor, constant: 20), self.bubble.trailingAnchor.constraint(equalTo: self.bodyView.trailingAnchor, constant: -20),
            self.bubble.topAnchor.constraint(equalTo: self.bodyView.topAnchor, constant: 20), self.bubble.bottomAnchor.constraint(equalTo: self.bodyView.bottomAnchor, constant: -20),
            text.leadingAnchor.constraint(equalTo: self.bubble.leadingAnchor, constant: 16), text.trailingAnchor.constraint(equalTo: self.bubble.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: self.bubble.topAnchor, constant: 14), text.bottomAnchor.constraint(equalTo: self.bubble.bottomAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        codegramApplyDeletedAppearance(root: self.bubble.layer, rect: self.bubble.bounds, isDeleted: true)
    }
}

final class CodeGramDeletedStyleController: CodeGramTableController {
    init(context: AccountContext) { super.init(context: context, title: "Удалённые сообщения") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func change(_ body: (inout CodeGramDeletedStyle) -> Void) { var style = CodeGramDeletedStyle.current; body(&style); CodeGramDeletedStyle.current = style }
    override func makeSections() -> [CodeGramSettingsSection] {
        let style = CodeGramDeletedStyle.current
        return [
            CodeGramSettingsSection(title: "Предпросмотр", footer: "Вид обновляется сразу, в том числе у уже открытых сообщений. Непрозрачность относится ко всему сообщению; затемнение добавляет чёрный полупрозрачный слой.", rows: [CodeGramSettingsRow(cell: { CodeGramDeletedPreviewCell() })]),
            CodeGramSettingsSection(title: "Внешний вид", footer: nil, rows: [
                self.sliderRow("Непрозрачность", value: style.opacity, range: 0.1 ... 1, icon: "circle.dotted", changed: { [weak self] value in self?.change { $0.opacity = value } }),
                self.sliderRow("Чёрное затемнение", value: style.darkOverlay, range: 0 ... 0.85, icon: "moon.fill", changed: { [weak self] value in self?.change { $0.darkOverlay = value } }),
                self.switchRow("Пунктирная рамка", value: style.dashed, icon: "rectangle.dashed", changed: { [weak self] value in self?.change { $0.dashed = value } }),
                self.sliderRow("Толщина рамки", value: style.outlineWidth, range: 0.5 ... 3, icon: "lineweight", format: { String(format: "%.1f pt", $0) }, changed: { [weak self] value in self?.change { $0.outlineWidth = value } }),
                self.sliderRow("Скругление", value: style.cornerRadius, range: 4 ... 30, icon: "squareshape", format: { String(format: "%.0f pt", $0) }, changed: { [weak self] value in self?.change { $0.cornerRadius = value } })]),
            CodeGramSettingsSection(title: "Цвет рамки", footer: nil, rows: ["Серый", "Синий", "Оранжевый", "Красный"].enumerated().map { index, title in self.textRow(title, detail: style.outlineColor == index ? "Выбран" : nil, icon: "paintpalette", action: { [weak self] in self?.change { $0.outlineColor = index }; self?.reloadContent() }) }),
            CodeGramSettingsSection(title: nil, footer: nil, rows: [self.textRow("Вернуть оформление по умолчанию", icon: "arrow.uturn.backward", action: { [weak self] in CodeGramDeletedStyle.current = CodeGramDeletedStyle(); self?.reloadContent() })])
        ]
    }
}

final class CodeGramContentController: CodeGramTableController {
    init(context: AccountContext) { super.init(context: context, title: "Сохранение и доступ") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func makeSections() -> [CodeGramSettingsSection] {
        let settings = NikitaSettingsStore.shared
        return [
            CodeGramSettingsSection(title: "Копирование и медиа", footer: "Копирование текста и сохранение полученных вложений из защищённых чатов. Пересылка через сервер Telegram может остаться недоступна. Для доступной истории появится «Сохранить в галерею» в меню истории.", rows: [
                self.switchRow("Разрешать копирование и сохранение", value: settings.allowsProtectedExport, icon: "doc.on.doc", changed: { settings.allowsProtectedExport = $0 })]),
            CodeGramSettingsSection(title: "Одноразовые медиа", footer: "Сохранять входящие одноразовые медиа, пока они доступны этому устройству. Уже просмотренные или исчезнувшие вложения восстановить нельзя. Секретные чаты недоступны серверу VPS.", rows: [
                self.switchRow("Сохранять полученные одноразовые медиа", value: settings.keepsEphemeralMedia, icon: "timer", changed: { settings.keepsEphemeralMedia = $0 })]),
            CodeGramSettingsSection(title: "Ограничения клиента", footer: "Скрывает локальные заглушки iOS и региональных ограничений для данных, которые Telegram выдаёт аккаунту. Не снимает блокировку на стороне сервера, требования вступления и проверки доступа. Переоткрой чат после изменения.", rows: [
                self.switchRow("Показывать доступный ограниченный контент", value: settings.allowsRestrictedContent, icon: "lock.open", changed: { settings.allowsRestrictedContent = $0 })])
        ]
    }
}



