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
    case "stories.deleted": return "Сторис удалена"
    case "stories.content_recovered": return "Сохранено содержимое удалённой сторис"
    case "stories.no_longer_visible": return "Сторис больше не доступна в списке"
    case "availability.added": return "Исходная доступность профиля"
    case "availability.changed": return "Изменилась доступность профиля"
    case "block_signals.possible_restriction": return "Возможная блокировка · косвенные признаки"
    case "block_signals.visibility_restored": return "Доступность профиля восстановилась"
    case "block_signals.inconclusive": return "Признаки ограничения стали неоднозначны"
    case "own_blocklist.blocked": return "Вы добавили пользователя в ЧС"
    case "own_blocklist.unblocked": return "Вы убрали пользователя из ЧС"
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

private func profileBlockSummary(_ value: [String: Any]?) -> String {
    switch value?["state"] as? String {
    case "possible_restriction": return "Возможен ЧС или изменение приватности · не подтверждено"
    case "visibility_restored": return "Доступность восстановилась · это не подтверждение снятия ЧС"
    case "visibility_available": return "Статус и фото доступны · чужой ЧС не раскрывается"
    default: return "Недостаточно признаков · точный статус не раскрывается"
    }
}

private func profileBlockDetails(_ value: [String: Any]?) -> String {
    var lines = [profileBlockSummary(value)]
    if value?["state"] as? String == "possible_restriction" {
        lines.append("В течение короткого времени после доступного статуса и фото оба признака исчезли. Это может быть ЧС, но те же данные могут измениться из-за приватности или неактивности.")
    } else if value?["state"] as? String == "visibility_restored" {
        lines.append("Telegram снова передал доступный статус или фото. Отдельного события «вас разблокировали» он не передаёт.")
    }
    if let observed = value?["observed_at"] as? NSNumber { lines.append("Получено на VPS: \(profileDate(observed))") }
    lines.append("Подарки не используются как доказательство ЧС. Ваша собственная блокировка записывается отдельно. Это оценка по полученным данным, а не доступ к чужому чёрному списку.")
    return lines.joined(separator: "\n\n")
}

