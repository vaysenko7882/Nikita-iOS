import Foundation

private struct LegacyArchiveState: Codable {
    var endpoint: String
    var serverId: String
    var cursor: Int64
    var pendingVersions: [String: [DeletedMessageArchiveIndexEntry]]
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func roundTrip(_ state: NikitaRemoteArchiveState) -> NikitaRemoteArchiveState {
    guard let entry = PreferencesEntry(state), let result = entry.get(NikitaRemoteArchiveState.self) else {
        fatalError("Archive state failed to round-trip through PreferencesEntry")
    }
    return result
}

@main
enum ArchiveStateCheck {
    static func main() throws {
        if CommandLine.arguments.contains("--legacy-crash") {
            let old = LegacyArchiveState(endpoint: "https://example.invalid", serverId: "epoch", cursor: 0,
                pendingVersions: [:])
            let entry = PreferencesEntry(old)!
            print("legacy-state-encoded; entering Dictionary decoding")
            fflush(stdout)
            let decoded = entry.get(LegacyArchiveState.self)
            exit(decoded == nil ? 3 : 0)
        }

        let empty = roundTrip(NikitaRemoteArchiveState())
        require(empty.pendingVersions.isEmpty && empty.cursor == 0, "Empty state changed")

        let first = DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(8123456789), namespace: 9, id: 17))
        let second = DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(8123456789), namespace: 9, id: 18))
        var populated = NikitaRemoteArchiveState()
        populated.endpoint = "https://archive.example.invalid/"
        populated.serverId = "stable-epoch"
        populated.cursor = 9876543210
        populated.pendingVersions = ["8123456789:42": [first, second], "other:7": []]
        let restored = roundTrip(populated)
        require(restored.endpoint == populated.endpoint && restored.serverId == populated.serverId,
            "Endpoint or server identity changed")
        require(restored.cursor == populated.cursor && restored.pendingVersions == populated.pendingVersions,
            "Cursor or pending revision references changed")
        require(roundTrip(restored).pendingVersions == populated.pendingVersions, "Second startup failed")

        for pending in [[String: [DeletedMessageArchiveIndexEntry]](), ["8123456789:42": [first]]] {
            let old = LegacyArchiveState(endpoint: populated.endpoint, serverId: "legacy-epoch", cursor: 57,
                pendingVersions: pending)
            guard let entry = PreferencesEntry(old), let migrated = entry.get(NikitaRemoteArchiveState.self) else {
                fatalError("Legacy state could not be migrated")
            }
            require(migrated.endpoint == old.endpoint, "Migration lost the endpoint")
            require(migrated.cursor == 0 && migrated.serverId.isEmpty && migrated.pendingVersions.isEmpty,
                "Legacy migration must replay the journal without decoding the broken map")
            require(roundTrip(migrated).pendingVersions.isEmpty, "Migrated state failed on next startup")
        }

        let minimal = Data("{}".utf8)
        let defaults = try JSONDecoder().decode(NikitaRemoteArchiveState.self, from: minimal)
        require(defaults.endpoint.isEmpty && defaults.pendingVersions.isEmpty, "Missing fields need safe defaults")
        let encoded = try JSONEncoder().encode(populated)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        require(object["pendingVersions"] == nil && object["pendingVersionEntries"] is [Any],
            "The legacy String-key dictionary must never be written again")
        print("Archive state: empty/populated/repeated-startup round-trips and legacy migration passed.")
    }
}
