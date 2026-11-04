import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

private final class CodeGramNoRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = CodeGramNoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum CodeGramArchiveAPI {
    static func request(account: String, path: String, query: String? = nil, body: [String: Any]? = nil, completion: @escaping (Result<[String: Any], NSError>) -> Void) {
        func fail(_ text: String, code: Int = 0) { DispatchQueue.main.async { completion(.failure(NSError(domain: "CodeGramArchive", code: code, userInfo: [NSLocalizedDescriptionKey: text]))) } }
        let config = NikitaSettingsStore.shared.server(account: account)
        guard config.enabled, config.hasValidToken, let base = config.baseURL else { fail("Сначала включи и сохрани подключение к VPS в настройках CodeGram."); return }
        var components = URLComponents(url: base.appendingPathComponent("v1").appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let query { components?.queryItems = [URLQueryItem(name: "q", value: query)] }
        guard let url = components?.url else { fail("Проверь HTTPS-адрес VPS."); return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "X-CodeGram-Account-ID")
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 256 * 1024 else { fail("Слишком много исключений."); return }
            request.httpMethod = "PUT"; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCache = nil; settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: CodeGramNoRedirect.shared, delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if error != nil { fail("VPS не отвечает. Проверь адрес и доступность сервера."); return }
            guard let http = response as? HTTPURLResponse else { fail("Неверный ответ сервера."); return }
            guard http.statusCode == 200 else {
                let message: String
                switch http.statusCode {
                case 401: message = "VPS отклонил ключ доступа. Проверь ключ в настройках."
                case 403: message = "VPS принадлежит другому аккаунту Telegram."
                case 404: message = "Обнови службу на VPS до версии 4: этот сервер ещё не поддерживает новые настройки."
                case 409: message = "Правила уже изменились на сервере. Обнови список и повтори изменения."
                default: message = "Ошибка VPS (HTTP \(http.statusCode))."
                }
                fail(message, code: http.statusCode); return
            }
            guard let data, data.count <= 2 * 1024 * 1024,
                let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                (result["account_id"] as? NSNumber)?.stringValue == account,
                (result["server_version"] as? Int ?? 0) >= 4 else { fail("Ответ не подходит этому аккаунту или версии CodeGram."); return }
            DispatchQueue.main.async { completion(.success(result)) }
        }.resume()
    }
}

