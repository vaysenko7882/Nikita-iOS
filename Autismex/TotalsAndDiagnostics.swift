import SwiftUI

struct TotalsCard: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState

    var body: some View {
        let total = store.liveMetrics(at: Date()).total

        VStack(alignment: .leading, spacing: 0) {
            Text("За всё время в сети")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink2)
            Text(Fmt.duration(total.online))
                .font(.rounded(46))
                .tracking(-1.4)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
            Rectangle()
                .fill(Palette.hair)
                .frame(height: 1)
                .padding(.top, 20)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    stat(String(Int(total.sessions)), "сеансы")
                    stat(String(Int(total.pauses)), "паузы")
                }
                GridRow {
                    stat(Fmt.duration(total.maxSession), "самый долгий сеанс")
                    stat(Fmt.duration(total.maxPause), "самая долгая пауза")
                }
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.rounded(22))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Связь с Telegram. В свёрнутом виде не тикает; секундные «N с назад» идут только когда раскрыта.
struct DiagnosticsCard: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    @Binding var isOpen: Bool
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text("Связь с Telegram")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(sourceName(state.health?.source))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 22)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Rectangle().fill(Palette.hair).frame(height: 1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    details(now: store.serverNow(at: context.date))
                }
                .transition(.opacity)
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func details(now: Double) -> some View {
        let health = state.health
        let sources = (health?.sources ?? [:]).values.sorted { ($0.source ?? "") < ($1.source ?? "") }
        return VStack(alignment: .leading, spacing: 16) {
            Text(health?.message ?? "Ждём подтверждение")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    field("Наблюдаем с", trackingText)
                    field("Подтверждено", confirmedText)
                }
                GridRow {
                    field("Сессия наблюдателя", health?.observer ?? "проверяем")
                    field("Сверка", age(health?.lastPoll, now: now))
                }
                GridRow {
                    field("Событие Telegram", age(health?.lastPush, now: now))
                    field("Интервал и ответ", rateText(health))
                }
                GridRow {
                    field("Цель в контактах", contactText(health))
                    field("Тип статуса", health?.rawType ?? "ещё не получен")
                }
            }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        Text(sourceLine(source, now: now))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Если Telegram открыт, а здесь офлайн, проверь видимость «Последний визит и в сети» между своими аккаунтами.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onCopy) {
                Text("Скопировать диагностику")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Palette.page, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 16, leading: 22, bottom: 22, trailing: 22))
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
            Text(value)
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackingText: String {
        guard let started = state.trackingStarted else { return "—" }
        return Fmt.dayText(Fmt.isoDay(started, tz: state.tz), "d MMM") + ", " + Fmt.time(started, tz: state.tz)
    }

    private var confirmedText: String {
        guard let observed = state.current.lastObserved else { return "ожидаем Telegram" }
        return "в " + Fmt.time(observed, tz: state.tz, seconds: true)
    }

    private func sourceName(_ source: String?) -> String {
        switch source {
        case "push": return "Событие Telegram"
        case "users": return "users.getUsers"
        case "contacts": return "contacts.getStatuses"
        default: return source ?? "нет источника"
        }
    }

    private func age(_ timestamp: Double?, now: Double) -> String {
        guard let timestamp else { return "ещё не было" }
        return Fmt.duration(now - timestamp, detailed: true) + " назад"
    }

    private func rateText(_ health: Health?) -> String {
        let poll = String(Int(health?.pollSeconds ?? 1)) + " с"
        guard let latency = health?.rpcLatencyMs else { return poll }
        return poll + ", " + String(Int(latency)) + " мс"
    }

    private func contactText(_ health: Health?) -> String {
        guard let contact = health?.contact else { return "не проверено" }
        if !contact { return "нет" }
        return health?.mutualContact == true ? "да, взаимно" : "да"
    }

    private func sourceLine(_ source: SourceInfo, now: Double) -> String {
        var line = sourceName(source.source) + ": " + (source.type ?? "—") + ", " + age(source.receivedAt, now: now)
        if let lastSeen = source.lastSeen { line += ", Last Seen " + Fmt.time(lastSeen, tz: state.tz, seconds: true) }
        if source.byMe == true { line += ", ограничение by_me" }
        return line
    }
}
