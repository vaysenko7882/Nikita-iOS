import SwiftUI

/// День за днём: полоска онлайна и черта среднего за период.
struct HistorySection: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    var onPick: () -> Void
    @State private var limit = 7

    var body: some View {
        let all = state.history ?? []
        let rows = Array(all.prefix(limit))
        let longest = max(1, rows.map { $0.onlineSeconds ?? 0 }.max() ?? 1)
        let complete = rows.filter { ($0.date ?? "") != state.today && ($0.coveragePercent ?? 0) > 0 }
        let base = complete.isEmpty ? rows : complete
        let average = base.isEmpty ? 0 : base.reduce(0) { $0 + ($1.onlineSeconds ?? 0) } / Double(base.count)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "День за днём", subtitle: "Сохранённая статистика. Выбери день, чтобы открыть подробности.")
            if average > 0 {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.ink.opacity(0.3))
                        .frame(width: 2, height: 14)
                    Text("Черта — среднее за день: " + Fmt.duration(average))
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .padding(.top, -10)
                .padding(.bottom, 14)
            }
            if rows.isEmpty {
                Text("История появится после первого наблюдения")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
            VStack(spacing: 4) {
                ForEach(rows, id: \.date) { day in
                    HistoryRow(day: day, state: state, longest: longest, average: average) {
                        if let date = day.date {
                            store.pick(date)
                            onPick()
                        }
                    }
                }
            }
            if all.count > limit {
                PanelButton(title: "Показать всю историю за 30 дней") {
                    withAnimation(.snappy) { limit = 30 }
                }
                .padding(.top, 12)
            }
        }
    }
}

struct HistoryRow: View {
    let day: Metrics
    let state: PresenceState
    let longest: Double
    let average: Double
    let action: () -> Void

    var body: some View {
        let date = day.date ?? ""
        let selected = date == state.date
        let online = day.onlineSeconds ?? 0

        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 14) {
                    Text(Fmt.shortDay(date, today: state.today))
                        .font(.system(size: 16, weight: selected ? .bold : .regular))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .leading) {
                            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 5, topTrailingRadius: 5, style: .continuous)
                                .fill(Palette.on)
                                .frame(width: max(4, width * CGFloat(online / longest)), height: 10)
                            if average > 0 {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Palette.ink.opacity(0.3))
                                    .frame(width: 2, height: 22)
                                    .offset(x: width * CGFloat(min(1, average / longest)) - 1)
                            }
                        }
                        .frame(width: width, height: geometry.size.height, alignment: .leading)
                    }
                    .frame(height: 10)
                    Text(Fmt.duration(online))
                        .font(.rounded(17))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(meta)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .background(selected ? Palette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -12)
        .accessibilityLabel(Text("Статистика за " + Fmt.dayText(date, "d MMMM") + ": в сети " + Fmt.duration(online) + ", " + meta))
    }

    private var meta: String {
        let sessions = Int(day.sessionCount ?? 0)
        let pauses = Int(day.pauseCount ?? 0)
        var parts = [
            "\(sessions) " + Fmt.plural(sessions, "сеанс", "сеанса", "сеансов"),
            "\(pauses) " + Fmt.plural(pauses, "пауза", "паузы", "пауз"),
            "пауза до " + Fmt.duration(day.maxPauseSeconds ?? 0)
        ]
        let coverage = day.coveragePercent ?? 0
        if coverage < 99.95 { parts.append("данные " + Fmt.percent(coverage)) }
        return parts.joined(separator: ", ")
    }
}
