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

        verifyCatchupBatch()
        verifyLazyArchiveAttribute()
        let empty = roundTrip(NikitaRemoteArchiveState())
        require(empty.pendingVersions.isEmpty && empty.cursor == 0, "Empty state changed")

        let first = DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(8123456789), namespace: 9, id: 17))
        let second = DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(8123456789), namespace: 9, id: 18))
        var populated = NikitaRemoteArchiveState()
        populated.endpoint = "https://archive.example.invalid/"
        populated.serverId = "stable-epoch"
        populated.cursor = 9876543210
        populated.mediaRevision = 1
        populated.pendingVersions = ["8123456789:42": [first, second], "other:7": []]
        let restored = roundTrip(populated)
        require(restored.endpoint == populated.endpoint && restored.serverId == populated.serverId,
            "Endpoint or server identity changed")
        require(restored.cursor == populated.cursor && restored.pendingVersions == populated.pendingVersions,
            "Cursor or pending revision references changed")
        require(roundTrip(restored).pendingVersions == populated.pendingVersions, "Second startup failed")
        require(restored.mediaRevision == 1, "Media replay migration marker changed")

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
        declareEncodable(NikitaArchiveMediaResource.self, f: { NikitaArchiveMediaResource(decoder: $0) })
        let resource = NikitaArchiveMediaResource(accountId: 42, serverId: "stable-epoch", blobId: String(repeating: "a", count: 64),
            size: 5 * 1024 * 1024 * 1024, sha256: String(repeating: "b", count: 64))
        let resourceEncoder = PostboxEncoder()
        resourceEncoder.encodeRootObject(resource)
        let resourceData = resourceEncoder.makeData()
        let decoded = PostboxDecoder(buffer: MemoryBuffer(data: resourceData)).decodeRootObject() as? NikitaArchiveMediaResource
        require(decoded?.id == resource.id && decoded?.size == resource.size && decoded?.sha256 == resource.sha256,
            "VPS media identity/64-bit size/hash failed actual Postbox round-trip")
        require(decoded?.isValid == true && decoded?.streamable == true, "Valid media resource became unusable")
        let other = NikitaArchiveMediaResource(accountId: 43, serverId: resource.serverId, blobId: resource.blobId, size: 12, sha256: "")
        require(other.id != resource.id, "Resources from separate accounts must not share cached bytes")
        let invalid = NikitaArchiveMediaResource(accountId: 42, serverId: "../../config", blobId: resource.blobId, size: 12, sha256: "")
        require(!invalid.isValid, "Path-shaped epochs must not enter MediaBox filenames")
        print("Archive state: empty/populated/repeated-startup round-trips and legacy migration passed.")
        print("VPS media resource: actual Postbox round-trip, large size, account isolation and invalid identity checks passed.")
    }
}

private func verifyLazyArchiveAttribute() {
    let original = MessageId(peerId: PeerId(123), namespace: 0, id: 42)
    let versions = (1 ... 10_000).map {
        MessageId(peerId: original.peerId, namespace: 10, id: Int32($0))
    }
    let attribute = ArchivedMessageAttribute(originalMessageId: original, versionIds: versions,
        deletedAt: 77, sessionId: 999)
    declareEncodable(ArchivedMessageAttribute.self, f: { ArchivedMessageAttribute(decoder: $0) })
    let encoder = PostboxEncoder()
    encoder.encodeRootObject(attribute)
    let decoder = PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData()))
    guard let restored = decoder.decodeRootObject() as? ArchivedMessageAttribute else {
        fatalError("Archived message attribute failed actual Postbox round-trip")
    }
    require(restored.originalMessageId == original && restored.versionIds == versions &&
        restored.deletedAt == 77 && restored.sessionId == 999,
        "Lazy archive rendering must preserve all stored revision metadata")
    require(restored.associatedMessageIds.isEmpty,
        "Stored revisions must not become eager associations during normal message rendering")
    print("Archive attribute: revision_ids=10000, implicit_revision_links=0; metadata preserved by the actual Postbox codec. Database-render timings run in TelegramCoreTests.")
}



private func verifyCatchupBatch() {
    let first = DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(123), namespace: 9, id: 1))
    var persistedIndex = DeletedMessageArchiveIndex(messageIds: [first], liveMessageIds: [first])
    var persistedState = NikitaRemoteArchiveState()
    persistedState.pendingVersions = ["123:7": [first], "another-account:9": [first]]
    var settingsReads = 0, indexReads = 0, stateReads = 0
    var indexWrites = 0, stateWrites = 0, sweeps = 0
    var initialized = false
    let batch = DeletedMessageArchiveBatch(loadSettings: {
        settingsReads += 1; initialized = true; return .defaultSettings
    }, loadIndex: {
        precondition(initialized, "Session initialization must precede index snapshot")
        indexReads += 1; return persistedIndex
    }, saveIndex: { value in
        indexWrites += 1
        // The same production Codable declaration and actual Postbox codec.
        persistedIndex = PreferencesEntry(value)!.get(DeletedMessageArchiveIndex.self)!
    }, loadRemoteState: {
        stateReads += 1; return roundTrip(persistedState)
    }, saveRemoteState: { state in stateWrites += 1; persistedState = roundTrip(state) }, retainMedia: { _, index in
        sweeps += 1; precondition(index == persistedIndex, "Retention ran on stale metadata")
    })
    // A local removal may be the first replay operation, before an edit calls prepare.
    batch.updateIndex { $0.liveMessageIds.removeAll() }
    var expected = [first]
    for number in 2 ... 10_001 {
        precondition(batch.settings != nil)
        precondition(batch.takePendingVersions(for: "missing") == nil)
        let entry = DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(123), namespace: 9, id: Int32(number)))
        expected.append(entry)
        batch.updateIndex { $0.messageIds.append(entry) }
        batch.requestMediaRetention()
    }
    precondition(batch.takePendingVersions(for: "123:7") == [first])
    precondition(batch.takePendingVersions(for: "123:7") == nil)
    precondition(indexWrites == 0 && stateWrites == 0 && sweeps == 0, "Work leaked out of transaction batch")
    batch.finish(); batch.finish()
    precondition(persistedIndex.messageIds == expected && persistedIndex.liveMessageIds.isEmpty)
    precondition(persistedState.pendingVersions == ["another-account:9": [first]])
    precondition(settingsReads == 1 && indexReads == 1 && stateReads == 1)
    precondition(indexWrites == 1 && stateWrites == 1 && sweeps == 1)
    var nilReads = 0
    let absent = DeletedMessageArchiveBatch(loadSettings: { nilReads += 1; return nil },
        loadIndex: { fatalError("Empty batch read index") }, saveIndex: { _ in fatalError("Unexpected index write") },
        loadRemoteState: { nilReads += 1; return nil }, saveRemoteState: { _ in fatalError("Unexpected state write") },
        retainMedia: { _, _ in fatalError("Unexpected retention sweep") })
    for _ in 0 ..< 100 { precondition(absent.settings == nil && absent.takePendingVersions(for: "none") == nil) }
    absent.finish(); absent.finish()
    precondition(nilReads == 2, "Missing settings/state must be cached within the transaction")
    print("Catch-up: 10,000 edits preserve index/revisions through the real Postbox codec, with one settings/index/state read, one index/state write and one retention sweep. Nil caching and idempotent finish passed.")
}
