import SwiftUI

/// Выбранный день: заголовок, циферблат, один вывод и четыре плитки.
/// Сама секция не тикает: живые цифры обновляются внутри циферблата.
struct DaySection: View {
    @Environment(PresenceStore.self) private var store
    @Environment(Interaction.self) private var interaction
    let state: PresenceState
    @Binding var scrubbing: Bool
    @AppStorage("dialHintSeen") private var hintSeen = false

    var body: some View {
        let now = store.serverNow()
        let metrics = store.liveMetrics(at: Date()).day
        let delta = Insights.usual(state: state, onlineSeconds: metrics.online, now: now)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.rounded(34))
                    .tracking(-1)
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DialView(state: state, scrubbing: $scrubbing, onLearned: { hintSeen = true })
                .id("dial")
                .padding(.top, 26)

            if let delta {
                DeltaPill(text: delta.text, direction: delta.direction)
                    .padding(.top, 20)
            }

            if !hintSeen {
                Text("Задержи палец на кольце и веди по нему.\nЗелёные точки внутри — привычные часы недели.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
            }

            if metrics.unknown > 90 {
                Text("Без данных " + Fmt.duration(metrics.unknown) + ", паузой не считаем")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }

            TilesView(state: state, metrics: metrics, onFocus: { start in interaction.focus(start) })
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        Fmt.relative(state.date, today: state.today) ?? Fmt.cap(Fmt.dayText(state.date, "d MMMM"))
    }

    private var subtitle: String {
        if Fmt.relative(state.date, today: state.today) != nil {
            return Fmt.cap(Fmt.dayText(state.date, "EEEE, d MMMM"))
        }
        let year = state.date.prefix(4) != state.today.prefix(4) ? ", " + String(state.date.prefix(4)) : ""
        return Fmt.cap(Fmt.dayText(state.date, "EEEE")) + year
    }
}

struct DeltaPill: View {
    let text: String
    let direction: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: direction > 0 ? "arrow.up" : (direction < 0 ? "arrow.down" : "equal"))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.ink2)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.panel, in: Capsule())
    }
}

// MARK: Плитки

/// Четыре плитки одного вида: подпись, значение, одна короткая заметка.
/// Плитки со значком прицела показывают свой отрезок на циферблате.
struct TilesView: View {
    let state: PresenceState
    let metrics: LiveMetrics
    var onFocus: (Double) -> Void

    var body: some View {
        let sessions = Int(metrics.sessions)
        let pauses = Int(metrics.pauses)
        let online = state.rows.filter { $0.state == "online" }
        let first = online.first
        let last = online.last
        let longest = online.max(by: { $0.duration < $1.duration })
        let longestPause = state.rows.filter { $0.state == "offline" }.max(by: { $0.duration < $1.duration })

        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Tile(dot: Palette.on, label: "Сеансы", value: String(sessions),
                     note: sessions > 0 ? "в среднем " + Fmt.duration(metrics.averageSession) : "пока не было")
                Tile(dot: Palette.offDot, label: "Паузы", value: String(pauses),
                     note: metrics.maxPause > 0 ? "до " + Fmt.duration(metrics.maxPause) : "пока не было",
                     action: focusAction(longestPause))
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                Tile(dot: Palette.on, label: "Первый выход",
                     value: first.map { Fmt.time($0.start, tz: state.tz) } ?? "—",
                     note: lastNote(last),
                     action: focusAction(first))
                Tile(dot: Palette.on, label: "Долгий сеанс",
                     value: longest.map { Fmt.duration($0.duration) } ?? "—",
                     note: longest.map { "с " + Fmt.time($0.start, tz: state.tz) } ?? "сеансов не было",
                     action: focusAction(longest))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func focusAction(_ row: Interval?) -> (() -> Void)? {
        guard let row else { return nil }
        return { onFocus(row.start) }
    }

    private func lastNote(_ last: Interval?) -> String {
        guard let last else { return "сеансов не было" }
        if last.isOngoing && state.isToday { return "и сейчас в сети" }
        return "последний в " + Fmt.time(last.end, tz: state.tz)
    }
}

struct TileLabel: View {
    let dot: Color
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Palette.ink2)
    }
}

struct Tile: View {
    let dot: Color
    let label: String
    let value: String
    let note: String
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) {
                content(showsScope: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Показать на циферблате"))
        } else {
            content(showsScope: false)
        }
    }

    private func content(showsScope: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TileLabel(dot: dot, text: label)
                Spacer(minLength: 0)
                if showsScope {
                    Image(systemName: "scope")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                }
            }
            Text(value)
                .font(.rounded(30))
                .tracking(-0.8)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.top, 10)
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: Выводы, которые считаются из того же ответа сервера

