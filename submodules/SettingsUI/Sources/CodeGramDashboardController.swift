import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

final class CodeGramDashboardController: ViewController, UISearchBarDelegate {
    private let context: AccountContext
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let logo = UIImageView(image: codegramBrandMark())
    private let searchSurface = CodeGramSearchView()
    private var searchBar: UISearchBar { self.searchSurface.searchBar }
    private let ghost = CodeGramQuickCard(title: "Призрак", symbol: "codegram.ghost")
    private let archive = CodeGramQuickCard(title: "Архив", symbol: "archivebox")
    private let privacy = CodeGramDashboardTile(destination: .privacy)
    private let messages = CodeGramDashboardTile(destination: .messages)
    private let appearance = CodeGramDashboardTile(destination: .appearance)
    private let voice = CodeGramDashboardTile(destination: .voice)
    private let bottomSurface = UIView()
    private let storage = CodeGramDashboardRow(destination: .storage)
    private let additional = CodeGramDashboardRow(destination: .additional)
    private let separator = UIView()
    private let footer = UILabel()
    private let emptyLabel = UILabel()
    private var searchRows: [CodeGramDashboardRow] = []
    private var query = ""
    private var layoutSize = CGSize.zero
    private var safeInsets = UIEdgeInsets.zero
    private var dark = true
    private var classicDesign = false
    private var ghostEnabled = false
    private var archiveEnabled = false
    private var ghostBusy = false
    private var archiveBusy = false
    private let subscriptions = DisposableSet()
    private let ghostWrite = MetaDisposable()
    private let archiveWrite = MetaDisposable()
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContext) {
        self.context = context
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = "CodeGram"
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "Назад", style: .plain, target: nil, action: nil)
        self.statusBar.statusBarStyle = context.sharedContext.currentPresentationData.with { $0 }.theme.rootController.statusBarStyle.style
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        self.subscriptions.dispose(); self.ghostWrite.dispose(); self.archiveWrite.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.scrollView.contentInsetAdjustmentBehavior = .never; self.scrollView.keyboardDismissMode = .interactive; self.scrollView.alwaysBounceVertical = true
        self.displayNode.view.addSubview(self.scrollView); self.scrollView.addSubview(self.contentView)
        self.titleLabel.text = "CodeGram"; self.titleLabel.textColor = .label; self.titleLabel.accessibilityTraits = .header
        self.titleLabel.adjustsFontSizeToFitWidth = true; self.titleLabel.minimumScaleFactor = 0.7
        self.subtitleLabel.text = "Твой стиль. Твои настройки."; self.subtitleLabel.textColor = .secondaryLabel; self.subtitleLabel.numberOfLines = 2
        self.logo.contentMode = .scaleAspectFit; self.logo.isAccessibilityElement = false
        self.searchBar.delegate = self
        self.searchBar.searchTextField.accessibilityLabel = "Поиск по настройкам CodeGram"
        self.footer.text = "На этом iPhone"; self.footer.textColor = .tertiaryLabel; self.footer.textAlignment = .center
        self.emptyLabel.text = "Ничего не найдено\nПопробуй «голос», «архив» или «плашка»."; self.emptyLabel.numberOfLines = 0; self.emptyLabel.textAlignment = .center; self.emptyLabel.textColor = .secondaryLabel
        for view in [self.titleLabel, self.subtitleLabel, self.logo, self.searchSurface, self.ghost, self.archive, self.privacy, self.messages, self.appearance, self.voice, self.bottomSurface, self.footer, self.emptyLabel] { self.contentView.addSubview(view) }
        self.bottomSurface.addSubview(self.storage); self.bottomSurface.addSubview(self.additional); self.bottomSurface.addSubview(self.separator)
        self.bottomSurface.isAccessibilityElement = false
        self.ghost.action = { [weak self] in self?.open(.ghost) }; self.archive.action = { [weak self] in self?.open(.archive) }
        self.ghost.changed = { [weak self] value in self?.setGhost(value) }; self.archive.changed = { [weak self] value in self?.setArchive(value) }
        self.privacy.action = { [weak self] in self?.open(.privacy) }; self.messages.action = { [weak self] in self?.open(.messages) }
        self.appearance.action = { [weak self] in self?.open(.appearance) }; self.voice.action = { [weak self] in self?.open(.voice) }
        self.storage.action = { [weak self] in self?.open(.storage) }; self.additional.action = { [weak self] in self?.open(.additional) }
        self.refreshFonts()
        self.displayNodeDidLoad()
        self.subscribeToSettings()
        self.observers.append(NotificationCenter.default.addObserver(forName: NikitaSettingsStore.changed, object: nil, queue: .main) { [weak self] _ in guard let self, self.isViewLoaded, self.displayNode.view.window != nil else { return }; self.refreshVoice() })
        self.observers.append(NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshFonts(); self?.layoutContent() })
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if self.isViewLoaded { self.refreshVoice(); self.layoutContent() } }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let initialLayout = self.layoutSize == .zero
        self.layoutSize = layout.size; self.safeInsets = layout.safeInsets
        self.scrollView.frame = CGRect(origin: .zero, size: layout.size)
        self.scrollView.contentInset = UIEdgeInsets(top: self.cleanNavigationHeight, left: 0, bottom: layout.insets(options: .input).bottom + 16, right: 0)
        self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset
        self.layoutContent()
        if initialLayout { self.scrollView.contentOffset = CGPoint(x: 0, y: -self.scrollView.contentInset.top) }
    }

    private func subscribeToSettings() {
        self.subscriptions.add((self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in self?.applyPalette(dark: data.theme.overallDarkAppearance) }))
        self.subscriptions.add((self.context.engine.messages.ghostModeSettings() |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else { return }; self.ghostEnabled = settings.isEnabled; self.ghost.update(isOn: self.ghostEnabled, busy: self.ghostBusy)
        }))
        self.subscriptions.add((self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.deletedMessageArchiveSettings)) |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self else { return }
            let settings = entry?.get(DeletedMessageArchiveSettings.self) ?? .defaultSettings
            self.archiveEnabled = settings.isEnabled
            self.archive.update(isOn: self.archiveEnabled, busy: self.archiveBusy)
        }))
        self.subscriptions.add((interfaceTuningSettingsSignal() |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else { return }; self.classicDesign = settings.classicDesign; self.refreshAppearanceDetail(); self.layoutContent()
        }))
        self.refreshVoice()
    }

    private func setGhost(_ value: Bool) {
        self.ghostBusy = true; self.ghost.update(isOn: value, busy: true)
        self.ghostWrite.set((self.context.engine.messages.updateGhostModeSettingsInteractively { current in var current = current; current.isEnabled = value; return current } |> deliverOnMainQueue).start(completed: { [weak self] in
            guard let self else { return }; self.ghostBusy = false; self.ghostEnabled = value; self.ghost.update(isOn: value)
        }))
    }
    private func setArchive(_ value: Bool) {
        self.archiveBusy = true; self.archive.update(isOn: value, busy: true)
        self.archiveWrite.set((self.context.engine.messages.updateDeletedMessageArchiveSettingsInteractively { current in
            var current = current; current.isEnabled = value
            if value { current.keepAcrossLaunches = true }
            return current
        } |> deliverOnMainQueue).start(completed: { [weak self] in
            guard let self else { return }; self.archiveBusy = false; self.archiveEnabled = value; self.archive.update(isOn: value)
        }))
    }
    private func refreshVoice() {
        let configuration = NikitaSettingsStore.shared.voiceConfiguration
        let title: String
        if !configuration.enabled || configuration.mix == 0 { title = "Оригинальный" }
        else if let preset = NikitaSettingsStore.shared.voicePresets.first(where: { $0.configuration == configuration }) { title = preset.title }
        else if let preset = NikitaVoiceEffect.allCases.first(where: { NikitaVoiceConfiguration.preset($0) == configuration }) { title = preset.title }
        else { title = "Свои настройки" }
        self.voice.setDetail(title); self.layoutContent()
    }
    private func refreshFonts() {
        self.titleLabel.font = codegramDashboardFont(36, weight: .bold, style: .largeTitle)
        self.subtitleLabel.font = codegramDashboardFont(15, style: .subheadline)
        self.searchBar.searchTextField.font = UIFont.preferredFont(forTextStyle: .body)
        self.footer.font = codegramDashboardFont(12, style: .caption1); self.emptyLabel.font = codegramDashboardFont(16)
        for tile in [self.privacy, self.messages, self.appearance, self.voice] { tile.refreshFonts() }
        self.ghost.refreshFonts(); self.archive.refreshFonts(); self.storage.refreshFonts(); self.additional.refreshFonts()
        for row in self.searchRows { row.refreshFonts() }
    }
    private func applyPalette(dark: Bool) {
        self.dark = dark; self.displayNode.view.overrideUserInterfaceStyle = dark ? .dark : .light
        self.displayNode.backgroundColor = dark ? .black : .systemGroupedBackground
        self.logo.tintColor = .label
        self.logo.image = codegramBrandMark()?.withRenderingMode(.alwaysTemplate)
        self.separator.backgroundColor = .clear
        for surface in [self.ghost, self.archive, self.privacy, self.messages, self.appearance, self.voice] as [CodeGramDashboardSurface] { surface.applyPalette(dark: dark) }
        self.refreshAppearanceDetail()
        self.layoutContent()
    }

    private func refreshAppearanceDetail() { self.appearance.setDetail(self.classicDesign ? "Классический стиль" : (self.dark ? "Тёмная · Glass" : "Светлая · Glass")) }

    private func layoutContent() {
        guard self.layoutSize.width > 0 else { return }
        let width = max(1, min(720, self.layoutSize.width - self.safeInsets.left - self.safeInsets.right - 32))
        let largeText = UIFont.preferredFont(forTextStyle: .body).pointSize > 20
        let singleColumn = width < 325 || largeText
        var y: CGFloat = 10
        let logoSize: CGFloat = largeText ? 50 : 62
        let titleY = largeText ? y + 58 : y
        let titleWidth = largeText ? width : max(1, width - 84)
        let titleHeight = self.titleLabel.font.lineHeight
        self.titleLabel.frame = CGRect(x: 8, y: titleY, width: titleWidth - 8, height: titleHeight)
        self.logo.frame = CGRect(x: width - logoSize - 10, y: y + (largeText ? 0 : 1), width: logoSize, height: logoSize + 4)
        let subtitleSize = self.subtitleLabel.sizeThatFits(CGSize(width: width - 16, height: 160))
        self.subtitleLabel.frame = CGRect(x: 8, y: self.titleLabel.frame.maxY + 4, width: width - 16, height: subtitleSize.height)
        y = max(self.logo.frame.maxY, self.subtitleLabel.frame.maxY) + 14
        let searchHeight = max(50, UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)
        self.searchSurface.frame = CGRect(x: 0, y: y, width: width, height: searchHeight)
        y += searchHeight + 10
        let searching = !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let home: [UIView] = [self.ghost, self.archive, self.privacy, self.messages, self.appearance, self.voice, self.bottomSurface, self.footer]
        for view in home { view.isHidden = searching }
        for row in self.searchRows { row.isHidden = !searching }
        self.emptyLabel.isHidden = !searching || !self.searchRows.isEmpty
        if searching {
            for row in self.searchRows {
                let height = row.preferredHeight(width: width)
                row.frame = CGRect(x: 0, y: y, width: width, height: height); y += height + 8
            }
            if self.searchRows.isEmpty { self.emptyLabel.frame = CGRect(x: 16, y: y + 20, width: width - 32, height: 110); y += 150 }
        } else {
            let gap: CGFloat = 10
            let smallWidth = singleColumn ? width : (width - gap) / 2
            let singleQuickColumn = singleColumn || width < 380
            let quickWidth = singleQuickColumn ? width : smallWidth
            let quickHeight = max(60, UIFont.preferredFont(forTextStyle: .body).lineHeight * 2 + 20)
            self.ghost.frame = CGRect(x: 0, y: y, width: quickWidth, height: quickHeight)
            self.archive.frame = CGRect(x: singleQuickColumn ? 0 : quickWidth + gap, y: singleQuickColumn ? y + quickHeight + gap : y, width: quickWidth, height: quickHeight)
            y += singleQuickColumn ? quickHeight * 2 + gap + 10 : quickHeight + 10
            let tiles = [self.privacy, self.messages, self.appearance, self.voice]
            for row in 0 ..< (singleColumn ? 4 : 2) {
                let first = row * (singleColumn ? 1 : 2)
                let count = singleColumn ? 1 : 2
                let height = (first ..< first + count).map { tiles[$0].preferredHeight(width: smallWidth) }.max() ?? 180
                for column in 0 ..< count { tiles[first + column].frame = CGRect(x: CGFloat(column) * (smallWidth + gap), y: y, width: smallWidth, height: height) }
                y += height + 10
            }
            let storageHeight = self.storage.preferredHeight(width: width)
            let additionalHeight = self.additional.preferredHeight(width: width)
            self.bottomSurface.frame = CGRect(x: 0, y: y, width: width, height: storageHeight + additionalHeight + 8)
            self.storage.frame = CGRect(x: 0, y: 0, width: width, height: storageHeight)
            self.additional.frame = CGRect(x: 0, y: storageHeight + 8, width: width, height: additionalHeight)
            self.separator.frame = CGRect(x: 63, y: storageHeight, width: max(0, width - 80), height: 0.5)
            y += storageHeight + additionalHeight + 24
            self.footer.frame = CGRect(x: 0, y: y, width: width, height: self.footer.font.lineHeight + 6); y = self.footer.frame.maxY + 12
        }
        self.contentView.frame = CGRect(x: max(self.safeInsets.left + 16, (self.layoutSize.width - width) / 2), y: 0, width: width, height: y)
        self.scrollView.contentSize = CGSize(width: self.layoutSize.width, height: y)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { self.query = searchText; self.rebuildSearch() }
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { searchBar.setShowsCancelButton(true, animated: !UIAccessibility.isReduceMotionEnabled) }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) { self.query = ""; searchBar.text = nil; searchBar.resignFirstResponder(); searchBar.setShowsCancelButton(false, animated: !UIAccessibility.isReduceMotionEnabled); self.rebuildSearch() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private func rebuildSearch() {
        for row in self.searchRows { row.removeFromSuperview() }; self.searchRows.removeAll()
        if !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for destination in CodeGramDestination.allCases where destination.matches(self.query) {
                let row = CodeGramDashboardRow(destination: destination); row.action = { [weak self] in self?.open(destination) }
                self.contentView.addSubview(row); self.searchRows.append(row)
            }
        }
        self.layoutContent()
        self.scrollView.setContentOffset(CGPoint(x: 0, y: -self.scrollView.contentInset.top), animated: false)
    }
    private func open(_ destination: CodeGramDestination) {
        self.searchBar.resignFirstResponder()
        let controller: ViewController
        switch destination {
        case .privacy: controller = codegramSectionSettingsController(context: self.context, section: .privacy)
        case .ghost: controller = ghostModeSettingsController(context: self.context)
        case .messages: controller = CodeGramOrganizedSectionController(context: self.context, section: .messages)
        case .archive: controller = localMessageArchiveSettingsController(context: self.context)
        case .filters: controller = messageFilterSettingsController(context: self.context)
        case .appearance: controller = codegramSectionSettingsController(context: self.context, section: .appearance)
        case .interface: controller = interfaceTuningSettingsController(context: self.context)
        case .deleted: controller = CodeGramDeletedStyleController(context: self.context)
        case .voice: controller = CodeGramVoiceController(context: self.context)
        case .storage: controller = NikitaToolsController(context: self.context)
        case .rules: controller = CodeGramCapturePolicyController(context: self.context)
        case .content: controller = CodeGramContentController(context: self.context)
        case .peers: controller = CodeGramPeerAppearanceController(context: self.context)
        case .additional: controller = CodeGramOrganizedSectionController(context: self.context, section: .additional)
        }
        self.push(controller)
    }
}

