import Combine
import Foundation

@MainActor
final class PresenceModel: ObservableObject {
    @Published var snapshot: PresenceSnapshot?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var selectedDate = Date()
    @Published var lastSuccess: Date?

    let baseURL = URL(string: "https://autismex.best")!
    private var inFlight = false
    private var retryDelay: TimeInterval = 1
    private let session: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 8
        settings.timeoutIntervalForResource = 10
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: settings)
    }()

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func refresh() async {
        guard !inFlight, !Task.isCancelled else { return }
        inFlight = true
        isLoading = snapshot == nil
        defer { inFlight = false; isLoading = false }
        let requestedDate = dateString(selectedDate)
        var components = URLComponents(url: baseURL.appendingPathComponent("api/state"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "date", value: requestedDate)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw FetchError.response }
            if http.statusCode == 429 {
                retryDelay = min(300, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "10") ?? 10))
                throw FetchError.limited
            }
            guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
            guard data.count < 5_000_000 else { throw FetchError.response }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let value = try decoder.decode(PresenceSnapshot.self, from: data)
            guard value.profile.id == 6103235693 else { throw FetchError.account }
            guard requestedDate == dateString(selectedDate) else { return }
            snapshot = value
            lastSuccess = Date()
            errorMessage = nil
            retryDelay = 1
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = (error as? FetchError)?.message ?? "Не удалось получить статистику. Проверь соединение с сайтом."
        }
    }

    func run() async {
        while !Task.isCancelled {
            let started = Date()
            await refresh()
            let delay = max(0.05, retryDelay - Date().timeIntervalSince(started))
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    func changeDay(_ offset: Int) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        guard let date = calendar.date(byAdding: .day, value: offset, to: selectedDate), date <= Date() else { return }
        selectedDate = date
        await refresh()
    }

    func selectToday() async { selectedDate = Date(); await refresh() }

    func selectDate(_ value: String) async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: value+" 12:00"), value <= dateString(Date()) else { return }
        selectedDate = value == dateString(Date()) ? Date() : date
        await refresh()
    }

    func serverNow(at date: Date) -> Double {
        guard let snapshot else { return date.timeIntervalSince1970 }
        return snapshot.now + max(0, date.timeIntervalSince(lastSuccess ?? date))
    }

    func sourceFresh(at date: Date) -> Bool {
        guard let lastSuccess else { return false }
        return date.timeIntervalSince(lastSuccess) < 6
    }

    func displayState(at date: Date) -> String {
        guard let value = snapshot, sourceFresh(at: date), value.health.selfSession != true,
              value.health.mode != "session_mismatch" else { return "unknown" }
        if let until = value.current.validUntil, serverNow(at: date) >= until { return "unknown" }
        return ["online", "offline"].contains(value.current.state) ? value.current.state : "unknown"
    }

    func elapsedStatus(at date: Date) -> Double {
        guard let value = snapshot else { return 0 }
        let state = displayState(at: date)
        guard state != "unknown" else { return 0 }
        let since = state == "offline" ? (value.current.pauseSince ?? value.current.since) : value.current.since
        return max(0, serverNow(at: date) - since)
    }

    private enum FetchError: Error {
        case response, http(Int), limited, account
        var message: String {
            switch self {
            case .response: return "Сайт вернул неподдерживаемый ответ."
            case .http(let status): return "Сайт временно недоступен (HTTP \(status))."
            case .limited: return "Сервер попросил паузу. Повторим запрос позже."
            case .account: return "Сервер вернул другой аккаунт. Проверь настройки проекта."
            }
        }
    }
}
