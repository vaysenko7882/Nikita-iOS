import SwiftUI

/// Выбранный день: заголовок, циферблат, один вывод и три плитки.
/// Сама секция не тикает: живые цифры обновляются внутри циферблата.
struct DaySection: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    @Binding var scrubbing: Bool
    @AppStorage("dialHintSeen") private var hintSeen = false

    var body: some View {
        let now = store.serverNow()
        let metrics = store.liveMetrics(at: Date()).day
        let delta = Insights.delta(state: state, onlineSeconds: metrics.online, now: now)

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
                .padding(.top, 26)

            if let delta {
                DeltaPill(text: delta.text, direction: delta.direction)
                    .padding(.top, 20)
            }

            if !hintSeen {
                Text("Задержи палец на кольце и веди по нему")
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

            TilesView(state: state, metrics: metrics)
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

struct TilesView: View {
    let state: PresenceState
    let metrics: LiveMetrics

    var body: some View {
        let sessions = Int(metrics.sessions)
        let pauses = Int(metrics.pauses)
        let span = Insights.span(state: state)

        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Tile(dot: Palette.on, label: "Сеансы", value: String(sessions),
                     note: sessions > 0 ? "в среднем " + Fmt.duration(metrics.averageSession) : "пока не было")
                Tile(dot: Palette.offDot, label: "Паузы", value: String(pauses), note: pauseNote)
            }
            .fixedSize(horizontal: false, vertical: true)

            if let span {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        TileLabel(dot: Palette.on, text: "Первый и последний выход")
                        Text(span.note)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Text(span.value)
                        .font(.rounded(22))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private var pauseNote: String {
        guard metrics.maxPause > 0 else { return "пока не было" }
        let source = metrics.maxPauseSource == "telegram_last_seen" ? " по Last Seen" : ""
        return "до " + Fmt.duration(metrics.maxPause) + source
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileLabel(dot: dot, text: label)
            Text(value)
                .font(.rounded(34))
                .tracking(-0.8)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
    }
}

// MARK: Выводы, которые считаются из того же ответа сервера

enum Insights {
    /// Сравнение с предыдущим днём. Для сегодня — с тем же временем суток вчера.
    static func delta(state: PresenceState, onlineSeconds: Double, now: Double) -> (text: String, direction: Int)? {
        let previousDay = Fmt.shiftDay(state.date, -1)
        guard let previous = state.heatmap?.first(where: { $0.date == previousDay }),
              previous.cells.contains(where: { $0.known > 0 }) else { return nil }
        var minutes = 0.0
        if state.isToday {
            let clock = Fmt.hourMinute(now, tz: state.tz)
            for cell in previous.cells {
                if cell.hour < clock.hour {
                    minutes += cell.online
                } else if cell.hour == clock.hour {
                    minutes += cell.online * Double(clock.minute) / 60
                }
            }
        } else {
            minutes = previous.cells.reduce(0) { $0 + $1.online }
        }
        let difference = onlineSeconds - minutes * 60
        if abs(difference) < 60 {
            return (state.isToday ? "Как вчера в это время" : "Как накануне", 0)
        }
        let more = difference > 0
        let when = state.isToday ? "чем вчера в это время" : "чем накануне"
        return ("На " + Fmt.duration(abs(difference)) + (more ? " больше, " : " меньше, ") + when, more ? 1 : -1)
    }

    /// Первый выход в сеть, последний и самый долгий сеанс.
    static func span(state: PresenceState) -> (value: String, note: String)? {
        let online = state.rows.filter { $0.state == "online" }
        guard let first = online.first, let last = online.last else { return nil }
        let live = last.isOngoing && state.isToday
        let value = Fmt.time(first.start, tz: state.tz) + " – " + (live ? "сейчас" : Fmt.time(last.end, tz: state.tz))
        let longest = online.max(by: { $0.duration < $1.duration }) ?? first
        return (value, "самый долгий сеанс " + Fmt.duration(longest.duration))
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

    /// Среднее время в сети за показанные полные дни.
    static func historyAverage(rows: [Metrics], today: String) -> Double {
        let complete = rows.filter { ($0.date ?? "") != today && ($0.coveragePercent ?? 0) > 0 }
        let base = complete.isEmpty ? rows : complete
        guard !base.isEmpty else { return 0 }
        return base.reduce(0) { $0 + ($1.onlineSeconds ?? 0) } / Double(base.count)
    }
}
