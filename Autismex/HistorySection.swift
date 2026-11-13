import SwiftUI

/// День за днём: одна строка на день, полоска онлайна и черта среднего.
struct HistorySection: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    var onPick: () -> Void
    @State private var limit = 7

    var body: some View {
        let all = state.history ?? []
        let rows = Array(all.prefix(limit))
        let longest = max(1, rows.map { $0.onlineSeconds ?? 0 }.max() ?? 1)
        let average = Insights.historyAverage(rows: rows, today: state.today)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "День за днём", note: average > 0 ? "Черта — среднее, " + Fmt.duration(average) : nil)

            if rows.isEmpty {
                Text("История появится после первого наблюдения")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
            VStack(spacing: 2) {
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
                PanelButton(title: "Вся история") {
                    limit = 30
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
        let coverage = day.coveragePercent ?? 0

        Button(action: action) {
            HStack(spacing: 12) {
                Text(Fmt.shortDay(date, today: state.today))
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 100, alignment: .leading)
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
                .frame(height: 22)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.duration(online))
                        .font(.rounded(16, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if coverage < 90 {
                        Text("данные " + Fmt.percent(coverage))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                    }
                }
                .frame(width: 92, alignment: .trailing)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .background(selected ? Palette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -12)
        .accessibilityLabel(Text(accessibilityText(date: date, online: online, coverage: coverage)))
    }

    private func accessibilityText(date: String, online: Double, coverage: Double) -> String {
        let sessions = Int(day.sessionCount ?? 0)
        return Fmt.dayText(date, "d MMMM") + ": в сети " + Fmt.duration(online) + ", "
            + String(sessions) + " " + Fmt.plural(sessions, "сеанс", "сеанса", "сеансов")
            + ", данные " + Fmt.percent(coverage)
    }
}
