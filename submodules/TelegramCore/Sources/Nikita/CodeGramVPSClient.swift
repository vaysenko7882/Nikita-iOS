import Foundation

public struct CodeGramVPSError: LocalizedError {
    public let message: String
    public var errorDescription: String? { self.message }
    public init(_ message: String) { self.message = message }

    /// Translate only known diagnostic codes. Never show an extractor's raw
    /// output, which can contain private URLs or other request details.
    public static func socialVideoFailure(code: String?) -> CodeGramVPSError {
        return self.knownSocialVideoFailure(code: code) ?? CodeGramVPSError("VPS не смог подготовить видео. Проверь состояние службы и версию сервера.")
    }
    private static func knownSocialVideoFailure(code: String?) -> CodeGramVPSError? {
        let message: String
        switch code {
        case "video_source_unavailable": message = "Источник не отдал публичное видео: ролик может быть удалён или недоступен с IP VPS."
        case "video_login_required": message = "Источник требует входа в аккаунт. Сервер поддерживает публичные ролики без авторизации."
        case "video_rate_limited": message = "TikTok или Instagram ограничил запросы с IP VPS. Повтори позже."
        case "video_network_error": message = "VPS не смог подключиться к источнику видео. Проверь сеть и доступность сайта с сервера."
        case "video_timeout": message = "Сервер превысил время подготовки видео. Повтори запрос позже."
        case "video_too_large": message = "Видео превышает предел 250 МБ."
        case "video_unsupported_codec": message = "Источник не предоставил видео в поддерживаемом формате H.264."
        case "video_processing_failed": message = "VPS получил видео, но не смог подготовить MP4. Проверь журнал службы и ffmpeg на сервере."
        case "video_dependency_missing": message = "На VPS не хватает компонентов обработки видео. Повтори установку серверной службы из актуальной ветки."
        case "insufficient_storage": message = "На VPS не хватает свободного места для видео."
        case "video_unavailable": message = "Сервер не смог получить или подготовить видео. Обнови серверную службу и повтори запрос."
        default: return nil
        }
        return CodeGramVPSError(message)
    }
    static func response(statusCode: Int, serverCode: String?) -> CodeGramVPSError {
        // Authentication failures retain their meaning even with a malformed body.
        if statusCode == 401 { return CodeGramVPSError("VPS отклонил ключ доступа.") }
        if statusCode == 403 { return CodeGramVPSError("На VPS подключён другой Telegram-аккаунт.") }
        if let error = self.knownSocialVideoFailure(code: serverCode) { return error }
        switch statusCode {
        case 400: return CodeGramVPSError("Сервер отклонил параметры. Проверь ссылку или доступность профиля.")
        case 404: return CodeGramVPSError("Функция или файл не найдены на VPS. Проверь версию серверной службы и повтори запрос.")
        case 409: return CodeGramVPSError("Состояние сервера изменилось. Повтори запрос.")
        case 429: return CodeGramVPSError("Очередь или лимит запросов VPS исчерпаны. Попробуй немного позже.")
        case 507: return CodeGramVPSError("На VPS не хватает свободного места для видео.")
        default: return CodeGramVPSError("Ошибка VPS (HTTP \(statusCode)).")
        }
    }
    static func connection(_ error: Error?, downloading: Bool = false) -> CodeGramVPSError {
        switch (error as? URLError)?.code {
        case .timedOut: return CodeGramVPSError(downloading ? "Истекло время загрузки видео с VPS на iPhone." : "VPS не ответил вовремя. Проверь состояние серверной службы.")
        case .cancelled: return CodeGramVPSError("Запрос отменён.")
        case .notConnectedToInternet: return CodeGramVPSError("На iPhone нет подключения к интернету.")
        default: return CodeGramVPSError(downloading ? "Не удалось загрузить файл с VPS на iPhone. Проверь соединение." : "Нет соединения с VPS. Проверь адрес, HTTPS и состояние службы.")
        }
    }
}

