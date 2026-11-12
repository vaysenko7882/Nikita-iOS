import Foundation

struct PresenceSnapshot: Decodable {
    let now: Double
    let timezone: String
    let today: String
    let date: String
    let trackingStarted: Double
    let profile: Profile
    let current: Current
    let day: Day
    let total: Metrics
    let history: [HistoryDay]
    let intervals: [Interval]
    let heatmap: [HeatmapDay]
    let health: Health
    let demo: Bool?
}

struct Profile: Decodable {
    let id: Int64
    let username: String?
    let name: String?
    let avatarVersion: String?
}
struct Current: Decodable {
    let state: String
    let since: Double
    let reason: String?
    let validUntil: Double?
    let lastObserved: Double?
    let lastSeen: Double?
    let pauseSince: Double?
    let pauseSource: String?
}
struct Metrics: Decodable {
    let onlineSeconds: Double
    let offlineSeconds: Double
    let unknownSeconds: Double
    let sessionCount: Int
    let pauseCount: Int
    let maxPauseSeconds: Double
    let coveragePercent: Double
}
struct Day: Decodable {
    let start: Double
    let end: Double
    let observedUntil: Double
    let onlineSeconds: Double
    let offlineSeconds: Double
    let unknownSeconds: Double
    let sessionCount: Int
    let pauseCount: Int
    let maxPauseSeconds: Double
    let coveragePercent: Double
}
struct HistoryDay: Decodable {
    let date: String
    let onlineSeconds: Double
    let offlineSeconds: Double
    let unknownSeconds: Double
    let sessionCount: Int
    let pauseCount: Int
    let maxPauseSeconds: Double
    let coveragePercent: Double
}
struct Interval: Decodable {
    let id: Int?
    let state: String
    let start: Double
    let end: Double
    let duration: Double
    let reason: String?
    let ongoing: Bool
}
struct Health: Decodable {
    let connected: Bool
    let mode: String
    let message: String?
    let pollSeconds: Double?
    let rpcLatencyMs: Double?
    let selfSession: Bool?
}
struct HeatmapDay: Decodable {
    let date: String
    let cells: [HeatCell]
}
struct HeatCell: Decodable {
    let hour: Int
    let onlineMinutes: Double
    let knownMinutes: Double
}
