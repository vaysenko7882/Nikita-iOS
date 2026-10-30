import Foundation
import Postbox
import SwiftSignalKit

struct NikitaRemoteArchiveState: Codable {
    var endpoint: String = ""
    var serverId: String = ""
    var cursor: Int64 = 0
    var pendingVersions: [String: [DeletedMessageArchiveIndexEntry]] = [:]
}

struct NikitaRemoteArchiveEvent: Decodable {
    let seq: Int64
    let peerType: String
    let peerId: Int64
    let messageId: Int32
    let authorType: String?
    let authorId: Int64?
    let outgoing: Bool
    let date: Int32
    let capturedAt: Int32
    let threadId: Int64?
    let text: String
    let mediaTitle: String
    let mediaId: Int64?
    let kind: String

    enum CodingKeys: String, CodingKey {
        case seq, outgoing, date, text, kind
        case peerType = "peer_type", peerId = "peer_id", messageId = "message_id"
        case authorType = "author_type", authorId = "author_id", capturedAt = "captured_at"
        case threadId = "thread_id", mediaTitle = "media_title"
        case mediaId = "media_id"
    }

    static func peer(type: String, id: Int64) -> PeerId? {
        guard id > 0 else { return nil }
        let namespace: PeerId.Namespace
        switch type {
        case "user": namespace = Namespaces.Peer.CloudUser
        case "chat": namespace = Namespaces.Peer.CloudGroup
        case "channel": namespace = Namespaces.Peer.CloudChannel
        default: return nil
        }
        return PeerId(namespace: namespace, id: PeerId.Id._internalFromInt64Value(id))
    }

    var originalId: MessageId? {
        guard self.messageId > 0, let peerId = Self.peer(type: self.peerType, id: self.peerId) else {
            return nil
        }
        return MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: self.messageId)
    }

    var resolvedAuthorId: PeerId? {
        guard let type = self.authorType, let id = self.authorId else { return nil }
        return Self.peer(type: type, id: id)
    }

    var displayText: String {
        if self.mediaTitle.isEmpty { return self.text }
        // Binary media is intentionally not exposed by this read-only API.
        return self.text.isEmpty ? "[\(self.mediaTitle)]" : "\(self.text)\n[\(self.mediaTitle)]"
    }
}

struct NikitaRemoteArchivePage: Decodable {
    let protocolVersion: Int
    let serverId: String
    let accountId: Int64
    let resetRequired: Bool
    let nextCursor: Int64
    let hasMore: Bool
    let events: [NikitaRemoteArchiveEvent]
    let connected: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", serverId = "server_id", accountId = "account_id"
        case resetRequired = "reset_required", nextCursor = "next_cursor", hasMore = "has_more"
        case events, connected
    }
}

public struct NikitaArchiveSyncResult {
    public let success: Bool
    public let importedCount: Int
    public let hasMore: Bool
    public let connected: Bool
    public let message: String

    static func failure(_ message: String) -> NikitaArchiveSyncResult {
        return NikitaArchiveSyncResult(success: false, importedCount: 0, hasMore: false, connected: false, message: message)
    }
}

// A redirect must not forward the private bearer token to a different host.
private final class NikitaArchiveSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum NikitaArchiveRequestResult {
    case page(NikitaRemoteArchivePage)
    case failure(String)
}

