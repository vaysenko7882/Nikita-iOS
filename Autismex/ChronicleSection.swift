import SwiftUI

/// Хроника дня в виде переписки: сеансы онлайн — исходящие сообщения,
/// чем дольше сеанс, тем шире пузырь; паузы и пропуски — служебные плашки.
struct ChronicleSection: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    @State private var filter: ChronicleFilter = .all
    @State private var limit = 7
    @State private var width: CGFloat = 0

    var body: some View {
        let all = state.rows.filter { filter == .all || $0.state == filter.rawValue }
        let shown = Array(all.suffix(limit))
        let longest = max(1, shown.filter { $0.state == "online" }.map { $0.duration }.max() ?? 1)
        let hidden = all.count - shown.count

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: "Хроника дня",
                subtitle: Fmt.dayText(state.date, "d MMMM") + " · только наблюдаемые отрезки; максимум пауз выше учитывает Last Seen"
            )
            Picker("Фильтр", selection: $filter) {
                ForEach(ChronicleFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 7) {
                if hidden > 0 {
                    Button {
                        withAnimation(.snappy) { limit += 20 }
                    } label: {
                        Text("Показать раньше · ещё " + String(hidden))
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
                    ServicePill(text: "Таких наблюдений за этот день пока нет")
                }
                ForEach(shown) { row in
                    item(row, longest: longest)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 12, bottom: 20, trailing: 12))
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width - 24 }
                        .onChange(of: proxy.size.width) { _, newWidth in width = newWidth - 24 }
                }
            )
            .background(ChatWallpaper())
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.top, 14)
        }
        .onChange(of: state.date) { _, _ in limit = 7 }
        .onChange(of: filter) { _, _ in limit = 7 }
    }

    private var dayLabel: String {
        let relative = Fmt.relative(state.date, today: state.today).map { $0 + ", " } ?? ""
        return relative + Fmt.dayText(state.date, "d MMMM")
    }

    @ViewBuilder
    private func item(_ row: Interval, longest: Double) -> some View {
        let live = row.isOngoing && state.isToday
        let range = Fmt.time(row.start, tz: state.tz) + " – " + (live ? "сейчас" : Fmt.time(row.end, tz: state.tz))
        if row.state == "online" {
            let fraction = CGFloat(0.54 + 0.38 * (row.duration / longest).squareRoot())
            let bubbleWidth: CGFloat? = width > 0 ? max(150, min(width - 4, width * fraction)) : nil
            MessageBubble(row: row, range: range, live: live, width: bubbleWidth)
        } else {
            PausePill(row: row, range: range, live: live)
        }
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var store: PresenceStore
    let row: Interval
    let range: String
    let live: Bool
    let width: CGFloat?

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
            if live {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    durationText(store.liveEnd(row, at: context.date) - row.start)
                }
            } else {
                durationText(row.duration)
            }
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
        .background(
            BubbleShape()
                .fill(Palette.bubble)
                .shadow(color: .black.opacity(0.07), radius: 0.8, x: 0, y: 1)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("В сети " + Fmt.duration(row.duration, detailed: true) + ", " + range))
    }

    private func durationText(_ seconds: Double) -> some View {
        Text(Fmt.duration(seconds, detailed: true))
            .font(.rounded(19))
            .monospacedDigit()
            .foregroundStyle(Palette.ink)
            .contentTransition(.numericText())
    }
}

struct PausePill: View {
    @EnvironmentObject private var store: PresenceStore
    let row: Interval
    let range: String
    let live: Bool

    var body: some View {
        let word = row.state == "offline" ? "Пауза " : "Нет данных "
        let unknown = row.state == "unknown"
        Group {
            if live {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(word, Fmt.duration(store.liveEnd(row, at: context.date) - row.start, detailed: true))
                }
            } else {
                label(word, Fmt.duration(row.duration, detailed: true))
            }
        }
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

    private func label(_ word: String, _ duration: String) -> some View {
        let tail = ", " + range + (row.isContinued ? ", с прошлого дня" : "")
        return (Text(word) + Text(duration).fontWeight(.semibold).foregroundColor(Palette.ink) + Text(tail))
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(Palette.pillInk)
            .multilineTextAlignment(.center)
    }
}
