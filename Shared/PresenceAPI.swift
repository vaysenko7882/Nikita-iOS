import Foundation

enum PresenceError: LocalizedError {
    case http(Int)
    case rateLimited
    case decoding
    case transport

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Сайт временно недоступен (HTTP \(code))."
        case .rateLimited: return "Сервер попросил паузу. Повторим запрос позже."
        case .decoding: return "Сайт вернул неподдерживаемый ответ."
        case .transport: return "Нет связи с сервером. Проверь интернет и доступность autismex.best."
        }
    }
}

/// Клиент того же API, что и у сайта: /api/state, /api/events, /api/diagnostics,
/// /api/export.csv, /api/avatar. Адрес сервера меняется в одном месте — defaultBase.
struct PresenceAPI {
    static let defaultBase = URL(string: "https://autismex.best")!

    var base: URL = PresenceAPI.defaultBase

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func request(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 12) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        let url = components?.url ?? base.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw PresenceError.transport
        }
        if let http = result.1 as? HTTPURLResponse {
            if http.statusCode == 429 { throw PresenceError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw PresenceError.http(http.statusCode) }
        }
        return result.0
    }

    func state(date: String?) async throws -> PresenceState {
        var query: [URLQueryItem] = []
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        let data = try await load(request("api/state", query: query))
        do {
            return try PresenceAPI.decoder.decode(PresenceState.self, from: data)
        } catch {
            throw PresenceError.decoding
        }
    }

    func diagnostics() async throws -> String {
        let data = try await load(request("api/diagnostics"))
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    func exportCSV() async throws -> URL {
        var csvRequest = request("api/export.csv", timeout: 30)
        csvRequest.setValue("text/csv", forHTTPHeaderField: "Accept")
        let data = try await load(csvRequest)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autismex-history.csv")
        try data.write(to: url, options: .atomic)
        return url
    }

    func eventsRequest() -> URLRequest {
        var events = request("api/events", timeout: 3_600)
        events.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return events
    }

    func avatarURL(version: String?) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("api/avatar"), resolvingAgainstBaseURL: false)
        if let version { components?.queryItems = [URLQueryItem(name: "v", value: version)] }
        return components?.url ?? base.appendingPathComponent("api/avatar")
    }
}
