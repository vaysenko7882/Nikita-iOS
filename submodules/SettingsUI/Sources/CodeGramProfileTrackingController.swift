import AccountContext
import Display
import Foundation
import QuickLook
import TelegramCore
import UIKit

public func codegramProfileTrackingController(context: AccountContext, peerId: EnginePeer.Id, accessHash: Int64?, title: String) -> ViewController {
    CodeGramProfileTrackingController(context: context, peerId: String(peerId.id._internalGetInt64Value()), accessHash: accessHash, title: title)
}

private let profileFieldNames = ["first_name":"Имя","last_name":"Фамилия","username":"Юзернейм","usernames":"Юзернеймы","about":"Описание","birthday":"День рождения","premium":"Premium","verified":"Верификация","emoji_status":"Эмодзи-статус","color":"Цвет имени","profile_color":"Цвет профиля","current_photo_id":"Главная аватарка","stargifts_count":"Количество подарков","personal_channel_id":"Личный канал","business_work_hours":"Часы работы","business_location":"Адрес бизнеса","scam":"Метка мошенничества","fake":"Метка подделки"]

private func profileEventTitle(_ event: [String: Any]) -> String {
    let payload = event["payload"] as? [String: Any] ?? [:]
    switch event["kind"] as? String ?? "" {
    case "tracking.enabled": return "Отслеживание включено"
    case "tracking.disabled": return "Отслеживание выключено"
    case "profile.baseline": return "Исходный снимок профиля"
    case "profile.changed": return "Изменено: \(profileFieldNames[payload["field"] as? String ?? ""] ?? (payload["field"] as? String ?? "профиль"))"
    case "gifts.added": return payload["item_id"] as? String == "_visible_order" ? "Витрина подарков" : "Обнаружен подарок"
    case "gifts.changed": return payload["item_id"] as? String == "_visible_order" ? "Изменилась витрина подарков" : "Изменились данные подарка"
    case "gifts.no_longer_visible": return "Подарок больше не отображается"
    case "avatars.added": return "Обнаружена аватарка"
    case "avatars.changed": return "Изменилась аватарка"
    case "avatars.no_longer_visible": return "Аватарка больше не отображается"
    case "stories.added": return "Обнаружена сторис"
    case "stories.changed": return "Изменилась сторис"
    case "stories.no_longer_visible": return "Сторис больше не доступна в списке"
    case "availability.added": return "Исходная доступность профиля"
    case "availability.changed": return "Изменилась доступность профиля"
    case "notifications.added", "notifications.changed": return "Telegram сообщил об изменении профиля"
    default: return "Изменение профиля"
    }
}
private func profileJSON(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "Не было / не указано" }
    if let string = value as? String { return string.isEmpty ? "Пусто" : string }
    if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]), let text = String(data: data,encoding: .utf8) { return text }
    return String(describing: value)
}
private func profileDate(_ value: Any?) -> String {
    guard let timestamp = value as? NSNumber else { return "Ещё не проверен" }
    return DateFormatter.localizedString(from: Date(timeIntervalSince1970: timestamp.doubleValue), dateStyle: .medium, timeStyle: .medium)
}