final class CodeGramCapturePolicyController: CodeGramTableController {
    private var defaults = ["private": true, "groups": false, "channels": false, "archived": false]
    private var exceptions: [[String: Any]] = []
    private var dialogs: [[String: Any]] = []
    private var revision: Int?
    private var message = "Загрузка правил с VPS…"
    private var loading = false
    private var saving = false
    private var query = ""
    private var searchWork: DispatchWorkItem?
    private var searchGeneration = 0
    init(context: AccountContext) {
        super.init(context: context, title: "Правила сохранения VPS")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Сохранить", style: .done, target: self, action: #selector(self.save))
        self.navigationItem.rightBarButtonItem?.isEnabled = false
        self.load(refreshRules: true)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.searchWork?.cancel() }
    override func loadDisplayNode() {
        super.loadDisplayNode()
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 68))
        let search = CodeGramSearchView()
        search.frame = header.bounds.insetBy(dx: 20, dy: 6)
        search.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        search.textField.placeholder = "Найти диалог, группу или канал"
        search.onTextChanged = { [weak self] text in self?.searchChanged(text) }
        search.onSubmit = { [weak self] in self?.searchWork?.cancel(); self?.load(refreshRules: false) }
        header.addSubview(search); self.tableView.tableHeaderView = header
    }
    private func searchChanged(_ searchText: String) {
        self.query = String(searchText.prefix(128)); self.searchGeneration += 1
        self.searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load(refreshRules: false) }
        self.searchWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func load(refreshRules: Bool) {
        let generation = self.searchGeneration
        self.loading = true
        CodeGramArchiveAPI.request(account: self.accountKey, path: "policy", query: self.query) { [weak self] result in
            guard let self, generation == self.searchGeneration else { return }
            self.loading = false
            switch result {
            case let .success(payload):
                if refreshRules || self.revision == nil {
                    guard let defaults = payload["defaults"] as? [String: Bool], Set(defaults.keys) == Set(self.defaults.keys),
                        let revision = payload["revision"] as? Int, let exceptions = payload["exceptions"] as? [[String: Any]] else { self.message = "Некорректные правила VPS."; self.reloadContent(); return }
                    self.defaults = defaults; self.revision = revision; self.exceptions = exceptions
                }
                self.dialogs = payload["dialogs"] as? [[String: Any]] ?? []
                self.message = "Правила применяются на VPS после нажатия «Сохранить». Исключений: \(self.exceptions.count)."
            case let .failure(error): self.message = error.localizedDescription
            }
            self.navigationItem.rightBarButtonItem?.isEnabled = self.revision != nil && !self.saving
            self.reloadContent()
        }
    }
    @objc private func save() {
        guard let revision, !self.saving else { return }
        self.saving = true; self.navigationItem.rightBarButtonItem?.isEnabled = false
        let payload: [String: Any] = ["revision": revision, "defaults": self.defaults, "exceptions": self.exceptions]
        CodeGramArchiveAPI.request(account: self.accountKey, path: "policy", body: payload) { [weak self] result in
            guard let self else { return }
            self.saving = false
            switch result {
            case let .success(payload): self.revision = payload["revision"] as? Int; self.message = "Сохранено на VPS. Новые правила уже действуют."
            case let .failure(error): self.message = error.localizedDescription
            }
            self.navigationItem.rightBarButtonItem?.isEnabled = self.revision != nil
            self.reloadContent()
        }
    }
    private func samePeer(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool { (lhs["peer_type"] as? String) == (rhs["peer_type"] as? String) && (lhs["peer_id"] as? NSNumber) == (rhs["peer_id"] as? NSNumber) }
    private func mode(_ dialog: [String: Any]) -> String? { self.exceptions.first(where: { self.samePeer($0, dialog) })?["mode"] as? String }
    private func edit(_ dialog: [String: Any]) {
        guard self.revision != nil else { return }
        let alert = CodeGramPlainAlertController(title: dialog["title"] as? String ?? "Исключение", message: "«Всегда» работает даже в папке «Архив» и при выключенной категории.", preferredStyle: .alert)
        for (title, mode) in [("По общим правилам", "default"), ("Всегда сохранять", "always"), ("Никогда не сохранять", "never")] {
            alert.addAction(CodeGramPlainAlertAction(title: title, style: .default, handler: { [weak self] _ in
                guard let self, let type = dialog["peer_type"] as? String, let id = dialog["peer_id"] as? NSNumber else { return }
                self.exceptions.removeAll(where: { self.samePeer($0, dialog) })
                if mode != "default" {
                    guard self.exceptions.count < 2000 else { self.notice("Достигнут лимит 2000 исключений."); return }
                    self.exceptions.append(["peer_type": type, "peer_id": id, "mode": mode])
                }
                self.message = "Есть несохранённые изменения. Нажми «Сохранить»."; self.reloadContent()
            }))
        }
        alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel)); self.present(alert, animated: true)
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        let rows = [("private", "Личные диалоги", "person"), ("groups", "Группы", "person.2"), ("channels", "Каналы", "megaphone"), ("archived", "Разрешать папку «Архив»", "archivebox")].map { key, title, icon in
            self.switchRow(title, value: self.defaults[key] ?? false, icon: icon, changed: { [weak self] value in self?.defaults[key] = value; self?.message = "Есть несохранённые изменения. Нажми «Сохранить»." })
        }
        let dialogRows = self.dialogs.map { dialog -> CodeGramSettingsRow in
            let mode = self.mode(dialog)
            let archived = dialog["archived"] as? Bool ?? false
            let kind = dialog["kind"] as? String ?? "private"
            let allowed = mode == "always" || (mode != "never" && (self.defaults[kind] ?? false) && (!archived || (self.defaults["archived"] ?? false)))
            let rule = mode == "always" ? "Всегда" : (mode == "never" ? "Никогда" : "По правилам")
            return self.textRow(dialog["title"] as? String ?? "Диалог", detail: "\(archived ? "Архив · " : "")\(rule) · \(allowed ? "сохраняется" : "не сохраняется")", icon: allowed ? "checkmark.circle.fill" : "minus.circle", action: { [weak self] in self?.edit(dialog) })
        }
        return [
            CodeGramSettingsSection(title: "На сервере · этот аккаунт", footer: self.message, rows: [self.textRow(self.loading ? "Загрузка…" : "Обновить правила и список", icon: "arrow.clockwise", action: { [weak self] in self?.load(refreshRules: true) })]),
            CodeGramSettingsSection(title: "По умолчанию", footer: "Новые установки: личные диалоги включены; группы, каналы и папка «Архив» выключены. Разрешение папки не включает выключенную категорию. Уже сохранённое не удаляется при смене правил.", rows: rows),
            CodeGramSettingsSection(title: "Исключения · нажми на диалог", footer: "Поиск выполняется по списку твоих диалогов на VPS. Он обновляется примерно раз в минуту. Исключение «Всегда» имеет приоритет над всеми общими выключателями.", rows: dialogRows.isEmpty ? [self.textRow("Диалогов нет", detail: "Проверь соединение с VPS или измени поисковый запрос.", icon: "bubble.left.and.bubble.right")] : dialogRows)
        ]
    }
}

