import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Device-side effects and an opt-in connection to the owner's archive service.
public final class NikitaToolsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let addressField = UITextField()
    private let tokenField = UITextField()
    private var serverEnabled: Bool
    private var statusText = "Сервер не проверен."
    private let syncDisposable = MetaDisposable()
    private var isSyncing = false
    private var importedCount = 0

    private var accountKey: String { return String(self.context.account.peerId.id._internalGetInt64Value()) }

    public init(context: AccountContext) {
        self.context = context
        let configuration = NikitaSettingsStore.shared.server(account: String(context.account.peerId.id._internalGetInt64Value()))
        self.serverEnabled = configuration.enabled
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = "Хранилище и VPS"
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "Назад", style: .plain, target: nil, action: nil)
        self.statusBar.statusBarStyle = context.sharedContext.currentPresentationData.with { $0 }.theme.rootController.statusBarStyle.style
        self.addressField.text = configuration.address
        self.addressField.placeholder = "https://archive.example.com"
        self.addressField.keyboardType = .URL
        self.addressField.autocapitalizationType = .none
        self.addressField.autocorrectionType = .no
        self.addressField.textContentType = .URL
        self.tokenField.text = configuration.token
        self.tokenField.placeholder = "Ключ доступа с твоего VPS"
        self.tokenField.isSecureTextEntry = true
        self.tokenField.autocapitalizationType = .none
        self.tokenField.autocorrectionType = .no
        self.tokenField.spellCheckingType = .no
        self.tokenField.textContentType = .password
    }

    required public init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { self.syncDisposable.dispose() }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        let dark = self.context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance
        self.displayNode.view.overrideUserInterfaceStyle = dark ? .dark : .light
        self.displayNode.backgroundColor = dark ? .black : .systemGroupedBackground
        CodeGramSettingsTheme.configure(self.tableView)
        let dark = self.context.sharedContext.currentPresentationData.with { $0 }.theme.overallDarkAppearance
        self.tableView.overrideUserInterfaceStyle = dark ? .dark : .light
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.keyboardDismissMode = .interactive
        self.tableView.contentInsetAdjustmentBehavior = .never
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 52.0
        self.displayNode.view.addSubview(self.tableView)
        self.displayNodeDidLoad()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.tableView.frame = CGRect(origin: .zero, size: layout.size)
        let insets = layout.insets(options: .input)
        self.tableView.contentInset = UIEdgeInsets(top: self.cleanNavigationHeight, left: layout.safeInsets.left,
            bottom: insets.bottom + 12.0, right: layout.safeInsets.right)
        self.tableView.scrollIndicatorInsets = self.tableView.contentInset
    }

    public func numberOfSections(in tableView: UITableView) -> Int { return 4 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return 1
        case 2: return 6
        default: return 1
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "АРХИВ И ПАМЯТЬ"
        case 1: return "АРХИВ В ФОНЕ"
        case 2: return "ТВОЙ VPS · ЭТОТ АККАУНТ"
        default: return "CODEGRAM"
        }
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "Объём файлов на iPhone и VPS, правила фонового сохранения и исключения для отдельных диалогов."
        case 1: return "Клиент сохраняет обновления, пока iOS разрешает работу: до 60 секунд, при энергосбережении до 15 секунд; при сильном нагреве дополнительное время не запрашивается. iOS может остановить работу раньше. После принудительного закрытия нужен VPS."
        case 2: return "VPS сохраняет полученные фото, видео, кружочки, голосовые, стикеры, GIF, музыку и файлы, даже когда iPhone закрыт. После синхронизации вложения открываются в чате и скачиваются частями. Файлы должны успеть загрузиться до потери доступа в Telegram. При нехватке места очередь приостанавливается; старые файлы не удаляются. Для новых правил и статистики обнови VPS до версии 4. Сохранение подчиняется настройкам в разделе «Правила VPS»."
        default: return "Ключ доступа хранится в Keychain. Сервер не подключается, пока ты не включишь интеграцию и не сохранишь настройки."
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            return CodeGramTextCell(title: ["Использование памяти", "Правила сохранения VPS"][indexPath.row], symbol: ["internaldrive", "line.3.horizontal.decrease.circle"][indexPath.row], disclosure: true)
        } else if indexPath.section == 1 {
            let toggle = CodeGramValueSwitch()
            toggle.isOn = NikitaSettingsStore.shared.extendArchiveInBackground
            toggle.addTarget(self, action: #selector(self.backgroundChanged(_:)), for: .valueChanged)
            return CodeGramTextCell(title: "Продлевать сохранение в фоне", symbol: "clock.badge.checkmark", control: toggle)
        } else if indexPath.section == 2 {
            switch indexPath.row {
            case 0:
                let toggle = CodeGramValueSwitch(); toggle.isOn = self.serverEnabled
                toggle.addTarget(self, action: #selector(self.serverChanged(_:)), for: .valueChanged)
                return CodeGramTextCell(title: "Интеграция с VPS", symbol: "server.rack", control: toggle)
            case 1, 2:
                return CodeGramFieldCell(field: indexPath.row == 1 ? self.addressField : self.tokenField, symbol: indexPath.row == 1 ? "link" : "key")
            case 3:
                return CodeGramTextCell(title: "Сохранить настройки VPS", symbol: "square.and.arrow.down")
            case 4:
                return CodeGramTextCell(title: self.isSyncing ? "Синхронизация…" : "Проверить и синхронизировать", symbol: "arrow.triangle.2.circlepath")
            default:
                return CodeGramTextCell(title: self.statusText, symbol: "info.circle")
            }
        }
        return CodeGramTextCell(title: "Как установить архив на VPS", symbol: "terminal", disclosure: true)
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let controller: ViewController
            switch indexPath.row {
            case 0: controller = CodeGramStorageController(context: self.context)
            default: controller = CodeGramCapturePolicyController(context: self.context)
            }
            (self.navigationController as? NavigationController)?.pushViewController(controller)
        } else if indexPath.section == 2 && indexPath.row == 3 {
            _ = self.saveServer()
        } else if indexPath.section == 2 && indexPath.row == 4 && !self.isSyncing {
            if self.saveServer() && self.serverEnabled {
                self.isSyncing = true
                self.importedCount = 0
                self.statusText = "Соединяюсь с сервером…"
                self.reloadStatus()
                self.syncPage(remaining: CodeGramEnergyPolicy.current.pageBudget)
            }
        } else if indexPath.section == 3 {
            self.context.sharedContext.applicationBindings.openUrl("https://github.com/vaysenko7882/Nikita-iOS/blob/master/server/README.md")
        }
    }

    @objc private func backgroundChanged(_ sender: UISwitch) {
        NikitaSettingsStore.shared.extendArchiveInBackground = sender.isOn
    }

    @objc private func serverChanged(_ sender: UISwitch) {
        self.serverEnabled = sender.isOn
        if !sender.isOn {
            let current = NikitaSettingsStore.shared.server(account: self.accountKey)
            if !NikitaSettingsStore.shared.setServer(NikitaServerConfiguration(enabled: false, address: current.address, token: current.token), account: self.accountKey) {
                self.statusText = "Не удалось сохранить отключение. Повтори после разблокировки iPhone."
            } else {
                self.syncDisposable.set(nil)
                self.isSyncing = false
                self.statusText = "Интеграция на iPhone отключена. Службу на VPS можно остановить отдельно."
            }
            self.reloadStatus()
        }
    }

    @discardableResult private func saveServer() -> Bool {
        self.view.endEditing(true)
        let configuration = NikitaServerConfiguration(enabled: self.serverEnabled, address: self.addressField.text ?? "", token: self.tokenField.text ?? "")
        if configuration.enabled && (configuration.baseURL == nil || !configuration.hasValidToken) {
            self.statusText = "Нужен HTTPS-адрес и ключ доступа, который выдал установщик VPS."
            self.reloadStatus()
            return false
        }
        guard NikitaSettingsStore.shared.setServer(configuration, account: self.accountKey) else {
            self.statusText = "Не удалось записать ключ в Keychain. Повтори после разблокировки iPhone."
            self.reloadStatus()
            return false
        }
        self.statusText = "Настройки сохранены. Нажми «Проверить и синхронизировать»."
        self.reloadStatus()
        return true
    }

    private func reloadStatus() {
        self.tableView.reloadRows(at: [IndexPath(row: 4, section: 2), IndexPath(row: 5, section: 2)], with: .none)
    }

    private func syncPage(remaining: Int) {
        self.syncDisposable.set((self.context.engine.messages.synchronizeNikitaArchive() |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else { return }
            self.importedCount += result.importedCount
            self.statusText = "\(result.message) Импортировано: \(self.importedCount)."
            if result.success && result.hasMore && remaining > 1 {
                Queue.mainQueue().async { [weak self] in self?.syncPage(remaining: remaining - 1) }
            } else {
                self.isSyncing = false
                if result.hasMore { self.statusText += " В журнале ещё есть записи; синхронизация продолжится при открытом приложении." }
            }
            self.reloadStatus()
        }))
    }
}