private func profileReadable(_ value: Any?) -> String {
    guard let object = value as? [String: Any] else { return profileJSON(value) }
    if let gift = object["gift"] as? [String: Any] {
        let title = gift["title"] as? String ?? gift["slug"] as? String ?? "Подарок \(gift["id"].map { String(describing: $0) } ?? "")"
        let sender = object["sender"] as? [String: Any]
        let name = sender?["title"] as? String ?? [sender?["first_name"] as? String,sender?["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
        let senderText = name.isEmpty ? "Telegram не передал отправителя" : name
        return "\(title)\nОтправитель: \(senderText)\nДата подарка: \(profileDate(object["date"]))\nВсе атрибуты и прежние значения доступны ниже в полных данных."
    }
    if object["blocked_by_target"] != nil {
        var lines = ["ЧС у этого человека: Telegram не раскрывает этот статус."]
        if let visible = object["photo_visible"] as? Bool { lines.append("Аватарка доступна: \(visible ? "да" : "нет")") }
        if let visible = object["about_visible"] as? Bool { lines.append("Описание доступно: \(visible ? "да" : "нет")") }
        if let blocked = object["blocked_by_me"] as? Bool { lines.append("Я заблокировал(а) пользователя: \(blocked ? "да" : "нет")") }
        lines.append("Изменение доступности может быть связано с настройками приватности.")
        return lines.joined(separator: "\n")
    }
    if object["caption"] != nil || object["expire_date"] != nil {
        return "Опубликовано: \(profileDate(object["date"]))\n\(object["caption"] as? String ?? "Без подписи")"
    }
    let fields = object.keys.sorted().compactMap { key -> String? in
        guard let title = profileFieldNames[key], let value = object[key], !(value is NSNull) else { return nil }
        return "\(title): \(profileJSON(value))"
    }
    return fields.isEmpty ? "Полученные данные сохранены. Открой полные данные события, чтобы увидеть все значения." : fields.joined(separator: "\n")
}

final class CodeGramTrackedProfilesController: CodeGramTableController {
    private lazy var client = CodeGramVPSClient(configuration: NikitaSettingsStore.shared.server(account: self.accountKey),accountId: self.accountKey)
    private var profiles: [[String: Any]] = []
    private var message = "Загружаю список VPS…"
    init(context: AccountContext) { super.init(context: context,title: "Отслеживаемые профили") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.client.close() }
    override func loadDisplayNode() { super.loadDisplayNode(); self.load() }
    private func load() {
        self.client.json(path: "profiles",completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): self.message = error.message
            case let .success(value): self.profiles = value["profiles"] as? [[String: Any]] ?? []; self.message = self.profiles.isEmpty ? "Открой профиль человека → «Отслеживание профиля»." : "Настройки и история хранятся на VPS этого аккаунта."
            }
            self.reloadContent()
        })
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        var rows = [self.textRow("Обновить список",detail: self.message,icon: "arrow.clockwise",action: { [weak self] in self?.load() })]
        rows += self.profiles.compactMap { item in
            guard let id = item["peer_id"] as? String else { return nil }
            let title = item["title"] as? String ?? id
            return self.textRow(title,detail: item["enabled"] as? Bool == true ? "Отслеживание включено" : "Выключено · история сохранена",icon: "person.crop.circle.badge.clock",action: { [weak self] in
                guard let self else { return }
                self.push(CodeGramProfileTrackingController(context: self.context,peerId: id,accessHash: nil,title: title))
            })
        }
        return [CodeGramSettingsSection(title: "Профили",footer: "Отключение останавливает новые проверки и сохраняет уже полученную историю.",rows: rows)]
    }
}