private func profileReadable(_ value: Any?) -> String {
    guard let object = value as? [String: Any] else { return profileJSON(value) }
    if object["state"] != nil && object["certainty"] != nil && object["blocked_by_target"] != nil {
        return profileBlockDetails(object)
    }
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
    if object["caption"] != nil || object["expire_date"] != nil || object["content_state"] != nil {
        let loading = object["content_state"] as? String == "not_loaded" ? "\nПолучено событие сторис; содержимое ещё не загружено." : ""
        return "Опубликовано: \(profileDate(object["date"]))\n\(object["caption"] as? String ?? "Без подписи")\(loading)"
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
    private var lastStoryCheck: Any?
    private var storyPollingInterval: Double?
    private var blockAssessment: [String: Any]?
    private var renderedHistory = CodeGramProfileHistorySnapshot()
    private var events: [[String: Any]] { self.renderedHistory.events }
    private var historyScreenVisible = false
    private var pendingRender = false
    private var renderRetry: DispatchWorkItem?
    private var resetToTop = false
    private lazy var feed = CodeGramProfileHistoryFeed(fetch: { [weak self] before, completion in
        guard let self else { return nil }
        let task = self.client.json(path: "profiles/\(self.peerId)/history", query: ["before":String(before)]) { result in
            completion(result.mapError { $0 as Error })
        }
        return { task?.cancel() }
    })
    init(context: AccountContext, peerId: String, accessHash: Int64?, title: String) {
        self.peerId = peerId; self.accessHash = accessHash; self.peerTitle = title
        super.init(context: context,title: "История профиля")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.renderRetry?.cancel(); self.feed.setVisible(false); self.client.close() }
    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.feed.updated = { [weak self] value, automatic in
            guard let self else { return }
            self.applyStatus(value)
            self.renderHistory(automatic: automatic)
        }
        self.feed.failed = { [weak self] error, automatic in
            guard let self else { return }
            self.message = error.localizedDescription
            self.renderHistory(automatic: automatic)
        }
        self.load(reset: true)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.historyScreenVisible = true
        if self.pendingRender { self.renderHistory(automatic: true) }
        self.feed.setVisible(true)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.historyScreenVisible = false
        self.renderRetry?.cancel(); self.renderRetry = nil
        self.feed.setVisible(false)
    }
    private func load(reset: Bool) {
        guard !self.busy else { return }
        if reset {
            self.resetToTop = true
            self.feed.refresh()
        } else {
            self.feed.loadOlder()
        }
        self.reloadContent()
    }
    private func renderHistory(automatic: Bool) {
        if automatic && (!self.historyScreenVisible || self.tableView.isDragging || self.tableView.isDecelerating) {
            self.pendingRender = true
            self.renderRetry?.cancel()
            if self.historyScreenVisible {
                let work = DispatchWorkItem { [weak self] in self?.renderHistory(automatic: true) }
                self.renderRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now()+0.2,execute: work)
            }
            return
        }
        self.pendingRender = false
        self.renderRetry?.cancel(); self.renderRetry = nil
        let anchor = CodeGramProfileHistoryScrollAnchor(table: self.tableView,events: self.events)
        self.renderedHistory = self.feed.snapshot
        UIView.performWithoutAnimation {
            self.reloadContent()
            self.tableView.layoutIfNeeded()
            anchor.restore(table: self.tableView,events: self.events,resetToTop: self.resetToTop)
        }
        self.resetToTop = false
    }
    private func applyStatus(_ value: [String: Any]) {
        guard let item = (value["profiles"] as? [[String: Any]])?.first else { return }
        self.enabled = item["enabled"] as? Bool ?? false
        self.loaded = true
        self.lastCheck = item["last_check"]
        self.lastStoryCheck = item["last_story_check"]
        self.blockAssessment = item["block_assessment"] as? [String: Any]
        if let interval = (value["story_poll_interval"] as? NSNumber)?.doubleValue, interval.isFinite, interval >= 1, interval <= 3600 {
            self.storyPollingInterval = interval
        } else {
            self.storyPollingInterval = nil
        }
        let error = item["error"] as? String ?? ""
        self.message = error.isEmpty ? (self.enabled ? "Отслеживание включено. Работает на VPS." : "Отслеживание выключено. Прежняя история сохранена.") : "Последняя проверка не завершилась: \(error)"
        if let lastEvent = item["last_event_at"] as? NSNumber, lastEvent.doubleValue > 0 {
            self.message += "\nПоследнее полученное событие: \(profileDate(lastEvent))"
        }
        if let storyError = item["story_error"] as? String, !storyError.isEmpty {
            self.message += "\nПроверка сторис: \(storyError)"
        }
        if self.storyPollingInterval == nil {
            self.message += "\nДля отдельной быстрой проверки сторис обнови службу VPS до 5.2.0."
        }
        if NikitaSettingsStore.shared.isProfileTracked(account: self.accountKey, peerId: self.peerId) != self.enabled {
            NikitaSettingsStore.shared.setProfileTracked(self.enabled, account: self.accountKey, peerId: self.peerId)
        }
    }
    private func setEnabled(_ enabled: Bool) {
        guard !self.busy, !self.feed.isUserLoading else { return }
        if enabled && self.accessHash == nil {
            self.notice("Открой этот профиль в Telegram и включи отслеживание оттуда: серверу нужен доступ к пользователю от текущего аккаунта.")
            self.reloadContent(); return
        }
        self.busy = true
        self.feed.setVisible(false)
        var body: [String: Any] = ["enabled":enabled,"title":self.peerTitle]
        if let accessHash = self.accessHash { body["access_hash"] = String(accessHash) }
        self.client.json(path: "profiles/\(self.peerId)",method: "PUT",body: body) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case let .success(value): self.applyStatus(value); self.load(reset: true)
            case let .failure(error): self.message = error.message
            }
            if self.historyScreenVisible { self.feed.setVisible(true) }
            self.reloadContent()
        }
        self.reloadContent()
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        let storyTiming = self.storyPollingInterval.map { "Сторис проверяются отдельной очередью от \(Int($0)) секунд." } ?? "Отдельная быстрая проверка сторис требует обновления службы VPS до 5.2.0."
        var sections = [CodeGramSettingsSection(title: self.peerTitle, footer: "Полученные события профиля и сторис записываются сразу. \(storyTiming) Профиль — от 15 секунд, подарки — от минуты. Полученные изменения видимости обрабатываются сразу; ожидание нового события Telegram не имеет гарантированного срока. Очередь профилей, сеть и лимиты могут увеличить задержку. Удалённую до получения события и файла сторис восстановить нельзя.", rows: [
            self.switchRow("Отслеживание профиля",value: self.enabled,detail: self.message,icon: "person.crop.circle.badge.clock",enabled: self.loaded && !self.busy && !self.feed.isUserLoading,changed: { [weak self] in self?.setEnabled($0) }),
            self.textRow("Последняя успешная проверка",detail: (self.lastCheck as? NSNumber)?.int64Value == 0 ? "Ещё не проверен" : profileDate(self.lastCheck),icon: "clock"),
            self.textRow("Последняя успешная проверка сторис",detail: ((self.lastStoryCheck as? NSNumber)?.int64Value ?? 0) == 0 ? "Ещё не проверены" : profileDate(self.lastStoryCheck),icon: "clock.arrow.circlepath"),
            self.textRow("ЧС у человека: косвенные признаки",detail: profileBlockSummary(self.blockAssessment),icon: "person.crop.circle.badge.questionmark",action: { [weak self] in
                guard let self else { return }
                self.notice(profileBlockDetails(self.blockAssessment))
            }),
            self.textRow(self.busy || self.feed.isUserLoading ? "Обновляю…" : "Обновить историю",icon: "arrow.clockwise",action: { [weak self] in self?.load(reset: true) })])]
        let rendered = self.renderedHistory
        var rows = rendered.events.enumerated().map { index, event in
            self.textRow(profileEventTitle(event),detail: profileDate(event["observed_at"]),icon: "clock.arrow.circlepath",action: { [weak self] in
                guard let self else { return }
                guard let selected = rendered.event(at: index,currentServerId: self.feed.serverId) else {
                    self.notice("Архив обновился. Дождись обновления списка и открой запись ещё раз.")
                    return
                }
                self.push(CodeGramProfileEventController(context: self.context,peerId: self.peerId,event: selected,serverId: rendered.serverId))
            })
        }
        if self.feed.hasMore { rows.append(self.textRow("Загрузить ещё",icon: "ellipsis",action: { [weak self] in self?.load(reset: false) })) }
        if rows.isEmpty { rows.append(self.textRow("История пока пуста",detail: "После включения дождись первой проверки VPS.",icon: "tray")) }
        sections.append(CodeGramSettingsSection(title: "История изменений",footer: "Полученные VPS события добавляются автоматически, пока экран открыт. История обновляется и при просмотре старых записей, сохраняя место чтения. Проверка iPhone — каждые 2 секунды; скорость получения самой сторис зависит от Telegram и очереди VPS. Дата события — время обнаружения на VPS.",rows: rows))
        return sections
    }
}

