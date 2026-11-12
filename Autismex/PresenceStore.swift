import Foundation
import SwiftUI
import WidgetKit

enum ChronicleFilter: String, CaseIterable, Identifiable {
    case all, online, offline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .online: return "В сети"
        case .offline: return "Паузы"
        }
    }
}

/// Показатели дня, которые растут каждую секунду между ответами сервера.
struct LiveMetrics {
    var online = 0.0
    var offline = 0.0
    var unknown = 0.0
    var sessions = 0.0
    var pauses = 0.0
    var maxSession = 0.0
    var maxPause = 0.0
    var averageSession = 0.0
    var coverage = 0.0
    var observedMaxPause = 0.0
    var maxPauseSource = "observed"

    init() {}

    init(_ metrics: Metrics?) {
        guard let metrics else { return }
        online = metrics.onlineSeconds ?? 0
        offline = metrics.offlineSeconds ?? 0
        unknown = metrics.unknownSeconds ?? 0
        sessions = metrics.sessionCount ?? 0
        pauses = metrics.pauseCount ?? 0
        maxSession = metrics.maxSessionSeconds ?? 0
        maxPause = metrics.maxPauseSeconds ?? 0
        averageSession = metrics.averageSessionSeconds ?? 0
        coverage = metrics.coveragePercent ?? 0
        observedMaxPause = metrics.observedMaxPauseSeconds ?? metrics.maxPauseSeconds ?? 0
        maxPauseSource = metrics.maxPauseSource ?? "observed"
    }
}

@MainActor
final class PresenceStore: ObservableObject {
    @Published private(set) var state: PresenceState?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var streamOpen = false
    @Published private(set) var lastSuccess: Date?

    let api = PresenceAPI()

    private(set) var fetchedAt = Date.distantPast
    private var followToday = true
    private var requestedDate: String?
    private var requestNumber = 0
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var widgetKey: String?

    // MARK: Жизненный цикл

