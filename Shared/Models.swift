import Foundation

// Ответ GET /api/state. Ключи приходят в snake_case и переводятся декодером
// (.convertFromSnakeCase). Почти всё опционально, чтобы мелкие изменения
// сервера не роняли приложение.

struct PresenceState: Decodable, Sendable {
    var now: Double
    var timezone: String?
    var today: String
    var date: String
    var trackingStarted: Double?
    var profile: Profile?
    var current: Current
    var day: Metrics
    var total: Metrics?
    var intervals: [Interval]?
    var history: [Metrics]?
    var heatmap: [HeatmapDay]?
    var health: Health?
    var demo: Bool?

    var tz: TimeZone { TimeZone(identifier: timezone ?? "Europe/Moscow") ?? TimeZone(secondsFromGMT: 3 * 3600) ?? .current }
    var rows: [Interval] { intervals ?? [] }
    var isToday: Bool { date == today }
    var dayStart: Double { day.start ?? now }
    var dayEnd: Double { day.end ?? (dayStart + 86_400) }
}

struct Profile: Decodable, Sendable {
    var id: String
    var username: String?
    var name: String?
    var hasAvatar: Bool?
    var avatarVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name, hasAvatar, avatarVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int64.self, forKey: .id) {
            id = String(number)
        } else if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = ""
        }
        username = try? container.decodeIfPresent(String.self, forKey: .username)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        hasAvatar = try? container.decodeIfPresent(Bool.self, forKey: .hasAvatar)
        if let text = try? container.decodeIfPresent(String.self, forKey: .avatarVersion) {
            avatarVersion = text
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .avatarVersion) {
            avatarVersion = String(Int64(number))
        } else {
            avatarVersion = nil
        }
    }

    var handle: String {
        guard let username, !username.isEmpty else { return "Без username" }
        return username.hasPrefix("@") ? username : "@" + username
    }
}

struct Current: Decodable, Sendable {
    var state: String?
    var since: Double?
    var reason: String?
    var source: String?
    var validUntil: Double?
    var lastObserved: Double?
    var lastSeen: Double?
    var pauseSince: Double?
    var pauseSource: String?
}

struct Metrics: Decodable, Sendable {
    var date: String?
    var start: Double?
    var end: Double?
    var onlineSeconds: Double?
    var offlineSeconds: Double?
    var unknownSeconds: Double?
    var sessionCount: Double?
    var pauseCount: Double?
    var maxSessionSeconds: Double?
    var maxPauseSeconds: Double?
    var averageSessionSeconds: Double?
    var coveragePercent: Double?
    var observedMaxPauseSeconds: Double?
    var maxPauseSource: String?
}

extension Metrics {
    init() {}
}

struct Interval: Decodable, Identifiable, Equatable, Sendable {
    var state: String
    var start: Double
    var end: Double
    var duration: Double
    var reason: String?
    var ongoing: Bool?
    var continued: Bool?

    var id: Double { start }
    var isOngoing: Bool { ongoing ?? false }
    var isContinued: Bool { continued ?? false }
}

struct HeatmapDay: Decodable, Sendable {
    var date: String
    var cells: [HeatCell]
}

struct HeatCell: Decodable, Sendable {
    var hour: Int
    var onlineMinutes: Double?
    var knownMinutes: Double?

    var online: Double { onlineMinutes ?? 0 }
    var known: Double { knownMinutes ?? 0 }
}

struct Health: Decodable, Sendable {
    var mode: String?
    var connected: Bool?
    var message: String?
    var lastPoll: Double?
    var pollSeconds: Double?
    var selfSession: Bool?
    var observer: String?
    var contact: Bool?
    var mutualContact: Bool?
    var source: String?
    var rawType: String?
    var lastPush: Double?
    var pushCount: Double?
    var pollCount: Double?
    var rpcLatencyMs: Double?
    var sources: [String: SourceInfo]?
}

struct SourceInfo: Decodable, Sendable {
    var source: String?
    var type: String?
    var receivedAt: Double?
    var lastSeen: Double?
    var byMe: Bool?
}