private final class CodeGramProfileEventController: CodeGramTableController, QLPreviewControllerDataSource {
    private let event: [String: Any]
    private let peerId: String
    private var archiveId: String?
    private var media: [[String: Any]]
    private var mediaNote: String?
    private var mediaDeadline = Date.distantPast
    private var eventScreenVisible = false
    private lazy var client = CodeGramVPSClient(configuration: NikitaSettingsStore.shared.server(account: self.accountKey), accountId: self.accountKey)
    private lazy var mediaFeed = CodeGramProfileHistoryFeed(fetch: { [weak self] _, completion in
        guard let self else { return nil }
        guard Date() < self.mediaDeadline else {
            completion(.failure(CodeGramVPSError("VPS ещё не закончил загрузку файла. История сохранена; проверку можно повторить.")))
            return nil
        }
        guard let seq = (self.event["seq"] as? NSNumber)?.int64Value, seq > 0, seq < Int64.max else {
            completion(.failure(CodeGramVPSError("Некорректный номер события."))); return nil
        }
        let task = self.client.json(path: "profiles/\(self.peerId)/history",query: ["before":String(seq+1),"limit":"1"]) { result in
            completion(result.mapError { $0 as Error })
        }
        return { task?.cancel() }
    })
    private var files: [URL] = []
    private var previewURL: URL?
    private var download: URLSessionDownloadTask?
    private var opening = false
    private var cancelledDownload = false
    private var expanded = false
    init(context: AccountContext,peerId: String,event: [String: Any],serverId: String?) {
        self.event = event; self.peerId = peerId; self.archiveId = serverId
        self.media = event["media"] as? [[String: Any]] ?? []
        super.init(context: context,title: profileEventTitle(event))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.mediaFeed.setVisible(false); self.client.close(); for file in self.files { try? FileManager.default.removeItem(at: file) } }
    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.mediaFeed.updated = { [weak self] page, _ in
            guard let self else { return }
            guard let epoch = page["server_id"] as? String, self.archiveId == nil || self.archiveId == epoch,
                let received = (page["events"] as? [[String: Any]])?.first,
                (received["seq"] as? NSNumber)?.int64Value == (self.event["seq"] as? NSNumber)?.int64Value else {
                self.mediaNote = "Архив изменился или эта запись недоступна. Вернись в историю профиля."
                self.mediaFeed.setVisible(false); self.reloadContent(); return
            }
            self.archiveId = epoch
            let original = self.event["media"] as? [[String: Any]] ?? []
            let available = received["media"] as? [[String: Any]] ?? []
            let media = original.map { asset -> [String: Any] in
                if let id = asset["blob_id"] as? String, let current = available.first(where: { $0["blob_id"] as? String == id }) { return current }
                var unavailable = asset
                unavailable["state"] = "failed"
                return unavailable
            }
            let changed = !(self.media as NSArray).isEqual(media as NSArray) || self.mediaNote != nil
            self.media = media; self.mediaNote = nil
            if !self.hasPendingMedia { self.mediaFeed.setVisible(false) }
            if changed { self.reloadContent() }
        }
        self.mediaFeed.failed = { [weak self] error, _ in
            guard let self else { return }
            let message = error.localizedDescription
            let changed = self.mediaNote != message
            self.mediaNote = message
            if Date() >= self.mediaDeadline { self.mediaFeed.setVisible(false) }
            if changed { self.reloadContent() }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.eventScreenVisible = true
        self.checkMedia()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.eventScreenVisible = false
        self.mediaFeed.setVisible(false)
    }
    private var hasPendingMedia: Bool {
        self.media.contains { asset in
            let state = asset["state"] as? String ?? "pending"
            return state != "ready" && state != "failed"
        }
    }
    private func checkMedia() {
        guard self.eventScreenVisible, self.hasPendingMedia else { return }
        self.mediaDeadline = Date().addingTimeInterval(120)
        self.mediaNote = nil
        self.mediaFeed.setVisible(true)
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        let payload = self.event["payload"] as? [String: Any] ?? [:]
        var sections = [CodeGramSettingsSection(title: "Обнаружено на VPS",footer: nil,rows: [self.textRow(profileDate(self.event["observed_at"]),icon: "clock")])]
        for (key,title) in [("before","До изменения"),("after","После изменения")] {
            if let value = payload[key], !(value is NSNull) {
                sections.append(CodeGramSettingsSection(title: title,footer: nil,rows: [self.textRow(profileReadable(value),icon: "text.alignleft")]))
            }
        }
        let assets = self.media
        if !assets.isEmpty {
            sections.append(CodeGramSettingsSection(title: "Сохранённые файлы",footer: self.mediaNote ?? "Статус загрузки на VPS обновляется автоматически до двух минут, пока эта запись открыта. Полученный файл скачивается на iPhone при открытии.",rows: assets.enumerated().map { index,asset in
                let ready = asset["state"] as? String == "ready"
                let status = ready ? "сохранён" : asset["state"] as? String == "failed" ? "байты недоступны" : "ожидает загрузки VPS"
                return self.textRow("Файл \(index+1)",detail: "\(asset["mime"] as? String ?? "медиа") · \(status)",icon: "doc",action: ready ? { [weak self] in self?.open(asset) } : nil)
            } + (self.hasPendingMedia ? [self.textRow("Проверить файлы",icon: "arrow.clockwise",action: { [weak self] in self?.checkMedia() })] : [])))
        } else if let after = payload["after"] as? [String: Any], after["content_state"] as? String == "not_loaded" {
            sections.append(CodeGramSettingsSection(title: "Содержимое сторис",footer: "Эта запись хранит первоначальное уведомление Telegram. Полное содержимое, если сервер успеет его получить, появится отдельным событием истории.",rows: [self.textRow("Пока получено только уведомление",icon: "info.circle")]))
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
            guard case let .success(value) = result, let epoch = value["server_id"] as? String,
                self.archiveId == nil || self.archiveId == epoch else {
                self.opening = false
                if case let .failure(error) = result { self.notice(error.message) }
                else { self.notice("Архив изменился. Вернись в историю профиля.") }
                return
            }
            let mime = asset["mime"] as? String ?? ""
            let ext = mime == "video/mp4" ? "mp4" : mime == "image/jpeg" ? "jpg" : mime == "image/png" ? "png" : mime.contains("ogg") ? "ogg" : mime.contains("webp") ? "webp" : "bin"
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-profile-\(UUID().uuidString).\(ext)")
            let alert = CodeGramPlainAlertController(title: "Загрузка файла",message: "Файл из истории профиля скачивается на iPhone…",preferredStyle: .alert)
            alert.addAction(CodeGramPlainAlertAction(title: "Отменить",style: .cancel,handler: { [weak self] _ in self?.cancelledDownload = true; self?.download?.cancel() }))
            self.present(alert,animated: true)
            self.download = self.client.download(path: "media/\(id)",epoch: epoch,size: size.int64Value,destination: destination,completion: { [weak self,weak alert] result in
                guard let self else {
                    if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.download = nil
                self.opening = false
                if self.cancelledDownload || alert?.isBeingDismissed == true {
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