    func start() {
        if streamTask == nil { startStream() }
        if pollTask == nil { startPolling() }
        Task { await refresh() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        streamOpen = false
    }

    func refresh() async {
        requestNumber += 1
        let number = requestNumber
        isLoading = true
        do {
            let next = try await api.state(date: followToday ? nil : requestedDate)
            guard number == requestNumber else { return }
            state = next
            fetchedAt = Date()
            lastSuccess = fetchedAt
            errorMessage = nil
            if next.isToday {
                followToday = true
                requestedDate = nil
            }
            reloadWidgetsIfNeeded(next)
        } catch {
            guard number == requestNumber else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Не удалось получить статистику. Проверь соединение с сайтом."
        }
        if number == requestNumber { isLoading = false }
    }

    func pick(_ day: String) {
        guard let state, day <= state.today else { return }
        if day == state.today {
            followToday = true
            requestedDate = nil
        } else {
            followToday = false
            requestedDate = day
        }
        Task { await refresh() }
    }

    func move(by days: Int) {
        guard let state else { return }
        pick(Fmt.shiftDay(state.date, days))
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Поток событий сервера (SSE). Каждое событие — повод перечитать состояние.
    private func startStream() {
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let request = self?.api.eventsRequest() else { return }
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        self?.streamOpen = true
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            if line.hasPrefix("event:") || line.hasPrefix("data:") {
                                self?.scheduleRefresh()
                            }
                        }
                    }
                } catch {
                    // Переподключимся ниже.
                }
                self?.streamOpen = false
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Запасной опрос: если поток молчит, данные устарели или наступил новый день.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let age = Date().timeIntervalSince(self.lastSuccess ?? .distantPast)
                var rolledOver = false
                if self.followToday, let state = self.state {
                    rolledOver = Fmt.isoDay(self.serverNow(), tz: state.tz) != state.today
                }
                if (!self.streamOpen && age > 5) || age > 60 || rolledOver {
                    await self.refresh()
                }
            }
        }
    }

    private func reloadWidgetsIfNeeded(_ state: PresenceState) {
        guard state.isToday else { return }
        let key = (state.current.state ?? "") + "|" + String(Int(state.current.since ?? 0))
        if key != widgetKey {
            widgetKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Живые значения (как liveMetrics и currentState на сайте)

    func serverNow(at date: Date = Date()) -> Double {
        guard let state else { return date.timeIntervalSince1970 }
        return state.now + date.timeIntervalSince(fetchedAt)
    }

    func isConnected(at date: Date) -> Bool {
        if streamOpen { return true }
        guard let lastSuccess else { return false }
        return date.timeIntervalSince(lastSuccess) < 12
    }

    func liveState(at date: Date) -> String {
        guard let state, isConnected(at: date), state.health?.selfSession != true else { return "unknown" }
        if let validUntil = state.current.validUntil, serverNow(at: date) >= validUntil { return "unknown" }
        return state.current.state ?? "unknown"
    }

    func liveMetrics(at date: Date) -> (day: LiveMetrics, total: LiveMetrics) {
        guard let state else { return (LiveMetrics(), LiveMetrics()) }
        var day = LiveMetrics(state.day)
        var total = LiveMetrics(state.total)
        guard isConnected(at: date) else { return (day, total) }

        let rawDelta = max(0, date.timeIntervalSince(fetchedAt))
        let now = state.now + rawDelta
        let delta: Double
        if let validUntil = state.current.validUntil {
            delta = max(0, min(now, validUntil) - state.now)
        } else {
            delta = rawDelta
        }
        let current = state.health?.selfSession == true ? "unknown" : (state.current.state ?? "unknown")
        let dayStart = state.dayStart
        let dayEnd = state.dayEnd
        let since = state.current.since ?? state.now

        func extend(_ value: inout LiveMetrics, isDay: Bool) {
            let frozen = isDay && !state.isToday
            let activeDelta = frozen ? 0 : delta
            let actualDelta = frozen ? 0 : rawDelta
            if current == "online" { value.online += activeDelta }
            if current == "offline" { value.offline += activeDelta }
            let known = current == "unknown" ? 0 : activeDelta
            value.unknown += max(0, actualDelta - known)
            let span = value.online + value.offline + value.unknown
            value.coverage = span > 0 ? (value.online + value.offline) / span * 100 : 0
            let cap = isDay ? dayEnd : Double.infinity
            let start = isDay ? max(dayStart, since) : since
            let duration = max(0, min(state.now + delta, cap) - start)
            if actualDelta > 0 && current == "offline" {
                value.observedMaxPause = max(value.observedMaxPause, duration)
                let reportedSince = state.current.pauseSince ?? since
                let pauseStart = isDay ? max(dayStart, reportedSince) : reportedSince
                let reported = max(0, min(state.now + delta, cap) - pauseStart)
                value.maxPause = max(value.maxPause, reported, duration)
                if value.maxPause > value.observedMaxPause { value.maxPauseSource = "telegram_last_seen" }
            }
            if actualDelta > 0 && current == "online" {
                value.maxSession = max(value.maxSession, duration)
            }
            value.averageSession = value.sessions > 0 ? value.online / value.sessions : 0
        }

        extend(&day, isDay: true)
        extend(&total, isDay: false)
        return (day, total)
    }

    func statusLine(at date: Date) -> String {
        guard let state else { return "Ждём данные Telegram" }
        let live = liveState(at: date)
        let now = serverNow(at: date)
        let current = state.current
        switch live {
        case "unknown":
            if !isConnected(at: date) { return "Показаны последние полученные данные" }
            if state.health?.selfSession == true { return "Подключи другой свой аккаунт в терминале VPS" }
            if let raw = current.state, raw != "unknown" { return "Статус устарел, ждём подтверждение" }
            return current.reason ?? "Ждём точный статус"
        case "offline":
            let start = current.pauseSince ?? current.since ?? now
            let startDay = Fmt.isoDay(start, tz: state.tz)
            let prefix = startDay == state.today ? "" : Fmt.dayText(startDay, "d MMM") + " "
            return "с " + prefix + Fmt.time(start, tz: state.tz) + " · пауза " + Fmt.duration(now - start, detailed: true)
        default:
            return "онлайн " + Fmt.duration(now - (current.since ?? now), detailed: true)
        }
    }

    func pauseNote(at date: Date) -> String? {
        guard let state, liveState(at: date) == "offline", state.current.pauseSource == "telegram_last_seen" else { return nil }
        let observed = serverNow(at: date) - (state.current.since ?? state.now)
        return "Начало — Last Seen Telegram. Непрерывно наблюдаем " + Fmt.duration(observed, detailed: true) + "."
    }

    /// Конец отрезка с учётом того, что текущий растёт прямо сейчас.
    func liveEnd(_ row: Interval, at date: Date = Date()) -> Double {
        guard let state, row.isOngoing, state.isToday else { return row.end }
        let cap = min(serverNow(at: date), state.current.validUntil ?? .infinity, state.dayEnd)
        return max(row.end, cap)
    }

    var notices: [String] {
        guard let state else { return [] }
        var list: [String] = []
        if state.health?.selfSession == true {
            list.append("Нужна сессия другого своего аккаунта. На VPS выполни: bash /root/autismex-install.sh --connect. Пока измерение остановлено.")
        }
        if let mode = state.health?.mode, ["limited", "conflict", "stale", "error", "rate_limit", "reconnecting"].contains(mode) {
            list.append(state.health?.message ?? "Нет подтверждённого статуса.")
        }
        if let errorMessage { list.append(errorMessage) }
        return list
    }
}