private func requestNikitaArchive(configuration: NikitaServerConfiguration, state: NikitaRemoteArchiveState) -> Signal<NikitaArchiveRequestResult, NoError> {
    return Signal { subscriber in
        guard let baseURL = configuration.baseURL, configuration.hasValidToken,
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/sync"), resolvingAgainstBaseURL: false) else {
            subscriber.putNext(.failure("Укажи HTTPS-адрес VPS и ключ доступа."))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        components.queryItems = [URLQueryItem(name: "after", value: String(state.cursor)),
            URLQueryItem(name: "server_id", value: state.serverId), URLQueryItem(name: "limit", value: "100")]
        guard let url = components.url else {
            subscriber.putNext(.failure("Некорректный адрес VPS."))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        let session = URLSession(configuration: sessionConfiguration, delegate: NikitaArchiveSessionDelegate(), delegateQueue: nil)
        let task = session.dataTask(with: request) { data, response, error in
            defer {
                subscriber.putCompletion()
                session.finishTasksAndInvalidate()
            }
            guard error == nil, let response = response as? HTTPURLResponse else {
                subscriber.putNext(.failure("Нет соединения с VPS. Проверь адрес и HTTPS-сертификат."))
                return
            }
            guard response.statusCode == 200 else {
                subscriber.putNext(.failure(response.statusCode == 401 ? "VPS отклонил ключ доступа." : "VPS вернул ошибку \(response.statusCode)."))
                return
            }
            guard let data, data.count <= 8 * 1024 * 1024,
                let page = try? JSONDecoder().decode(NikitaRemoteArchivePage.self, from: data),
                page.protocolVersion == 1, page.events.count <= 200,
                !page.serverId.isEmpty, page.serverId.count <= 128,
                page.events.allSatisfy({ $0.text.utf8.count <= 65536 && $0.mediaTitle.utf8.count <= 2048 && ($0.kind == "edit" || $0.kind == "delete") && $0.originalId != nil }) else {
                subscriber.putNext(.failure("Ответ VPS не соответствует протоколу Никита."))
                return
            }
            subscriber.putNext(.page(page))
        }
        task.resume()
        return ActionDisposable {
            task.cancel()
            session.invalidateAndCancel()
        }
    }
}

public extension TelegramEngine.Messages {
    func synchronizeNikitaArchive() -> Signal<NikitaArchiveSyncResult, NoError> {
        let account = self.account
        let accountKey = String(account.peerId.id._internalGetInt64Value())
        let configuration = NikitaSettingsStore.shared.server(account: accountKey)
        guard configuration.enabled, let endpoint = configuration.baseURL?.absoluteString else {
            return .single(.failure("Сначала включи интеграцию с VPS и сохрани настройки."))
        }
        return account.postbox.transaction { transaction -> NikitaRemoteArchiveState in
            var state = transaction.getPreferencesEntry(key: PreferencesKeys.nikitaServerArchive)?.get(NikitaRemoteArchiveState.self) ?? NikitaRemoteArchiveState()
            if state.endpoint != endpoint {
                state.endpoint = endpoint
                state.serverId = ""
                state.cursor = 0
                transaction.updatePreferencesEntry(key: PreferencesKeys.nikitaServerArchive, { _ in PreferencesEntry(state) })
            }
            return state
        }
        |> mapToSignal { state -> Signal<NikitaArchiveSyncResult, NoError> in
            return requestNikitaArchive(configuration: configuration, state: state)
            |> mapToSignal { result -> Signal<NikitaArchiveSyncResult, NoError> in
                switch result {
                case let .failure(message): return .single(.failure(message))
                case let .page(page):
                    guard page.accountId == account.peerId.id._internalGetInt64Value() else {
                        return .single(.failure("На VPS подключён другой Telegram-аккаунт. Импорт остановлен."))
                    }
                    return account.postbox.transaction { transaction -> NikitaArchiveSyncResult in
                        guard NikitaSettingsStore.shared.server(account: accountKey) == configuration else {
                            return .failure("Настройки изменились. Повтори синхронизацию.")
                        }
                        var current = transaction.getPreferencesEntry(key: PreferencesKeys.nikitaServerArchive)?.get(NikitaRemoteArchiveState.self) ?? NikitaRemoteArchiveState()
                        guard current.endpoint == endpoint else { return .failure("Адрес VPS изменился.") }
                        if page.resetRequired || (!current.serverId.isEmpty && current.serverId != page.serverId) {
                            current.serverId = page.serverId
                            current.cursor = 0
                            transaction.updatePreferencesEntry(key: PreferencesKeys.nikitaServerArchive, { _ in PreferencesEntry(current) })
                            return NikitaArchiveSyncResult(success: true, importedCount: 0, hasMore: true, connected: page.connected, message: "Архив сервера изменился. Перечитываю журнал…")
                        }
                        var lastSequence = state.cursor
                        for event in page.events {
                            guard event.seq > lastSequence else { return .failure("Нарушен порядок журнала VPS.") }
                            lastSequence = event.seq
                        }
                        guard page.nextCursor == lastSequence else { return .failure("Некорректная позиция журнала VPS.") }
                        guard page.nextCursor >= current.cursor else {
                            // Another sync may already have committed the same page.
                            return NikitaArchiveSyncResult(success: true, importedCount: 0, hasMore: false, connected: page.connected, message: "Архив уже синхронизирован.")
                        }
                        let count = importNikitaArchiveEvents(transaction: transaction, mediaBox: account.postbox.mediaBox,
                            events: page.events.filter { $0.seq > current.cursor }, state: &current)
                        current.serverId = page.serverId
                        current.cursor = page.nextCursor
                        transaction.updatePreferencesEntry(key: PreferencesKeys.nikitaServerArchive, { _ in PreferencesEntry(current) })
                        return NikitaArchiveSyncResult(success: true, importedCount: count, hasMore: page.hasMore, connected: page.connected,
                            message: page.connected ? "Архив синхронизирован. Сервер подключён к Telegram." : "Архив получен, но сессия Telegram на VPS сейчас отключена.")
                    }
                }
            }
        }
    }
}
