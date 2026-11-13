import Foundation
import Observation
import SwiftUI
import WidgetKit

/// Показатели дня, которые растут между ответами сервера.
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

/// Источник данных приложения.
///
/// Ради плавной прокрутки данные разделены на два слоя:
/// • `state` — снимок для раскладки экрана. Меняется только когда изменилось что-то
///   существенное (статус, новый отрезок, другой день) или раз в 45 секунд.
/// • `latest` — самый свежий ответ сервера. Его читают только маленькие «тикающие»
///   тексты (таймер, цифра в центре циферблата), поэтому весь экран каждую секунду
///   не перерисовывается.
@MainActor
@Observable
final class PresenceStore {
    private(set) var state: PresenceState? = nil
    private(set) var errorMessage: String? = nil
    private(set) var streamOpen = false
    /// Пришёл ли хотя бы один свежий ответ после запуска.
    private(set) var bootstrapped = false

    let api = PresenceAPI()

    @ObservationIgnored private var latest: PresenceState?
    @ObservationIgnored private var fetchedAt = Date.distantPast
    @ObservationIgnored private var lastSuccess: Date?
    @ObservationIgnored private var stateKey = ""
    @ObservationIgnored private var stateSetAt = Date.distantPast
    @ObservationIgnored private var lastRefreshStart = Date.distantPast
    @ObservationIgnored private var lastCacheWrite = Date.distantPast
    @ObservationIgnored private var followToday = true
    @ObservationIgnored private var requestedDate: String?
    @ObservationIgnored private var requestNumber = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var widgetKey: String?

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("presence-state.json")
    }

    /// Мгновенный запуск: показываем последний сохранённый ответ за сегодня, пока идёт запрос.
    init() {
        let url = PresenceStore.cacheURL
        guard let data = try? Data(contentsOf: url),
              let cached = try? PresenceAPI.decoder.decode(PresenceState.self, from: data),
              cached.isToday,
              Fmt.isoDay(Date().timeIntervalSince1970, tz: cached.tz) == cached.today else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let savedAt = (attributes?[.modificationDate] as? Date) ?? Date()
        latest = cached
        fetchedAt = savedAt
        state = cached
        stateKey = PresenceStore.fingerprint(cached)
        stateSetAt = savedAt
    }

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
        if streamOpen { streamOpen = false }
    }

    func refresh(force: Bool = false) async {
        requestNumber += 1
        let number = requestNumber
        lastRefreshStart = Date()
        do {
            let (next, data) = try await api.stateWithData(date: followToday ? nil : requestedDate)
            guard number == requestNumber else { return }
            apply(next, force: force)
            if next.isToday { cache(data) }
        } catch {
            guard number == requestNumber else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? "Не удалось получить статистику. Проверь соединение с сайтом."
            if errorMessage != message { errorMessage = message }
        }
    }

    private func apply(_ next: PresenceState, force: Bool) {
        let now = Date()
        latest = next
        fetchedAt = now
        lastSuccess = now
        if !bootstrapped { bootstrapped = true }
        if errorMessage != nil { errorMessage = nil }
        if next.isToday {
            followToday = true
            requestedDate = nil
        }
        let key = PresenceStore.fingerprint(next)
        if force || state == nil || key != stateKey || now.timeIntervalSince(stateSetAt) > 45 {
            state = next
            stateKey = key
            stateSetAt = now
        }
        reloadWidgetsIfNeeded(next)
    }

    /// Что считается существенным изменением экрана.
    private static func fingerprint(_ state: PresenceState) -> String {
        let last = state.rows.last
        let parts: [String] = [
            state.date,
            state.today,
            state.current.state ?? "",
            String(Int(state.current.since ?? 0)),
            String(state.rows.count),
            last?.state ?? "",
            String(Int(last?.start ?? 0)),
            String(state.history?.count ?? 0),
            state.health?.mode ?? "",
            (state.health?.selfSession ?? false) ? "self" : "",
            state.health?.message ?? "",
            state.profile?.name ?? "",
            state.profile?.avatarVersion ?? ""
        ]
        return parts.joined(separator: "|")
    }

    private func cache(_ data: Data) {
        let now = Date()
        guard now.timeIntervalSince(lastCacheWrite) > 30 else { return }
        lastCacheWrite = now
        let url = PresenceStore.cacheURL
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func pick(_ day: String) {
        guard let state, day <= state.today, day != state.date else { return }
        if day == state.today {
            followToday = true
            requestedDate = nil
        } else {
            followToday = false
            requestedDate = day
        }
        Task { await refresh(force: true) }
    }

    func move(by days: Int) {
        guard let state else { return }
        pick(Fmt.shiftDay(state.date, days))
    }

    /// Не чаще одного запроса в 0,8 с, даже если сервер шлёт события подряд.
    private func scheduleRefresh() {
        debounceTask?.cancel()
        let sinceLast = Date().timeIntervalSince(lastRefreshStart)
        let delay = max(0.15, 0.8 - sinceLast)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Поток событий сервера (SSE). Как и сайт, реагируем только на событие «update».
    private func startStream() {
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let request = self?.api.eventsRequest() else { return }
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        self?.setStream(true)
                        var eventName = "message"
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            if line.hasPrefix("event:") {
                                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                if eventName == "update" { self?.scheduleRefresh() }
                                eventName = "message"
                            }
                        }
                    }
                } catch {
                    // Переподключимся ниже.
                }
                self?.setStream(false)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func setStream(_ open: Bool) {
        if streamOpen != open { streamOpen = open }
    }

    /// Запасной опрос: если поток молчит, данные устарели или наступил новый день.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let age = Date().timeIntervalSince(self.lastSuccess ?? .distantPast)
                var rolledOver = false
                if self.followToday, let latest = self.latest {
                    rolledOver = Fmt.isoDay(self.serverNow(), tz: latest.tz) != latest.today
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
        guard let latest else { return date.timeIntervalSince1970 }
        return latest.now + date.timeIntervalSince(fetchedAt)
    }

    func isConnected(at date: Date) -> Bool {
        if streamOpen && bootstrapped { return true }
        guard let lastSuccess else { return false }
        return date.timeIntervalSince(lastSuccess) < 12
    }

    func liveState(at date: Date) -> String {
        guard let latest, isConnected(at: date), latest.health?.selfSession != true else { return "unknown" }
        if let validUntil = latest.current.validUntil, serverNow(at: date) >= validUntil { return "unknown" }
        return latest.current.state ?? "unknown"
    }

    func liveMetrics(at date: Date) -> (day: LiveMetrics, total: LiveMetrics) {
        guard let state = latest else { return (LiveMetrics(), LiveMetrics()) }
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

    /// Крупная строка статуса.
    func headline(at date: Date) -> String {
        if isConnected(at: date) { return Labels.state(liveState(at: date)) }
        return (bootstrapped || errorMessage != nil) ? "Нет связи" : "Обновляем…"
    }

    /// Строка под статусом: «3 мин 44 с, с 18:43».
    func statusLine(at date: Date) -> String {
        guard let state = latest else { return "Ждём данные Telegram" }
        let live = liveState(at: date)
        let now = serverNow(at: date)
        let current = state.current
        switch live {
        case "unknown":
            if !isConnected(at: date) {
                return bootstrapped ? "Показаны последние полученные данные" : "Показаны данные с прошлого запуска"
            }
            if state.health?.selfSession == true { return "Подключи другой свой аккаунт на VPS" }
            if let raw = current.state, raw != "unknown" { return "Статус устарел, ждём подтверждение" }
            return current.reason ?? "Ждём точный статус"
        case "offline":
            let start = current.pauseSince ?? current.since ?? now
            let startDay = Fmt.isoDay(start, tz: state.tz)
            let prefix = startDay == state.today ? "" : Fmt.dayText(startDay, "d MMM") + " "
            return Fmt.duration(now - start, detailed: true) + ", с " + prefix + Fmt.time(start, tz: state.tz)
        default:
            let start = current.since ?? now
            return Fmt.duration(now - start, detailed: true) + ", с " + Fmt.time(start, tz: state.tz)
        }
    }

    /// Конец отрезка с учётом того, что текущий растёт прямо сейчас.
    func liveEnd(_ row: Interval, at date: Date = Date()) -> Double {
        guard let state = latest, row.isOngoing, state.isToday else { return row.end }
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
        if let errorMessage, bootstrapped { list.append(errorMessage) }
        return list
    }
}
