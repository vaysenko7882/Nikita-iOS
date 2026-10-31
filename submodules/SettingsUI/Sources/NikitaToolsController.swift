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
        self.title = "VPS и VoiceChanger"
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
        case 0: return NikitaVoiceEffect.allCases.count
        case 1: return 1
        case 2: return 6
        default: return 1
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "VOICECHANGER · ГОЛОСОВЫЕ"
        case 1: return "АРХИВ В ФОНЕ"
        case 2: return "ТВОЙ VPS · ЭТОТ АККАУНТ"
        default: return "НИКИТА"
        }
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "Эффект применяется на iPhone во время записи и слышен в предпросмотре и отправленном голосовом. Выбирается при начале записи. На звонки не влияет."
        case 1: return "Клиент сохраняет обновления, пока iOS разрешает работу: запрос до 5 минут, фактическое время может быть значительно короче. После принудительного закрытия нужен VPS."
        case 2: return "Отдельная сессия твоего Telegram работает на VPS. Сервер хранит текст, подписи, версии и сведения о вложениях, полученные после подключения. На iPhone они появляются при синхронизации; фото и видео с VPS не скачиваются. Вход по коду и 2FA выполняется только в терминале своего VPS."
        default: return "Ключ доступа хранится в Keychain. Сервер не подключается, пока ты не включишь интеграцию и не сохранишь настройки."
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            let effect = NikitaVoiceEffect.allCases[indexPath.row]
            cell.textLabel?.text = effect.title
            cell.accessoryType = NikitaSettingsStore.shared.voiceEffect == effect ? .checkmark : .none
        } else if indexPath.section == 1 {
            cell.textLabel?.text = "Продлевать сохранение в фоне"
            let toggle = UISwitch()
            toggle.isOn = NikitaSettingsStore.shared.extendArchiveInBackground
            toggle.addTarget(self, action: #selector(self.backgroundChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else if indexPath.section == 2 {
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Интеграция с VPS"
                let toggle = UISwitch()
                toggle.isOn = self.serverEnabled
                toggle.addTarget(self, action: #selector(self.serverChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
                cell.selectionStyle = .none
            case 1, 2:
                let field = indexPath.row == 1 ? self.addressField : self.tokenField
                field.removeFromSuperview()
                cell.contentView.addSubview(field)
                field.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16.0),
                    field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16.0),
                    field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 14.0),
                    field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -14.0)
                ])
                cell.selectionStyle = .none
            case 3:
                cell.textLabel?.text = "Сохранить настройки VPS"
                cell.textLabel?.textColor = .systemBlue
            case 4:
                cell.textLabel?.text = self.isSyncing ? "Синхронизация…" : "Проверить и синхронизировать"
                cell.textLabel?.textColor = .systemBlue
            default:
                cell.textLabel?.text = self.statusText
                cell.textLabel?.font = .systemFont(ofSize: 14.0)
                cell.textLabel?.textColor = .secondaryLabel
                cell.selectionStyle = .none
            }
        } else {
            cell.textLabel?.text = "Как установить архив на VPS"
            cell.textLabel?.textColor = .systemBlue
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            NikitaSettingsStore.shared.voiceEffect = NikitaVoiceEffect.allCases[indexPath.row]
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
        } else if indexPath.section == 2 && indexPath.row == 3 {
            _ = self.saveServer()
        } else if indexPath.section == 2 && indexPath.row == 4 && !self.isSyncing {
            if self.saveServer() && self.serverEnabled {
                self.isSyncing = true
                self.importedCount = 0
                self.statusText = "Соединяюсь с сервером…"
                self.reloadStatus()
                self.syncPage(remaining: 20)
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
