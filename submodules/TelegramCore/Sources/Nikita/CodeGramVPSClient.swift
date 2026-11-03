import Foundation

public struct CodeGramVPSError: LocalizedError {
    public let message: String
    public var errorDescription: String? { self.message }
    public init(_ message: String) { self.message = message }
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
        value.timeoutIntervalForResource = 240
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
    private static func error(_ code: Int) -> CodeGramVPSError {
        switch code {
        case 400: return CodeGramVPSError("Сервер отклонил параметры. Проверь ссылку или доступность профиля.")
        case 401: return CodeGramVPSError("VPS отклонил ключ доступа.")
        case 403: return CodeGramVPSError("На VPS подключён другой Telegram-аккаунт.")
        case 404: return CodeGramVPSError("Обнови службу VPS до версии 5 для этой функции.")
        case 409: return CodeGramVPSError("Состояние сервера изменилось. Повтори запрос.")
        case 429: return CodeGramVPSError("Очередь видео занята. Попробуй немного позже.")
        case 507: return CodeGramVPSError("На VPS не хватает свободного места для видео.")
        default: return CodeGramVPSError("Ошибка VPS (HTTP \(code)).")
        }
    }
    @discardableResult public func json(path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil, completion: @escaping (Result<[String: Any], CodeGramVPSError>) -> Void) -> URLSessionDataTask? {
        func done(_ result: Result<[String: Any], CodeGramVPSError>) { DispatchQueue.main.async { completion(result) } }
        guard let request = self.request(path: path, query: query, method: method, body: body) else {
            done(.failure(CodeGramVPSError("Сначала включи и сохрани HTTPS-подключение к VPS в настройках CodeGram."))); return nil
        }
        let task = self.session.dataTask(with: request) { [accountId = self.accountId] data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse else { done(.failure(CodeGramVPSError("Нет соединения с VPS или запрос отменён."))); return }
            guard response.statusCode == 200 else { done(.failure(Self.error(response.statusCode))); return }
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
        let task = self.session.downloadTask(with: request) { temporary, response, error in
            guard error == nil, let temporary, let response = response as? HTTPURLResponse else { done(.failure(CodeGramVPSError("Загрузка файла прервана."))); return }
            guard response.statusCode == 200 else { done(.failure(Self.error(response.statusCode))); return }
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
