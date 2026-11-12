import SwiftUI

struct TotalsCard: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = store.liveMetrics(at: context.date).total
            VStack(alignment: .leading, spacing: 0) {
                Text("За всё время")
                    .font(.rounded(20))
                    .foregroundStyle(Palette.ink)
                Text(Fmt.duration(total.online))
                    .font(.rounded(46))
                    .tracking(-1.4)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .padding(.top, 14)
                Text("наблюдаемого онлайна")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
                    .padding(.top, 6)
                Rectangle()
                    .fill(Palette.hair)
                    .frame(height: 1)
                    .padding(.top, 22)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 20) {
                    GridRow {
                        stat(String(Int(total.sessions)), "онлайн-сеансы")
                        stat(String(Int(total.pauses)), "паузы")
                    }
                    GridRow {
                        stat(Fmt.duration(total.maxPause), "самая долгая пауза")
                        stat(Fmt.percent(total.coverage), "покрытие наблюдениями")
                    }
                }
                .padding(.top, 20)
                Text("История копится с момента первого запуска.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .padding(.top, 20)
            }
            .padding(EdgeInsets(top: 24, leading: 22, bottom: 22, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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

struct DiagnosticsCard: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    @Binding var isOpen: Bool
    var onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = store.serverNow(at: context.date)
            let health = state.health
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Связь с Telegram")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Text(summary(health, now: now))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    Rectangle().fill(Palette.hair).frame(height: 1)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(health?.message ?? "Ждём подтверждение")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                            GridRow {
                                field("Сессия наблюдателя", health?.observer ?? "Проверяем")
                                field("Последняя сверка", age(health?.lastPoll, now: now) + " · " + String(Int(health?.pollCount ?? 0)) + " ответов")
                            }
                            GridRow {
                                field("События Telegram", age(health?.lastPush, now: now) + " · " + String(Int(health?.pushCount ?? 0)) + " событий")
                                field("Интервал / ответ API", rateText(health))
                            }
                            GridRow {
                                field("Цель в контактах", contactText(health))
                                field("Полученный тип статуса", health?.rawType ?? "ещё не получен")
                            }
                        }
                        let sources = (health?.sources ?? [:]).values.sorted { ($0.source ?? "") < ($1.source ?? "") }
                        if !sources.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                                    Text(sourceLine(source, now: now))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Text("Если на телефоне открыт Telegram, а здесь офлайн, проверь видимость «Последний визит и в сети» между своими аккаунтами. Панель показывает ответы API, а не активность отдельного устройства.")
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
                    .transition(.opacity)
                }
            }
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
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

    private func sourceName(_ source: String?) -> String {
        switch source {
        case "push": return "Событие Telegram"
        case "users": return "users.getUsers"
        case "contacts": return "contacts.getStatuses"
        default: return source ?? "Нет источника"
        }
    }

    private func age(_ timestamp: Double?, now: Double) -> String {
        guard let timestamp else { return "ещё не получены" }
        return Fmt.duration(now - timestamp, detailed: true) + " назад"
    }

    private func summary(_ health: Health?, now: Double) -> String {
        guard let health else { return "Ждём первый ответ" }
        let latest = health.source.flatMap { health.sources?[$0] }
        let tail = latest.map { age($0.receivedAt, now: now) } ?? (health.mode ?? "—")
        return sourceName(health.source) + " · " + tail
    }

    private func rateText(_ health: Health?) -> String {
        let poll = String(Int(health?.pollSeconds ?? 1)) + " с"
        guard let latency = health?.rpcLatencyMs else { return poll + " / —" }
        return poll + " / " + String(Int(latency)) + " мс"
    }

    private func contactText(_ health: Health?) -> String {
        guard let contact = health?.contact else { return "не проверено" }
        if !contact { return "нет" }
        return health?.mutualContact == true ? "да, взаимно" : "да"
    }

    private func sourceLine(_ source: SourceInfo, now: Double) -> String {
        var line = sourceName(source.source) + " · " + (source.type ?? "—") + " · " + age(source.receivedAt, now: now)
        if let lastSeen = source.lastSeen { line += " · Last Seen " + Fmt.time(lastSeen, tz: state.tz, seconds: true) }
        if source.byMe == true { line += " · ограничение by_me" }
        return line
    }
}
