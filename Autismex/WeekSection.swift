import SwiftUI

/// Ритм недели: точка в каждом часе, площадь точки — минуты онлайн.
struct WeekSection: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    @State private var picked: PickedCell?

    struct PickedCell: Equatable {
        var date: String
        var hour: Int
    }

    var body: some View {
        let facts = Insights.week(state: state)
        let hourNow = state.isToday ? Fmt.hourMinute(store.serverNow(), tz: state.tz).hour : 24

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: "Ритм недели",
                subtitle: "Чем крупнее точка, тем больше минут онлайн было в этот час. Нажми на день слева, чтобы открыть его."
            )
            if facts.peak != nil || facts.average != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips(peak: facts.peak, average: facts.average) }
                    VStack(alignment: .leading, spacing: 8) { chips(peak: facts.peak, average: facts.average) }
                }
                .padding(.bottom, 22)
            }

            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 40, height: 1)
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(Fmt.two(hour))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(width: 46, height: 1)
                }
                .padding(.bottom, 6)
                ForEach(state.heatmap ?? [], id: \.date) { day in
                    row(day, hourNow: hourNow)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                readout(hourNow: hourNow)
                Spacer(minLength: 0)
                scale
            }
            .padding(.top, 16)
        }
        .onChange(of: state.date) { _, _ in picked = nil }
    }

    @ViewBuilder
    private func chips(peak: String?, average: String?) -> some View {
        if let peak { FactChip(value: peak, label: "чаще всего в сети") }
        if let average { FactChip(value: average, label: "в среднем за день") }
    }

    private func row(_ day: HeatmapDay, hourNow: Int) -> some View {
        let current = day.date == state.date
        let total = day.cells.reduce(0) { $0 + $1.online }
        let known = day.cells.contains { $0.known > 0 }
        let dayNumber = Int(day.date.suffix(2)) ?? 0
        return HStack(spacing: 0) {
            Button {
                store.pick(day.date)
            } label: {
                Text(Fmt.cap(Fmt.dayText(day.date, "EE")) + " " + String(dayNumber))
                    .font(.system(size: 13, weight: current ? .bold : .regular))
                    .foregroundStyle(current ? Palette.ink : Palette.ink2)
                    .frame(width: 40, height: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(day.cells, id: \.hour) { cell in
                dot(day: day, cell: cell, future: day.date == state.today && cell.hour > hourNow)
            }
            Text(known ? Fmt.compactMinutes(total) : "—")
                .font(.system(size: 11, weight: current ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(current ? Palette.ink : Palette.ink2)
                .lineLimit(1)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 28)
    }

    private func dot(day: HeatmapDay, cell: HeatCell, future: Bool) -> some View {
        let minutes = max(0, min(60, cell.online))
        let share = (minutes / 60).squareRoot()
        let isPicked = picked == PickedCell(date: day.date, hour: cell.hour)
        let size = CGFloat(3 + share * 8)
        return ZStack {
            if isPicked {
                Circle().fill(Palette.panel2).frame(width: 24, height: 24)
            }
            if future {
                Circle().fill(Palette.ink3.opacity(0.3)).frame(width: 2, height: 2)
            } else if cell.known <= 0 {
                Circle().strokeBorder(Palette.ink3.opacity(0.8), lineWidth: 1.2).frame(width: 6, height: 6)
            } else if minutes <= 0 {
                Circle().fill(Palette.ink3.opacity(0.7)).frame(width: 3, height: 3)
            } else {
                Circle().fill(Palette.on.opacity(0.4 + share * 0.6)).frame(width: size, height: size)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            picked = PickedCell(date: day.date, hour: cell.hour)
        }
        .sensoryFeedback(.selection, trigger: isPicked) { _, nowPicked in nowPicked }
    }

    @ViewBuilder
    private func readout(hourNow: Int) -> some View {
        if let picked,
           let day = state.heatmap?.first(where: { $0.date == picked.date }),
           let cell = day.cells.first(where: { $0.hour == picked.hour }) {
            let when = Fmt.dayText(day.date, "d MMM") + ", " + Fmt.two(cell.hour) + ":00"
            let detail = cellDetail(cell, future: day.date == state.today && cell.hour > hourNow)
            (Text(when).fontWeight(.semibold).foregroundColor(Palette.ink) + Text(", " + detail))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Нажми на точку, чтобы увидеть минуты")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cellDetail(_ cell: HeatCell, future: Bool) -> String {
        if future { return "ещё не наступило" }
        if cell.known <= 0 { return "нет данных" }
        return "\(Int(cell.online.rounded())) мин онлайн из \(Int(cell.known.rounded()))"
    }

    private var scale: some View {
        HStack(spacing: 6) {
            Text("0")
            Circle().fill(Palette.ink3.opacity(0.7)).frame(width: 3, height: 3)
            ForEach([0.45, 0.75, 1.0], id: \.self) { share in
                Circle()
                    .fill(Palette.on.opacity(0.4 + share * 0.6))
                    .frame(width: CGFloat(3 + share * 8), height: CGFloat(3 + share * 8))
            }
            Text("60 мин")
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.ink2)
        .fixedSize()
    }
}