private final class CodeGramProfileTrackingController: CodeGramTableController {
    private let peerId: String
    private let accessHash: Int64?
    private let peerTitle: String
    private lazy var client = CodeGramVPSClient(configuration: NikitaSettingsStore.shared.server(account: self.accountKey), accountId: self.accountKey)
    private var enabled = false
    private var busy = false
    private var loaded = false
    private var message = "Проверяю настройки VPS…"
    private var lastCheck: Any?
    private var events: [[String: Any]] = []
    private var before = 0
    private var hasMore = false
    init(context: AccountContext, peerId: String, accessHash: Int64?, title: String) {
        self.peerId = peerId; self.accessHash = accessHash; self.peerTitle = title
        super.init(context: context,title: "История профиля")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.client.close() }
    override func loadDisplayNode() { super.loadDisplayNode(); self.load(reset: true) }
    private func load(reset: Bool) {
        guard !self.busy else { return }
        self.busy = true
        self.client.json(path: "profiles/\(self.peerId)/history", query: ["before":reset ? "0" : String(self.before)]) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case let .failure(error): self.message = error.message
            case let .success(value):
                self.applyStatus(value)
                if reset { self.events = [] }
                let existing = Set(self.events.compactMap { ($0["seq"] as? NSNumber)?.int64Value })
                self.events.append(contentsOf: (value["events"] as? [[String: Any]] ?? []).filter { !existing.contains(($0["seq"] as? NSNumber)?.int64Value ?? -1) })
                self.before = value["next_before"] as? Int ?? 0
                self.hasMore = value["has_more"] as? Bool ?? false
            }
            self.reloadContent()
        }
    }
    private func applyStatus(_ value: [String: Any]) {
        guard let item = (value["profiles"] as? [[String: Any]])?.first else { return }
        self.enabled = item["enabled"] as? Bool ?? false
        self.loaded = true
        self.lastCheck = item["last_check"]
        let error = item["error"] as? String ?? ""
        self.message = error.isEmpty ? (self.enabled ? "Отслеживание включено. Работает на VPS." : "Отслеживание выключено. Прежняя история сохранена.") : "Последняя проверка не завершилась: \(error)"
        NikitaSettingsStore.shared.setProfileTracked(self.enabled, account: self.accountKey, peerId: self.peerId)
    }
    private func setEnabled(_ enabled: Bool) {
        guard !self.busy else { return }
        if enabled && self.accessHash == nil {
            self.notice("Открой этот профиль в Telegram и включи отслеживание оттуда: серверу нужен доступ к пользователю от текущего аккаунта.")
            self.reloadContent(); return
        }
        self.busy = true
        var body: [String: Any] = ["enabled":enabled,"title":self.peerTitle]
        if let accessHash = self.accessHash { body["access_hash"] = String(accessHash) }
        self.client.json(path: "profiles/\(self.peerId)",method: "PUT",body: body) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case let .success(value): self.applyStatus(value); self.load(reset: true)
            case let .failure(error): self.message = error.message
            }
            self.reloadContent()
        }
        self.reloadContent()
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        var sections = [CodeGramSettingsSection(title: self.peerTitle, footer: "События профиля и сторис записываются сразу после получения от Telegram. Очередь проверок профиля — от 30 секунд, подарков — от 5 минут; при лимитах Telegram проверки замедляются. Изменения между проверками могут быть пропущены. Telegram не раскрывает, кто добавил тебя в ЧС: изменения доступности фото и описания отмечаются отдельно и не считаются подтверждением блокировки.", rows: [
            self.switchRow("Отслеживание профиля",value: self.enabled,detail: self.message,icon: "person.crop.circle.badge.clock",enabled: self.loaded && !self.busy,changed: { [weak self] in self?.setEnabled($0) }),
            self.textRow("Последняя успешная проверка",detail: (self.lastCheck as? NSNumber)?.int64Value == 0 ? "Ещё не проверен" : profileDate(self.lastCheck),icon: "clock"),
            self.textRow(self.busy ? "Обновляю…" : "Обновить историю",icon: "arrow.clockwise",action: { [weak self] in self?.load(reset: true) })])]
        var rows = self.events.map { event in
            self.textRow(profileEventTitle(event),detail: profileDate(event["observed_at"]),icon: "clock.arrow.circlepath",action: { [weak self] in
                guard let self else { return }
                self.push(CodeGramProfileEventController(context: self.context,event: event))
            })
        }
        if self.hasMore { rows.append(self.textRow("Загрузить ещё",icon: "ellipsis",action: { [weak self] in self?.load(reset: false) })) }
        if rows.isEmpty { rows.append(self.textRow("История пока пуста",detail: "После включения дождись первой проверки VPS.",icon: "tray")) }
        sections.append(CodeGramSettingsSection(title: "История изменений",footer: "Дата события в списке — время обнаружения на VPS. Исходные даты Telegram и все полученные данные находятся внутри события.",rows: rows))
        return sections
    }
}