private final class CodeGramOrganizedSectionController: CodeGramTableController {
    enum Section: Equatable { case messages, additional }
    private let section: Section
    init(context: AccountContext, section: Section) { self.section = section; super.init(context: context, title: section == .messages ? "Сообщения" : "Дополнительно") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func makeSections() -> [CodeGramSettingsSection] {
        if self.section == .messages {
            return [CodeGramSettingsSection(title: "История и сохранение", footer: "Параметры локального архива относятся к этому iPhone. Фоновое сохранение на сервере настраивается в разделе «Хранилище и VPS».", rows: [
                self.switchRow("TikTok и Instagram → видео", value: NikitaSettingsStore.shared.sendsSocialLinksAsVideo, detail: "Одну ссылку на публичное видео до 250 МБ скачать через VPS и отправить видеофайлом. Нужна служба VPS версии 5. При ошибке ссылка останется в черновике.", icon: "play.rectangle", changed: { value in NikitaSettingsStore.shared.sendsSocialLinksAsVideo = value }),
                self.textRow("Локальный архив", detail: "Удалённые сообщения и версии правок", icon: "archivebox", action: { [weak self] in guard let self else { return }; self.push(localMessageArchiveSettingsController(context: self.context)) }),
                self.textRow("Оформление удалённых", detail: "Прозрачность, затемнение и рамка", icon: "bubble.left", action: { [weak self] in guard let self else { return }; self.push(CodeGramDeletedStyleController(context: self.context)) }),
                self.textRow("Фильтры сообщений", icon: "line.3.horizontal.decrease.circle", action: { [weak self] in guard let self else { return }; self.push(messageFilterSettingsController(context: self.context)) }),
                self.textRow("Сохранение и доступ", detail: "Копирование, истории и одноразовые медиа", icon: "square.and.arrow.down", action: { [weak self] in guard let self else { return }; self.push(CodeGramContentController(context: self.context)) }) ])]
        } else {
            return [CodeGramSettingsSection(title: "На этом iPhone", footer: "Локальный вид, ресурсы и дополнительные возможности клиента.", rows: [
                self.textRow("Отслеживаемые профили", detail: "История изменений и сохранённые сторис на VPS", icon: "person.crop.circle.badge.clock", action: { [weak self] in guard let self else { return }; self.push(CodeGramTrackedProfilesController(context: self.context)) }),
                self.textRow("Имена и аватары для себя", icon: "person.crop.circle", action: { [weak self] in guard let self else { return }; self.push(CodeGramPeerAppearanceController(context: self.context)) }),
                self.textRow("Ресурсы и локальные функции", detail: "Энергосбережение и локальные возможности", icon: "slider.horizontal.3", action: { [weak self] in guard let self else { return }; self.push(codegramSectionSettingsController(context: self.context, section: .additional)) }) ])]
        }
    }
}


