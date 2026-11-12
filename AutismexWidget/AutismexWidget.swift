import WidgetKit
import SwiftUI

// Виджеты читают тот же /api/state напрямую — общий контейнер приложений не нужен.
// Приложение обновляет их, когда статус меняется, пока оно открыто.

struct WidgetSnapshot {
    var state: String
    var since: Double
    var online: Double
    var sessions: Int
    var segments: [DialSegment]
    var dayStart: Double
    var dayEnd: Double
    var serverNow: Double
    var updated: Date
    var tz: TimeZone

    init(state: String, since: Double, online: Double, sessions: Int, segments: [DialSegment],
         dayStart: Double, dayEnd: Double, serverNow: Double, updated: Date, tz: TimeZone) {
        self.state = state
        self.since = since
        self.online = online
        self.sessions = sessions
        self.segments = segments
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.serverNow = serverNow
        self.updated = updated
        self.tz = tz
    }

    init(_ presence: PresenceState) {
        let current = presence.health?.selfSession == true ? "unknown" : (presence.current.state ?? "unknown")
        state = current
        if current == "offline" {
            since = presence.current.pauseSince ?? presence.current.since ?? presence.now
        } else {
            since = presence.current.since ?? presence.now
        }
        online = presence.day.onlineSeconds ?? 0
        sessions = Int(presence.day.sessionCount ?? 0)
        segments = presence.rows.map { DialSegment(state: $0.state, start: $0.start, end: $0.end) }
        dayStart = presence.dayStart
        dayEnd = presence.dayEnd
        serverNow = presence.now
        updated = Date()
        tz = presence.tz
    }

    var sinceDate: Date { Date(timeIntervalSince1970: since) }

    static var sample: WidgetSnapshot {
        let now = Date().timeIntervalSince1970
        let start = now - 18.8 * 3600
        let sessions: [(Double, Double)] = [(8.25, 8.55), (10.4, 10.8), (12.7, 12.95), (14.1, 14.8), (16.5, 16.8), (18.7, 18.8)]
        var segments: [DialSegment] = []
        var cursor = start
        for (from, to) in sessions {
            segments.append(DialSegment(state: "offline", start: cursor, end: start + from * 3600))
            segments.append(DialSegment(state: "online", start: start + from * 3600, end: start + to * 3600))
            cursor = start + to * 3600
        }
        return WidgetSnapshot(state: "online", since: now - 224, online: 6_960, sessions: 6, segments: segments,
                              dayStart: start, dayEnd: start + 86_400, serverNow: now, updated: Date(),
                              tz: TimeZone(identifier: "Europe/Moscow") ?? .current)
    }
}

struct PresenceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct PresenceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PresenceEntry {
        PresenceEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PresenceEntry) -> Void) {
        if context.isPreview {
            completion(PresenceEntry(date: Date(), snapshot: .sample))
            return
        }
        Task {
            let entry = await load()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PresenceEntry>) -> Void) {
        Task {
            let entry = await load()
            let next = Date().addingTimeInterval(entry.snapshot == nil ? 5 * 60 : 15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load() async -> PresenceEntry {
        do {
            let presence = try await PresenceAPI().state(date: nil)
            return PresenceEntry(date: Date(), snapshot: WidgetSnapshot(presence))
        } catch {
            return PresenceEntry(date: Date(), snapshot: nil)
        }
    }
}

// MARK: Виды

struct WidgetDial: View {
    let snapshot: WidgetSnapshot
    var labels = false
    var ticks = true

    var body: some View {
        Canvas { context, size in
            DialPainter.paint(&context, size: size, segments: snapshot.segments, dayStart: snapshot.dayStart, dayEnd: snapshot.dayEnd,
                              showLabels: labels, showTicks: ticks, knobAt: snapshot.serverNow, knobState: snapshot.state)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct WidgetStateLine: View {
    let snapshot: WidgetSnapshot
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Palette.state(snapshot.state))
                .frame(width: size * 0.55, height: size * 0.55)
            Text(Labels.state(snapshot.state))
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(Palette.ink2)
    }
}

struct SmallPresenceView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack {
            WidgetDial(snapshot: snapshot)
            VStack(spacing: 1) {
                WidgetStateLine(snapshot: snapshot, size: 10)
                Text(Fmt.duration(snapshot.online))
                    .font(.rounded(17))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("сегодня")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.ink2)
            }
            .frame(width: 78)
        }
    }
}

struct MediumPresenceView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 16) {
            WidgetDial(snapshot: snapshot)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Palette.state(snapshot.state))
                        .frame(width: 10, height: 10)
                    Text(Labels.state(snapshot.state))
                        .font(.rounded(22))
                        .foregroundStyle(Palette.ink)
                }
                if snapshot.state == "online" || snapshot.state == "offline" {
                    (Text(snapshot.state == "online" ? "онлайн " : "пауза ") + Text(snapshot.sinceDate, style: .timer))
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink2)
                } else {
                    Text("статус скрыт или устарел")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 4)
                Text("Сегодня в сети")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                Text(Fmt.duration(snapshot.online))
                    .font(.rounded(22))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(String(snapshot.sessions) + " " + Fmt.plural(snapshot.sessions, "сеанс", "сеанса", "сеансов") + " · обновлено " + Fmt.time(snapshot.updated.timeIntervalSince1970, tz: snapshot.tz))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CircularPresenceView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            WidgetDial(snapshot: snapshot, labels: false, ticks: false)
                .padding(2)
            Text(Fmt.compactMinutes(snapshot.online / 60))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: 36)
        }
        .widgetAccentable()
    }
}

struct RectangularPresenceView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: snapshot.state == "online" ? "circle.fill" : (snapshot.state == "offline" ? "moon.fill" : "questionmark.circle"))
                    .font(.system(size: 10, weight: .bold))
                Text(Labels.state(snapshot.state))
                    .font(.headline)
            }
            .widgetAccentable()
            if snapshot.state == "online" || snapshot.state == "offline" {
                (Text(snapshot.state == "online" ? "онлайн " : "пауза ") + Text(snapshot.sinceDate, style: .timer))
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            Text("Сегодня " + Fmt.duration(snapshot.online))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PresenceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PresenceEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium:
                MediumPresenceView(snapshot: snapshot)
            case .accessoryCircular:
                CircularPresenceView(snapshot: snapshot)
            case .accessoryRectangular:
                RectangularPresenceView(snapshot: snapshot)
            case .accessoryInline:
                Text(Labels.state(snapshot.state) + " · " + Fmt.duration(snapshot.online) + " сегодня")
            default:
                SmallPresenceView(snapshot: snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 18, weight: .semibold))
                Text("Нет связи")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Palette.ink2)
        }
    }
}

struct PresenceWidget: Widget {
    let kind = "AutismexPresence"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PresenceProvider()) { entry in
            PresenceWidgetView(entry: entry)
                .containerBackground(Palette.page, for: .widget)
        }
        .configurationDisplayName("Присутствие")
        .description("Статус и время онлайн за сегодня.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct AutismexWidgetBundle: WidgetBundle {
    var body: some Widget {
        PresenceWidget()
    }
}
