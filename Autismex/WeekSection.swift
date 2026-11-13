import SwiftUI

/// Ритм недели: точка в каждом часе, площадь точки — минуты онлайн.
/// Вся сетка — один Canvas и один жест касания: это 1 вью вместо 168.
struct WeekSection: View {
    @Environment(PresenceStore.self) private var store
    @Environment(Interaction.self) private var interaction
    let state: PresenceState
    @State private var picked: PickedCell?

    struct PickedCell: Equatable {
        var date: String
        var hour: Int
    }

    private let headerHeight: CGFloat = 18
    private let rowHeight: CGFloat = 28

    var body: some View {
        let days = state.heatmap ?? []
        let facts = Insights.week(state: state)
        let hourNow = Fmt.hourMinute(store.serverNow(), tz: state.tz).hour

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Ритм недели")

            if facts.peak != nil || facts.average != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips(peak: facts.peak, average: facts.average) }
                    VStack(alignment: .leading, spacing: 8) { chips(peak: facts.peak, average: facts.average) }
                }
                .padding(.bottom, 20)
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                    ForEach(days, id: \.date) { day in
                        dayButton(day)
                    }
                }
                .frame(width: 42)

                GeometryReader { geometry in
                    Canvas { context, size in
                        draw(&context, size: size, days: days, hourNow: hourNow)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            pick(at: value.location, width: geometry.size.width, days: days)
                        }
                    )
                }
                .frame(height: headerHeight + rowHeight * CGFloat(days.count))

                VStack(spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                    ForEach(days, id: \.date) { day in
                        total(day)
                    }
                }
                .frame(width: 48)
            }
            // Полоса под строкой открытого дня.
            .background(alignment: .top) {
                if let index = days.firstIndex(where: { $0.date == state.date }) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.panel)
                        .frame(height: rowHeight - 2)
                        .padding(.horizontal, -8)
                        .offset(y: headerHeight + CGFloat(index) * rowHeight + 1)
                }
            }

            footer(days: days, hourNow: hourNow)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .padding(.top, 14)
        }
        .sensoryFeedback(.selection, trigger: picked)
        .onChange(of: state.date) { _, _ in picked = nil }
    }

    @ViewBuilder
    private func chips(peak: String?, average: String?) -> some View {
        if let peak { FactChip(value: peak, label: "пик") }
        if let average { FactChip(value: average, label: "в среднем за день") }
    }

    private func dayButton(_ day: HeatmapDay) -> some View {
        let current = day.date == state.date
        let dayNumber = Int(day.date.suffix(2)) ?? 0
        return Button {
            guard !current else { return }
            store.pick(day.date)
            interaction.scroll(to: "day")
        } label: {
            Text(Fmt.cap(Fmt.dayText(day.date, "EE")) + " " + String(dayNumber))
                .font(.system(size: 13, weight: current ? .bold : .regular))
                .foregroundStyle(current ? Palette.ink : Palette.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: rowHeight)
    }

    private func total(_ day: HeatmapDay) -> some View {
        let current = day.date == state.date
        let known = day.cells.contains { $0.known > 0 }
        let minutes = day.cells.reduce(0) { $0 + $1.online }
        return Text(known ? Fmt.compactMinutes(minutes) : "—")
            .font(.system(size: 11, weight: current ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(current ? Palette.ink : Palette.ink2)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .trailing)
            .frame(height: rowHeight)
    }

    // MARK: Сетка

    private func draw(_ context: inout GraphicsContext, size: CGSize, days: [HeatmapDay], hourNow: Int) {
        let cellWidth = size.width / 24
        let maxDot = max(4, min(11, cellWidth - 1.5))

        for hour in [0, 6, 12, 18] {
            let label = Text(verbatim: Fmt.two(hour))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.ink3)
            context.draw(label, at: CGPoint(x: CGFloat(hour) * cellWidth + 1, y: 6), anchor: .leading)
        }

        for (rowIndex, day) in days.enumerated() {
            let y = headerHeight + CGFloat(rowIndex) * rowHeight + rowHeight / 2
            for cell in day.cells where cell.hour >= 0 && cell.hour < 24 {
                let x = (CGFloat(cell.hour) + 0.5) * cellWidth
                let isPicked = picked == PickedCell(date: day.date, hour: cell.hour)
                if isPicked {
                    let box = CGRect(x: x - cellWidth / 2 - 2, y: y - 11, width: cellWidth + 4, height: 22)
                    context.fill(Path(roundedRect: box, cornerRadius: 7), with: .color(Palette.panel2))
                }
                let future = day.date == state.today && cell.hour > hourNow
                if future {
                    context.fill(circle(x, y, 2), with: .color(Palette.ink3.opacity(0.3)))
                } else if cell.known <= 0 {
                    context.stroke(circle(x, y, 5.5), with: .color(Palette.ink3.opacity(0.8)), lineWidth: 1.2)
                } else if cell.online <= 0 {
                    context.fill(circle(x, y, 3), with: .color(Palette.ink3.opacity(0.7)))
                } else {
                    let share = (max(0, min(60, cell.online)) / 60).squareRoot()
                    let diameter = 3 + CGFloat(share) * (maxDot - 3)
                    context.fill(circle(x, y, diameter), with: .color(Palette.on.opacity(0.4 + share * 0.6)))
                }
            }
        }
    }

    private func circle(_ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
    }

    private func pick(at location: CGPoint, width: CGFloat, days: [HeatmapDay]) {
        guard width > 0, location.y >= headerHeight else { return }
        let row = Int((location.y - headerHeight) / rowHeight)
        let hour = Int(location.x / (width / 24))
        guard row >= 0, row < days.count, hour >= 0, hour < 24 else { return }
        let cell = PickedCell(date: days[row].date, hour: hour)
        picked = picked == cell ? nil : cell
    }

    // MARK: Подпись под сеткой

    @ViewBuilder
    private func footer(days: [HeatmapDay], hourNow: Int) -> some View {
        if let picked,
           let day = days.first(where: { $0.date == picked.date }),
           let cell = day.cells.first(where: { $0.hour == picked.hour }) {
            let when = Fmt.cap(Fmt.dayText(day.date, "EE, d MMM")) + ", " + Fmt.two(cell.hour) + ":00"
            let detail = cellDetail(cell, future: day.date == state.today && cell.hour > hourNow)
            (Text(when).fontWeight(.semibold).foregroundColor(Palette.ink) + Text(" — " + detail))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            scale
        }
    }

    private func cellDetail(_ cell: HeatCell, future: Bool) -> String {
        if future { return "ещё не наступило" }
        if cell.known <= 0 { return "нет данных" }
        return String(Int(cell.online.rounded())) + " мин в сети"
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
            Text("60 мин в час")
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.ink2)
        .fixedSize()
    }
}