private final class CodeGramProfileEventController: CodeGramTableController, QLPreviewControllerDataSource {
    private let event: [String: Any]
    private lazy var client = CodeGramVPSClient(configuration: NikitaSettingsStore.shared.server(account: self.accountKey), accountId: self.accountKey)
    private var files: [URL] = []
    private var previewURL: URL?
    private var download: URLSessionDownloadTask?
    private var opening = false
    private var cancelledDownload = false
    private var expanded = false
    init(context: AccountContext,event: [String: Any]) { self.event = event; super.init(context: context,title: profileEventTitle(event)) }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.client.close(); for file in self.files { try? FileManager.default.removeItem(at: file) } }
    override func makeSections() -> [CodeGramSettingsSection] {
        let payload = self.event["payload"] as? [String: Any] ?? [:]
        var sections = [CodeGramSettingsSection(title: "Обнаружено на VPS",footer: nil,rows: [self.textRow(profileDate(self.event["observed_at"]),icon: "clock")])]
        for (key,title) in [("before","До изменения"),("after","После изменения")] {
            if let value = payload[key], !(value is NSNull) {
                sections.append(CodeGramSettingsSection(title: title,footer: nil,rows: [self.textRow(profileReadable(value),icon: "text.alignleft")]))
            }
        }
        let assets = self.event["media"] as? [[String: Any]] ?? []
        if !assets.isEmpty {
            sections.append(CodeGramSettingsSection(title: "Сохранённые файлы",footer: "Файл скачивается на iPhone при открытии.",rows: assets.enumerated().map { index,asset in
                let ready = asset["state"] as? String == "ready"
                return self.textRow("Файл \(index+1)",detail: "\(asset["mime"] as? String ?? "медиа") · \(ready ? "сохранён" : "ещё не готов")",icon: "doc",action: ready ? { [weak self] in self?.open(asset) } : nil)
            }))
        }
        sections.append(CodeGramSettingsSection(title: "Полные данные события",footer: "Если Telegram не передал имя отправителя подарка, журнал не может его восстановить.",rows: [self.textRow(self.expanded ? "Скрыть полные данные" : "Показать все данные и атрибуты",icon: "list.bullet.rectangle",action: { [weak self] in guard let self else { return }; self.expanded.toggle(); self.reloadContent() })] + (self.expanded ? [self.textRow(profileJSON(payload),icon: "text.alignleft")] : [])))
        return sections
    }
    private func open(_ asset: [String: Any]) {
        guard !self.opening, let id = asset["blob_id"] as? String, id.range(of: "^[a-f0-9]{64}$",options: .regularExpression) != nil,
            let size = asset["size"] as? NSNumber else { return }
        self.opening = true
        self.cancelledDownload = false
        self.client.json(path: "profiles",completion: { [weak self] result in
            guard let self else { return }
            guard case let .success(value) = result, let epoch = value["server_id"] as? String else {
                self.opening = false
                if case let .failure(error) = result { self.notice(error.message) }; return
            }
            let mime = asset["mime"] as? String ?? ""
            let ext = mime == "video/mp4" ? "mp4" : mime == "image/jpeg" ? "jpg" : mime == "image/png" ? "png" : mime.contains("ogg") ? "ogg" : mime.contains("webp") ? "webp" : "bin"
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-profile-\(UUID().uuidString).\(ext)")
            let alert = UIAlertController(title: "Загрузка файла",message: "Файл из истории профиля скачивается на iPhone…",preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отменить",style: .cancel,handler: { [weak self] _ in self?.cancelledDownload = true; self?.download?.cancel() }))
            self.present(alert,animated: true)
            self.download = self.client.download(path: "media/\(id)",epoch: epoch,size: size.int64Value,destination: destination,completion: { [weak self,weak alert] result in
                guard let self else {
                    if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.download = nil
                self.opening = false
                if self.cancelledDownload {
                    if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                let presentResult = { [weak self] in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): self.notice(error.message)
                    case let .success(url):
                        self.files.append(url); self.previewURL = url
                        let preview = QLPreviewController(); preview.dataSource = self
                        self.present(preview,animated: true)
                    }
                }
                if let alert { codeGramDismissMediaActions(alert, perform: presentResult) } else { presentResult() }
            })
        })
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { self.previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController,previewItemAt index: Int) -> QLPreviewItem { self.previewURL! as NSURL }
}
