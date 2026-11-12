import SwiftUI

/// Выбранный день: заголовок, циферблат, сравнение со вчера, плитки.
struct DaySection: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    @Binding var scrubbing: Bool
    @AppStorage("dialHintSeen") private var hintSeen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TimelineView(.periodic(from: .now, by: 1)) { context in
                dayBody(date: context.date)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.rounded(34))
                    .tracking(-1)
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 12)
            Text(zoneText)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
        }
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

    private var zoneText: String {
        let tz = state.tz
        let hours = tz.secondsFromGMT() / 3600
        let city: String
        if tz.identifier == "Europe/Moscow" {
            city = "Москва"
        } else {
            city = tz.identifier.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
        }
        return city + ", UTC" + (hours >= 0 ? "+" : "−") + String(abs(hours))
    }

    @ViewBuilder
    private func dayBody(date: Date) -> some View {
        let now = store.serverNow(at: date)
        let live = store.liveState(at: date)
        let metrics = store.liveMetrics(at: date).day
        let observed = metrics.online + metrics.offline
        let note = observed > 0 ? Fmt.percent(metrics.online / observed * 100) + " наблюдаемого времени" : "Нет подтверждённого статуса"
        let delta = Insights.delta(state: state, onlineSeconds: metrics.online, now: now)
        let coverageNote = metrics.unknown > 1 ? "Без данных " + Fmt.duration(metrics.unknown) + ", не считаем паузой" : "Наблюдаемое время без пропусков"

        VStack(spacing: 0) {
            DialView(
                state: state,
                now: now,
                liveState: live,
                onlineSeconds: metrics.online,
                note: note,
                scrubbing: $scrubbing,
                onLearned: { hintSeen = true }
            )
            .padding(.top, 30)

            if let delta {
                DeltaPill(text: delta.text, direction: delta.direction)
                    .padding(.top, 22)
            }

            if !hintSeen {
                Text("Подержи палец на кольце и веди, чтобы увидеть время. Смахни панель внизу, чтобы сменить день.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 16)
                    .transition(.opacity)
            }

            DialLegend()
                .padding(.top, 16)

            Text("Данные: " + Fmt.percent(metrics.coverage) + ". " + coverageNote)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            TilesView(state: state, metrics: metrics, now: now)
                .padding(.top, 32)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.3), value: hintSeen)
    }
}

// MARK: Сравнение и легенда

struct DeltaPill: View {
    let text: String
    let direction: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: direction > 0 ? "arrow.up" : (direction < 0 ? "arrow.down" : "arrow.right"))
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

struct DialLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            item(color: Palette.on, dashed: false, text: "В сети")
            item(color: Palette.off, dashed: false, text: "Офлайн")
            item(color: Palette.ink3, dashed: true, text: "Нет данных")
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink2)
    }

    private func item(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            if dashed {
                Circle()
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 1.5]))
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(Palette.hair, lineWidth: 1))
                    .frame(width: 10, height: 10)
            }
            Text(text)
        }
    }
}

// MARK: Плитки

struct TilesView: View {
    let state: PresenceState
    let metrics: LiveMetrics
    let now: Double

    var body: some View {
        let span = Insights.span(state: state)
        let sessions = Int(metrics.sessions)
        let pauseNote = metrics.maxPauseSource == "telegram_last_seen"
            ? "По Last Seen · наблюдали " + Fmt.duration(metrics.observedMaxPause)
            : "Наблюдаемый максимум за день"

        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Tile(dot: Palette.on, label: "Сеансы онлайн", value: "\(sessions)",
                     note: sessions > 0 ? "В среднем " + Fmt.duration(metrics.averageSession, detailed: true) : "Пока без сеансов онлайн")
                Tile(dot: Palette.offDot, label: "Паузы", value: "\(Int(metrics.pauses))",
                     note: "Наблюдали офлайн " + Fmt.duration(metrics.offline))
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                TileLabel(dot: Palette.on, text: "Первый и последний раз в сети")
                Text(span.value)
                    .font(.rounded(32))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 12)
                Text(span.note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .tileBackground()

            VStack(alignment: .leading, spacing: 0) {
                TileLabel(dot: Palette.offDot, text: "Самая долгая пауза")
                HStack(alignment: .bottom, spacing: 16) {
                    Text(pauseNote)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(Fmt.duration(metrics.maxPause))
                        .font(.rounded(32))
                        .tracking(-0.6)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.top, 10)
            }
            .tileBackground()
        }
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
                .font(.rounded(32))
                .tracking(-0.8)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 12)
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .tileBackground()
        .frame(maxHeight: .infinity)
    }
}

extension View {
    func tileBackground() -> some View {
        padding(EdgeInsets(top: 18, leading: 18, bottom: 20, trailing: 18))
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
            return (state.isToday ? "Столько же, сколько вчера в это время" : "Столько же, сколько накануне", 0)
        }
        let more = difference > 0
        let when = state.isToday ? "чем вчера в это время" : "чем накануне"
        return ("На " + Fmt.duration(abs(difference)) + (more ? " больше, " : " меньше, ") + when, more ? 1 : -1)
    }

    /// Первый выход в сеть, последний и самый долгий сеанс.
    static func span(state: PresenceState) -> (value: String, note: String) {
        let online = state.rows.filter { $0.state == "online" }
        guard let first = online.first, let last = online.last else {
            return ("—", "Сеансов онлайн в этот день не было")
        }
        let live = last.isOngoing && state.isToday
        let value = Fmt.time(first.start, tz: state.tz) + " – " + (live ? "сейчас" : Fmt.time(last.end, tz: state.tz))
        let longest = online.max(by: { $0.duration < $1.duration }) ?? first
        let note = "Самый долгий сеанс " + Fmt.duration(longest.duration, detailed: true) + ", с " + Fmt.time(longest.start, tz: state.tz)
        return (value, note)
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
}
