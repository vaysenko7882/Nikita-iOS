import SwiftUI

/// Хроника дня в виде переписки: сеансы онлайн — исходящие сообщения,
/// чем дольше сеанс, тем шире пузырь; паузы — короткие служебные плашки.
struct ChronicleSection: View {
    let state: PresenceState
    /// Ширина колонки содержимого (экран минус поля).
    let width: CGFloat
    @State private var limit = 7

    var body: some View {
        let all = state.rows
        let shown = Array(all.suffix(limit))
        let longest = max(1, shown.filter { $0.state == "online" }.map { $0.duration }.max() ?? 1)
        let hidden = all.count - shown.count
        let inner = max(160, width - 24)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Хроника")

            VStack(spacing: 7) {
                if hidden > 0 {
                    Button {
                        limit += 20
                    } label: {
                        Text("Раньше, ещё " + String(hidden))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.pillInk)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Palette.pill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 5)
                }
                ServicePill(text: dayLabel, bold: true)
                    .padding(.bottom, 6)
                if shown.isEmpty {
                    ServicePill(text: "Наблюдений пока нет")
                }
                ForEach(shown) { row in
                    item(row, longest: longest, inner: inner)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 12, bottom: 20, trailing: 12))
            .frame(maxWidth: .infinity)
            .background(ChatWallpaper())
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .onChange(of: state.date) { _, _ in limit = 7 }
    }

    private var dayLabel: String {
        let relative = Fmt.relative(state.date, today: state.today).map { $0 + ", " } ?? ""
        return relative + Fmt.dayText(state.date, "d MMMM")
    }

    @ViewBuilder
    private func item(_ row: Interval, longest: Double, inner: CGFloat) -> some View {
        let live = row.isOngoing && state.isToday
        if row.state == "online" {
            let fraction = CGFloat(0.54 + 0.38 * (row.duration / longest).squareRoot())
            let range = Fmt.time(row.start, tz: state.tz) + " – " + (live ? "сейчас" : Fmt.time(row.end, tz: state.tz))
            MessageBubble(row: row, range: range, live: live, width: max(150, min(inner - 4, inner * fraction)))
        } else {
            PausePill(row: row, live: live)
        }
    }
}

/// Длительность, которая растёт каждую секунду. Тикает только этот текст.
struct LiveDuration: View {
    @Environment(PresenceStore.self) private var store
    let row: Interval
    let live: Bool

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.duration(store.liveEnd(row, at: context.date) - row.start, detailed: true))
            }
        } else {
            Text(Fmt.duration(row.duration, detailed: true))
        }
    }
}

struct MessageBubble: View {
    let row: Interval
    let range: String
    let live: Bool
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if live {
                HStack(spacing: 4) {
                    Text("в сети сейчас")
                    TypingDots()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.bubbleMeta)
            } else if row.isContinued {
                Text("с прошлого дня")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.bubbleMeta)
            }
            LiveDuration(row: row, live: live)
                .font(.rounded(19))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
            Text(range)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Palette.bubbleMeta)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 8)
        .padding(.bottom, 7)
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .frame(width: width, alignment: .leading)
        .background(BubbleShape().fill(Palette.bubble))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("В сети " + Fmt.duration(row.duration, detailed: true) + ", " + range))
    }
}

struct PausePill: View {
    let row: Interval
    let live: Bool

    var body: some View {
        let unknown = row.state == "unknown"
        HStack(spacing: 4) {
            Text(unknown ? "Нет данных" : "Пауза")
            LiveDuration(row: row, live: live)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.ink)
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .foregroundStyle(Palette.pillInk)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(unknown ? Color.clear : Palette.pill, in: Capsule())
        .overlay {
            if unknown {
                Capsule().strokeBorder(Palette.ink3, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .padding(.vertical, 3)
    }
}