enum Insights {
    /// Сравнение с обычным днём недели: сколько в среднем набиралось к этому часу
    /// (для сегодня) или за целый день (для прошедших дней).
    static func usual(state: PresenceState, onlineSeconds: Double, now: Double) -> (text: String, direction: Int)? {
        guard let days = state.heatmap, days.contains(where: { $0.date == state.date }) else { return nil }
        let clock = Fmt.hourMinute(now, tz: state.tz)
        var totals: [Double] = []
        for day in days where day.date != state.date && day.date != state.today {
            guard day.cells.contains(where: { $0.known > 0 }) else { continue }
            var minutes = 0.0
            for cell in day.cells {
                if !state.isToday || cell.hour < clock.hour {
                    minutes += cell.online
                } else if cell.hour == clock.hour {
                    minutes += cell.online * Double(clock.minute) / 60
                }
            }
            totals.append(minutes)
        }
        guard !totals.isEmpty else { return nil }
        let usual = totals.reduce(0, +) / Double(totals.count) * 60
        let difference = onlineSeconds - usual
        let tail = state.isToday ? " к этому часу" : ""
        if abs(difference) < 60 { return ("Как обычно" + tail, 0) }
        let more = difference > 0
        return ("На " + Fmt.duration(abs(difference)) + (more ? " больше" : " меньше") + " обычного" + tail, more ? 1 : -1)
    }

    /// Пиковый час и среднее время в сети за полный день.
    static func week(state: PresenceState) -> (peak: String?, average: String?) {
        guard let days = state.heatmap, !days.isEmpty else { return (nil, nil) }
        var byHour = Array(repeating: 0.0, count: 24)
        var totals: [Double] = []
        for day in days {
            for cell in day.cells where cell.hour >= 0 && cell.hour < 24 {
                byHour[cell.hour] += cell.online
            }
            let known = day.cells.contains { $0.known > 0 }
            if known && day.date != state.today {
                totals.append(day.cells.reduce(0) { $0 + $1.online })
            }
        }
        var peak: String?
        if let top = byHour.max(), top > 0, let hour = byHour.firstIndex(of: top) {
            peak = Fmt.two(hour) + ":00–" + Fmt.two((hour + 1) % 24) + ":00"
        }
        var average: String?
        if !totals.isEmpty {
            average = Fmt.duration(totals.reduce(0, +) / Double(totals.count) * 60)
        }
        return (peak, average)
    }

    /// Привычный ритм: средняя доля онлайна в каждом часе за прошлые дни недели (0…1).
    static func habit(state: PresenceState) -> [Double]? {
        guard let days = state.heatmap else { return nil }
        var sum = Array(repeating: 0.0, count: 24)
        var count = Array(repeating: 0.0, count: 24)
        for day in days where day.date != state.today {
            for cell in day.cells where cell.hour >= 0 && cell.hour < 24 && cell.known > 0 {
                sum[cell.hour] += min(60, cell.online)
                count[cell.hour] += 1
            }
        }
        guard count.contains(where: { $0 > 0 }) else { return nil }
        return (0..<24).map { hour in count[hour] > 0 ? sum[hour] / count[hour] / 60 : 0 }
    }

    /// Сумма за последние 7 дней и за 7 дней до них (история идёт от новых к старым).
    static func weekTotals(history: [Metrics]) -> (current: Double, previous: Double?) {
        let current = history.prefix(7).reduce(0) { $0 + ($1.onlineSeconds ?? 0) }
        guard history.count >= 14 else { return (current, nil) }
        let previous = history.dropFirst(7).prefix(7).reduce(0) { $0 + ($1.onlineSeconds ?? 0) }
        return (current, previous)
    }

    /// День с самым большим временем в сети.
    static func recordDate(history: [Metrics]) -> String? {
        guard history.count >= 3,
              let best = history.max(by: { ($0.onlineSeconds ?? 0) < ($1.onlineSeconds ?? 0) }),
              (best.onlineSeconds ?? 0) > 0 else { return nil }
        return best.date
    }

    /// Среднее время в сети за показанные полные дни.
    static func historyAverage(rows: [Metrics], today: String) -> Double {
        let complete = rows.filter { ($0.date ?? "") != today && ($0.coveragePercent ?? 0) > 0 }
        let base = complete.isEmpty ? rows : complete
        guard !base.isEmpty else { return 0 }
        return base.reduce(0) { $0 + ($1.onlineSeconds ?? 0) } / Double(base.count)
    }
}
