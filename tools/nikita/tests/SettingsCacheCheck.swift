import Foundation

private struct CountedSettings: Codable, Equatable {
    static var decodes = 0
    var peers: Set<Int64>
    init(peers: Set<Int64>) { self.peers = peers }
    init(from decoder: Decoder) throws {
        Self.decodes += 1
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.peers = try container.decode(Set<Int64>.self, forKey: .peers)
    }
}

@main enum SettingsCacheCheck {
    static func main() throws {
        let initial = CountedSettings(peers: Set((0 ..< 10000).map(Int64.init)))
        let data = try JSONEncoder().encode(initial)
        var cache = CodeGramSettingsCache(defaultValue: CountedSettings(peers: []), data: data)
        precondition(cache.value == initial && CountedSettings.decodes == 1)

        // A chat list repeatedly asks for the same filters while laying out
        // different rows. Equal bytes (including a new Data allocation) must
        // not reconstruct the entire 10,000-peer set for each row.
        for _ in 0 ..< 1000 { cache.reload(data: Data(Array(data))) }
        precondition(CountedSettings.decodes == 1)

        let external = CountedSettings(peers: [22, 33])
        cache.reload(data: try JSONEncoder().encode(external))
        precondition(cache.value == external && CountedSettings.decodes == 2)

        let invalid = Data("{\"peers\":\"invalid\"}".utf8)
        cache.reload(data: invalid)
        for _ in 0 ..< 1000 { cache.reload(data: invalid) }
        precondition(cache.value == external && CountedSettings.decodes == 3)
        cache.reload(data: nil)
        precondition(cache.value == external)

        let local = CountedSettings(peers: [44])
        let stored = cache.store(local)
        precondition(stored != nil)
        cache.reload(data: stored)
        precondition(cache.value == local && CountedSettings.decodes == 3)
        cache.reload(data: data)
        precondition(cache.value == initial && CountedSettings.decodes == 4)
        print("Settings cache: unchanged rows decode once; external edits, malformed values and local writes passed.")
    }
}