private func codegramBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .binary) }
private final class CodeGramStorageBar: UIView {
    private let segments: [(String, Int64, UIColor)]
    init(segments: [(String, Int64, UIColor)]) {
        self.segments = segments
        super.init(frame: .zero)
        self.backgroundColor = .tertiarySystemFill; self.layer.cornerRadius = 5; self.clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let total = max(1, self.segments.reduce(Int64(0)) { $0 + $1.1 })
        var x: CGFloat = 0
        for (_, bytes, color) in self.segments where bytes > 0 {
            let width = CGFloat(bytes) / CGFloat(total) * self.bounds.width
            color.setFill()
            UIBezierPath(rect: CGRect(x: x, y: 0, width: max(0, width - min(2, width * 0.1)), height: self.bounds.height)).fill()
            x += width
        }
    }
}
private final class CodeGramStorageSummaryCell: CodeGramSurfaceCell {
    init(total: Int64, categories: [(String, Int64, UIColor)]) {
        super.init(style: .default, reuseIdentifier: nil)
        self.selectionStyle = .none
        let value = UILabel(); value.text = codegramBytes(total); value.font = .systemFont(ofSize: 36, weight: .bold); value.adjustsFontSizeToFitWidth = true
        let caption = UILabel(); caption.text = "занимает архив на VPS"; caption.font = .systemFont(ofSize: 14); caption.textColor = .secondaryLabel
        let bar = CodeGramStorageBar(segments: categories)
        let stack = UIStackView(arrangedSubviews: [value, caption, bar]); stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        self.bodyView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: self.bodyView.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: self.bodyView.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: self.bodyView.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: self.bodyView.bottomAnchor, constant: -24), bar.heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class CodeGramStorageController: CodeGramTableController {
    private var payload: [String: Any]?
    private var local: DeletedMessageArchiveStats?
    private var message = "Загрузка…"
    private let disposable = MetaDisposable()
    private let labels: [String: String] = ["photos": "Фото", "videos": "Видео", "voice": "Голосовые", "round_video": "Кружочки", "stickers": "Стикеры", "animations": "GIF", "audio": "Музыка", "files": "Файлы", "thumbnails": "Миниатюры"]
    init(context: AccountContext) { super.init(context: context, title: "Память архива"); self.refresh() }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.disposable.dispose() }
    private func refresh() {
        self.disposable.set((self.context.engine.messages.deletedMessageArchiveStats() |> deliverOnMainQueue).start(next: { [weak self] value in self?.local = value; self?.reloadContent() }))
        CodeGramArchiveAPI.request(account: self.accountKey, path: "storage") { [weak self] result in
            guard let self else { return }
            switch result { case let .success(payload): self.payload = payload; self.message = "Обновлено сейчас. Объём VPS и iPhone показан раздельно."; case let .failure(error): self.message = error.localizedDescription }
            self.reloadContent()
        }
    }
    private func count(_ key: String) -> Int64 { (self.payload?[key] as? NSNumber)?.int64Value ?? 0 }
    override func makeSections() -> [CodeGramSettingsSection] {
        var result: [CodeGramSettingsSection] = []
        if let payload = self.payload {
            let colors: [UIColor] = [.systemBlue, .systemPurple, .systemGreen, .systemOrange, .systemPink, .systemTeal, .systemIndigo, .systemYellow, .systemGray]
            let categories = (payload["categories"] as? [[String: Any]] ?? []).enumerated().map { index, row -> (String, Int64, UIColor) in
                return (self.labels[row["category"] as? String ?? ""] ?? "Файлы", (row["bytes"] as? NSNumber)?.int64Value ?? 0, colors[index % colors.count])
            }
            let symbols = ["photos": "photo", "videos": "video", "voice": "waveform", "round_video": "video.circle", "stickers": "face.smiling", "animations": "play.rectangle", "audio": "music.note", "files": "doc", "thumbnails": "photo.on.rectangle"]
            var categoryRows = (payload["categories"] as? [[String: Any]] ?? []).map { row in
                let key = row["category"] as? String ?? "files"
                return self.textRow(self.labels[key] ?? "Файлы", detail: codegramBytes((row["bytes"] as? NSNumber)?.int64Value ?? 0), icon: symbols[key] ?? "doc")
            }
            var segments = categories
            if self.count("database_bytes") > 0 {
                segments.append(("База и журнал", self.count("database_bytes"), .systemGray2))
                categoryRows.append(self.textRow("База и журнал", detail: codegramBytes(self.count("database_bytes")), icon: "externaldrive.badge.person.crop"))
            }
            if self.count("partial_bytes") > 0 {
                segments.append(("В процессе загрузки", self.count("partial_bytes"), .systemGray3))
                categoryRows.append(self.textRow("В процессе загрузки", detail: codegramBytes(self.count("partial_bytes")), icon: "arrow.down.circle.dotted"))
            }
            let totalBytes = self.count("total_bytes")
            result.append(CodeGramSettingsSection(title: "VPS · фоновое сохранение", footer: "Размер готовых файлов считается один раз, даже если файл встречался в нескольких сообщениях. Удалённые вложения — часть общего объёма.", rows: [CodeGramSettingsRow(cell: { CodeGramStorageSummaryCell(total: totalBytes, categories: segments) })] + categoryRows))
            result.append(CodeGramSettingsSection(title: "Статистика VPS", footer: "Резерв — свободное место, которое служба старается оставить на диске. При нехватке места очередь ждёт; готовые файлы автоматически не удаляются.", rows: [
                self.textRow("Вложения удалённых сообщений", detail: codegramBytes(self.count("deleted_bytes")), icon: "paperclip"),
                self.textRow("Удалённые сообщения", detail: String(self.count("deleted_messages")), icon: "trash"),
                self.textRow("Записи в журнале", detail: String(self.count("revision_count")), icon: "list.bullet.rectangle"),
                self.textRow("Готовые файлы", detail: String(self.count("ready")), icon: "checkmark.seal"),
                self.textRow("В очереди / на паузе по правилам", detail: "\(self.count("pending")) / \(self.count("paused_by_policy"))", icon: "pause.circle"),
                self.textRow("Не удалось загрузить", detail: String(self.count("failed")), icon: "exclamationmark.arrow.triangle.2.circlepath"),
                self.textRow("Свободно на VPS", detail: codegramBytes(self.count("free_bytes")), icon: "externaldrive"),
                self.textRow("Резерв свободного места", detail: codegramBytes(self.count("reserved_bytes")), icon: "lock.shield") ]))
        }
        if let local {
            result.append(CodeGramSettingsSection(title: "На этом iPhone", footer: "Загруженные на iPhone файлы локального архива. Полный кэш приложения управляется в обычном разделе Telegram «Данные и память → Использование памяти».", rows: [self.textRow("Медиа локального архива", detail: codegramBytes(local.mediaSize), icon: "internaldrive"), self.textRow("Удалённые / версии", detail: "\(local.messageCount) / \(local.versionCount)", icon: "clock.arrow.circlepath")]))
        }
        result.append(CodeGramSettingsSection(title: nil, footer: self.message, rows: [self.textRow("Обновить статистику", icon: "arrow.clockwise", action: { [weak self] in self?.refresh() })]))
        return result
    }
}