/// Each operation is tied to one saved account/configuration. Redirects never
/// forward archive credentials, and downloads stream to disk rather than Data.
public final class CodeGramVPSClient: NSObject, URLSessionTaskDelegate {
    private let configuration: NikitaServerConfiguration
    private let accountId: String
    private lazy var session: URLSession = {
        let value = URLSessionConfiguration.ephemeral
        value.httpShouldSetCookies = false
        value.httpCookieStorage = nil
        value.urlCache = nil
        value.timeoutIntervalForRequest = 25
        value.timeoutIntervalForResource = 600
        return URLSession(configuration: value, delegate: self, delegateQueue: nil)
    }()
    public init(configuration: NikitaServerConfiguration, accountId: String) {
        self.configuration = configuration; self.accountId = accountId
        super.init()
    }
    public func close() { self.session.invalidateAndCancel() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    private func request(path: String, query: [String: String], method: String, body: [String: Any]?) -> URLRequest? {
        guard self.configuration.enabled, self.configuration.hasValidToken,
            let base = self.configuration.baseURL, !path.hasPrefix("/"), !path.contains(".."), !path.contains("://"),
            var components = URLComponents(url: base.appendingPathComponent("v1").appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("Bearer \(self.configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue(self.accountId, forHTTPHeaderField: "X-CodeGram-Account-ID")
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    private static func error(_ code: Int, data: Data? = nil) -> CodeGramVPSError {
        var serverCode: String?
        if let data, data.count <= 4096, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            serverCode = body["error"] as? String
        }
        return CodeGramVPSError.response(statusCode: code, serverCode: serverCode)
    }
    @discardableResult public func json(path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil, completion: @escaping (Result<[String: Any], CodeGramVPSError>) -> Void) -> URLSessionDataTask? {
        func done(_ result: Result<[String: Any], CodeGramVPSError>) { DispatchQueue.main.async { completion(result) } }
        guard let request = self.request(path: path, query: query, method: method, body: body) else {
            done(.failure(CodeGramVPSError("Сначала включи и сохрани HTTPS-подключение к VPS в настройках CodeGram."))); return nil
        }
        let task = self.session.dataTask(with: request) { [accountId = self.accountId] data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse else { done(.failure(CodeGramVPSError.connection(error))); return }
            guard response.statusCode == 200 else { done(.failure(Self.error(response.statusCode, data: data))); return }
            guard let data, data.count <= 4 * 1024 * 1024,
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let account = object["account_id"] as? NSNumber, account.stringValue == accountId,
                let epoch = object["server_id"] as? String, !epoch.isEmpty,
                (object["server_version"] as? Int ?? 0) >= 5 else { done(.failure(CodeGramVPSError("Ответ VPS не подходит этому аккаунту или версии клиента."))); return }
            done(.success(object))
        }
        task.resume()
        return task
    }
    @discardableResult public func download(path: String, epoch: String, size: Int64, destination: URL, completion: @escaping (Result<URL, CodeGramVPSError>) -> Void) -> URLSessionDownloadTask? {
        func done(_ result: Result<URL, CodeGramVPSError>) { DispatchQueue.main.async { completion(result) } }
        guard size > 0, size <= 8 * 1024 * 1024 * 1024,
            var request = self.request(path: path, query: [:], method: "GET", body: nil) else { done(.failure(CodeGramVPSError("Некорректный файл или подключение VPS."))); return nil }
        request.setValue(epoch, forHTTPHeaderField: "X-Nikita-Archive-Epoch")
        request.timeoutInterval = 60
        let task = self.session.downloadTask(with: request) { temporary, response, error in
            guard error == nil, let temporary, let response = response as? HTTPURLResponse else { done(.failure(CodeGramVPSError.connection(error, downloading: true))); return }
            guard response.statusCode == 200 else {
                let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let data = size <= 4096 ? (try? Data(contentsOf: temporary)) : nil
                done(.failure(Self.error(response.statusCode, data: data))); return
            }
            guard response.value(forHTTPHeaderField: "X-Nikita-Archive-Epoch") == epoch,
                let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path),
                (attributes[.size] as? NSNumber)?.int64Value == size else { done(.failure(CodeGramVPSError("Файл получен не полностью или архив изменился."))); return }
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                done(.success(destination))
            } catch { done(.failure(CodeGramVPSError("Не удалось сохранить временный файл на iPhone."))) }
        }
        task.resume()
        return task
    }
}

