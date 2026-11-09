import Foundation
import Postbox
import SwiftSignalKit
@testable import TelegramCore
import XCTest

/// Counts actual stored-message decoding, rather than timing a policy helper.
private final class UnrelatedArchiveProbeAttribute: MessageAttribute {
    static let reads = Atomic<Int>(value: 0)
    static let onNextDecode = Atomic<(() -> Void)?>(value: nil)
    static let register: Void = {
        declareEncodable(UnrelatedArchiveProbeAttribute.self, f: { UnrelatedArchiveProbeAttribute(decoder: $0) })
    }()
    init() {}
    required init(decoder: PostboxDecoder) {
        let _ = Self.reads.modify { $0 + 1 }
        Self.onNextDecode.swap(nil)?()
    }
    func encode(_ encoder: PostboxEncoder) {}
}

/// Reproduces the pre-14.7 archive association contract without changing Postbox.
/// Both benchmark arms use the production renderer and the same stored revisions.
private final class EagerArchiveRevisionLinksAttribute: MessageAttribute {
    static let register: Void = {
        declareEncodable(EagerArchiveRevisionLinksAttribute.self, f: { EagerArchiveRevisionLinksAttribute(decoder: $0) })
    }()
    let versionIds: [MessageId]
    var associatedMessageIds: [MessageId] { self.versionIds }
    init(versionIds: [MessageId]) { self.versionIds = versionIds }
    required init(decoder: PostboxDecoder) {
        self.versionIds = decoder.decodeDataForKey("v").map(MessageId.decodeArrayFromData) ?? []
    }
    func encode(_ encoder: PostboxEncoder) {
        encoder.encodeData(MessageId.encodeArrayToData(self.versionIds), forKey: "v")
    }
}

private let archiveBenchmarkSeedConfiguration: SeedConfiguration = {
    let seed = telegramPostboxSeedConfiguration
    // Telegram uses server-side cloud search and indexes only secret chats in
    // local FTS. Index this fixture's cloud peer so the benchmark can exercise
    // the real Postbox search renderer with a non-empty result, without a server.
    return SeedConfiguration(globalMessageIdsPeerIdNamespaces: seed.globalMessageIdsPeerIdNamespaces,
        initializeChatListWithHole: seed.initializeChatListWithHole, messageHoles: seed.messageHoles,
        upgradedMessageHoles: seed.upgradedMessageHoles, messageThreadHoles: seed.messageThreadHoles,
        existingMessageTags: MessageTags.all, messageTagsWithSummary: seed.messageTagsWithSummary,
        messageTagsWithThreadSummary: seed.messageTagsWithThreadSummary, existingGlobalMessageTags: seed.existingGlobalMessageTags,
        peerNamespacesRequiringMessageTextIndex: seed.peerNamespacesRequiringMessageTextIndex + [Namespaces.Peer.CloudUser],
        peerSummaryCounterTags: seed.peerSummaryCounterTags, peerSummaryIsThreadBased: seed.peerSummaryIsThreadBased,
        additionalChatListIndexNamespace: seed.additionalChatListIndexNamespace,
        messageNamespacesRequiringGroupStatsValidation: seed.messageNamespacesRequiringGroupStatsValidation,
        defaultMessageNamespaceReadStates: seed.defaultMessageNamespaceReadStates, chatMessagesNamespaces: seed.chatMessagesNamespaces,
        readStateExcludedMessageNamespaces: seed.readStateExcludedMessageNamespaces,
        getGlobalNotificationSettings: seed.getGlobalNotificationSettings, defaultGlobalNotificationSettings: seed.defaultGlobalNotificationSettings,
        mergeMessageAttributes: seed.mergeMessageAttributes, decodeMessageThreadInfo: seed.decodeMessageThreadInfo,
        decodeAutoremoveTimeout: seed.decodeAutoremoveTimeout, decodeDisplayPeerAsRegularChat: seed.decodeDisplayPeerAsRegularChat,
        isPeerUpgradeMessage: seed.isPeerUpgradeMessage, automaticThreadIndexInfo: seed.automaticThreadIndexInfo,
        customTagsFromAttributes: seed.customTagsFromAttributes, displaySavedMessagesAsTopicListPreferencesKey: seed.displaySavedMessagesAsTopicListPreferencesKey)
}()

final class CodeGramArchiveCatchupTests: XCTestCase {
    private var postbox: Postbox!
    private var path: String!
    private let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(700))
    private let unrelatedPeer = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(701))

    override func setUpWithError() throws {
        try super.setUpWithError()
        initializeAccountManagement()
        let _ = UnrelatedArchiveProbeAttribute.register
        let _ = EagerArchiveRevisionLinksAttribute.register
        self.path = NSTemporaryDirectory() + "CodeGramArchiveCatchup-" + UUID().uuidString
        let encryption = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false,
            key: ValueBoxEncryptionParameters.Key(data: Data(repeating: 0, count: 32))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(repeating: 0, count: 16))!)
        let opened = openPostbox(basePath: self.path, seedConfiguration: archiveBenchmarkSeedConfiguration,
            encryptionParameters: encryption, timestampForAbsoluteTimeBasedOperations: 100,
            isMainProcess: true, isTemporary: true, isReadOnly: false, useCopy: false,
            useCaches: false, removeDatabaseOnError: false)
        self.postbox = self.wait(opened |> mapToSignal { value -> Signal<Postbox, NoError> in
            if case let .postbox(postbox) = value { return .single(postbox) }
            return .complete()
        })
        XCTAssertNotNil(self.postbox)
        guard self.postbox != nil else { throw NSError(domain: "CodeGramArchiveCatchupTests", code: 1) }
        self.waitForCompletion(initializeDeletedMessageArchiveSession(postbox: self.postbox))
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            let peers = [self.peer, self.unrelatedPeer].map { id in
                TelegramUser(id: id, accessHash: nil, firstName: "Fixture", lastName: nil,
                    username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil,
                    flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil,
                    backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
                    subscriberCount: nil, verificationIconFileId: nil)
            }
            transaction.updatePeersInternal(peers, update: { _, updated in updated })
            return true
        }), true)
    }

    override func tearDownWithError() throws {
        if let postbox = self.postbox {
            // Let MediaBox finish opening its own storage before removing its directory.
            let _ = self.wait(postbox.mediaBox.storageBox.totalSize())
        }
        self.postbox = nil
        // Flush the queue on which the Postbox implementation is released.
        Postbox.sharedQueue.sync {}
        if let path = self.path { try? FileManager.default.removeItem(atPath: path) }
        try super.tearDownWithError()
    }

    private func waitForCompletion(_ signal: Signal<Never, NoError>) {
        let done = DispatchSemaphore(value: 0)
        let disposable = signal.start(completed: { done.signal() })
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        disposable.dispose()
    }

    private func wait<T>(_ signal: Signal<T, NoError>) -> T? {
        let result = Atomic<T?>(value: nil)
        let done = DispatchSemaphore(value: 0)
        let disposable = (signal |> take(1)).start(next: { value in
            let _ = result.swap(value)
        }, completed: { done.signal() })
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        disposable.dispose()
        return result.with { $0 }
    }

    private func id(_ id: Int32, peer: PeerId? = nil, namespace: Int32 = Namespaces.Message.Cloud) -> MessageId {
        return MessageId(peerId: peer ?? self.peer, namespace: namespace, id: id)
    }

    private func message(_ id: MessageId, text: String, attributes: [MessageAttribute] = [], media: [Media] = []) -> StoreMessage {
        return StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil,
            threadId: nil, timestamp: 100, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
            forwardInfo: nil, authorId: nil, text: text, attributes: attributes, media: media)
    }

    func testMediaRetentionSlicesStartupAndOnlyReadsChangedArchiveEntries() {
        func file(_ id: Int64) -> TelegramMediaFile {
            return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
                resource: CloudDocumentMediaResource(datacenterId: 1, fileId: id, accessHash: 1, size: 3,
                    fileReference: Data([1]), fileName: "fixture.dat"), previewRepresentations: [], videoThumbnails: [],
                immediateThumbnailData: nil, mimeType: "application/octet-stream", size: 3,
                attributes: [.FileName(fileName: "fixture.dat")], alternativeRepresentations: [])
        }
        let count = 2_000
        let ids = (1 ... count).map { self.id(Int32($0), namespace: Namespaces.Message.ArchivedVersion) }
        var index = DeletedMessageArchiveIndex(messageIds: ids.map(DeletedMessageArchiveIndexEntry.init), liveMessageIds: [])
        let firstFile = file(1)
        self.postbox.mediaBox.storeResourceData(firstFile.resource.id, data: Data([1, 2, 3]), synchronous: true)
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            let _ = transaction.addMessages(ids.enumerated().map { offset, id in
                self.message(id, text: "stored \(offset)", attributes: [UnrelatedArchiveProbeAttribute()], media: [file(Int64(offset + 1))])
            }, location: .Random)
            transaction.updatePreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex, { _ in PreferencesEntry(index) })
            return true
        }), true)
        let retention = DeletedMessageArchiveMediaRetention(postbox: self.postbox, delay: 0.02, batchDelay: 0.001)
        defer { retention.releasePins() }
        func pass(_ index: DeletedMessageArchiveIndex, invalidated: Set<MessageId> = [], repetitions: Int = 1) -> DeletedMessageArchiveMediaRetentionWork? {
            return self.wait(Signal { subscriber in
                for number in 0 ..< repetitions {
                    retention.request(settings: .defaultSettings, index: index, invalidatedIds: invalidated,
                        completed: number == repetitions - 1 ? { work in
                            subscriber.putNext(work)
                            subscriber.putCompletion()
                        } : nil)
                }
                return EmptyDisposable
            })
        }
        let started = CFAbsoluteTimeGetCurrent()
        let _ = UnrelatedArchiveProbeAttribute.reads.swap(0)
        let initial = pass(index)
        XCTAssertEqual(initial?.messageReads, count)
        XCTAssertEqual(initial?.resourceStats, count)
        XCTAssertLessThanOrEqual(initial?.largestReadBatch ?? Int.max, 64)
        XCTAssertEqual(UnrelatedArchiveProbeAttribute.reads.with { $0 }, count,
            "Startup accounting must measure actual stored-message decodes")

        let idle = pass(index, repetitions: 100)
        XCTAssertEqual(idle?.messageReads, 0, "100 replay packets must reuse the catalogue")
        XCTAssertEqual(idle?.resourceStats, 0, "100 replay packets must reuse known resource sizes")
        let completedLater = file(2)
        self.postbox.mediaBox.storeResourceData(completedLater.resource.id, data: Data([1, 2, 3]), synchronous: true)
        retention.protect(resourceIds: [completedLater.resource.id])
        let downloaded = pass(index)
        XCTAssertEqual(downloaded?.messageReads, 0)
        XCTAssertEqual(downloaded?.resourceStats, 1, "Reusing a now-complete resource must invalidate its cached incomplete size")
        self.waitForCompletion(self.postbox.mediaBox.removeCachedResources([completedLater.resource.id], force: false) |> ignoreValues)
        XCTAssertNotNil(self.postbox.mediaBox.completedResourcePath(id: completedLater.resource.id), "A newly completed reused resource must keep its fresh pin")
        let added = self.id(3_000, namespace: Namespaces.Message.ArchivedVersion)
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            let _ = transaction.addMessages([self.message(added, text: "new", attributes: [UnrelatedArchiveProbeAttribute()], media: [file(3_000)])], location: .Random)
            return true
        }), true)
        index.messageIds.append(DeletedMessageArchiveIndexEntry(added))
        let delta = pass(index)
        XCTAssertEqual(delta?.messageReads, 1)
        XCTAssertEqual(delta?.resourceStats, 1)

        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            transaction.updateMessage(added, update: { _ in
                .update(self.message(added, text: "import replaced media", attributes: [UnrelatedArchiveProbeAttribute()], media: [file(4_000)]))
            })
            return true
        }), true)
        let replaced = pass(index, invalidated: [added])
        XCTAssertEqual(replaced?.messageReads, 1, "A remote import can change media while keeping the same message ID")
        XCTAssertEqual(replaced?.resourceStats, 1)
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction in
            ids.filter { transaction.getMessage($0) != nil }.count
        }), count, "Quota maintenance must preserve every archived message")
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: self.postbox.mediaBox.resourcePath(firstFile.resource))), Data([1, 2, 3]))
        print("CodeGram archive retention benchmark: requests=104, stored_rows=2000, startup_reads=\(initial?.messageReads ?? -1), max_read_batch=\(initial?.largestReadBatch ?? -1), idle_reads=\(idle?.messageReads ?? -1), idle_stats=\(idle?.resourceStats ?? -1), completed_resource_stats=\(downloaded?.resourceStats ?? -1), added_reads=\(delta?.messageReads ?? -1), same_id_update_reads=\(replaced?.messageReads ?? -1), milliseconds=\((CFAbsoluteTimeGetCurrent() - started) * 1_000)")
    }

    func testSupersededEvictionDoesNotDeleteQueuedMedia() throws {
        let mediaBox = self.postbox.mediaBox
        let id = MediaResourceId("codegram-retention-stale-eviction")
        let paths = mediaBox.storePathsForId(id)
        let files = [paths.complete, paths.partial, paths.partial + ".meta"]
        for path in files { try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path)) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocked = mediaBox.removeCachedResources([MediaResourceId("codegram-retention-blocker")], force: true,
            shouldRemove: {
                entered.signal()
                let _ = release.wait(timeout: .now() + 10)
                return false
            }).start()
        defer { release.signal(); blocked.dispose() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let generation = Atomic<Int>(value: 1)
        let finished = DispatchSemaphore(value: 0)
        let queued = mediaBox.removeCachedResources([id], force: true,
            shouldRemove: { generation.with { $0 == 1 } }).start(completed: { finished.signal() })
        let _ = generation.swap(2)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        queued.dispose()
        for path in files {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([1, 2, 3]),
                "A newer archive snapshot must cancel eviction at the actual MediaBox I/O queue")
        }
    }

    func testInvalidationDuringAnInFlightReadCannotRestoreStaleMedia() {
        func file(_ id: Int64) -> TelegramMediaFile {
            return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil,
                resource: CloudDocumentMediaResource(datacenterId: 1, fileId: id, accessHash: 1, size: 3,
                    fileReference: Data([1]), fileName: "fixture.dat"), previewRepresentations: [], videoThumbnails: [],
                immediateThumbnailData: nil, mimeType: "application/octet-stream", size: 3,
                attributes: [.FileName(fileName: "fixture.dat")], alternativeRepresentations: [])
        }
        let id = self.id(7_000, namespace: Namespaces.Message.Archived)
        let oldFile = file(7_000), newFile = file(7_001)
        let mediaBox = self.postbox.mediaBox
        for file in [oldFile, newFile] { mediaBox.storeResourceData(file.resource.id, data: Data([1, 2, 3]), synchronous: true) }
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            let _ = transaction.addMessages([self.message(id, text: "old", attributes: [UnrelatedArchiveProbeAttribute()], media: [oldFile])], location: .Random)
            return true
        }), true)
        let retention = DeletedMessageArchiveMediaRetention(postbox: self.postbox, delay: 0.02, batchDelay: 0.001)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let result = Atomic<DeletedMessageArchiveMediaRetentionWork?>(value: nil)
        let index = DeletedMessageArchiveIndex(messageIds: [DeletedMessageArchiveIndexEntry(id)], liveMessageIds: [])
        let _ = UnrelatedArchiveProbeAttribute.onNextDecode.swap({
            entered.signal()
            let _ = release.wait(timeout: .now() + 10)
        })
        defer {
            let _ = UnrelatedArchiveProbeAttribute.onNextDecode.swap(nil)
            release.signal()
            retention.releasePins()
        }
        retention.request(settings: .defaultSettings, index: index)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        // The old row has been read and is still decoding. Queue its replacement
        // before releasing that read, then invalidate its catalogue descriptor.
        let rewrite = self.postbox.transaction { transaction -> Void in
            transaction.updateMessage(id, update: { _ in
                .update(self.message(id, text: "new", attributes: [UnrelatedArchiveProbeAttribute()], media: [newFile]))
            })
        }.start()
        defer { rewrite.dispose() }
        retention.request(settings: .defaultSettings, index: index, invalidatedIds: [id], completed: { work in
            let _ = result.swap(work)
            completed.signal()
        })
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(result.with { $0?.messageReads }, 1, "The invalidated row must be fetched again after the stale callback")
        XCTAssertEqual(result.with { $0?.resourceStats }, 1)
        // A stale descriptor would pin oldFile, allowing ordinary cache cleanup
        // to delete newFile. Check the actual MediaBox keepResource behaviour.
        self.waitForCompletion(mediaBox.removeCachedResources([newFile.resource.id], force: false) |> ignoreValues)
        XCTAssertNotNil(mediaBox.completedResourcePath(id: newFile.resource.id), "The replacement resource must retain its pin")
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction in transaction.getMessage(id)?.text }), "new")
    }

    func testHistoryAndSearchDoNotEagerlyDecodeArchivedRevisions() {
        let liveId = self.id(42)
        let revisionCount = 1_000
        let versionIds = (1 ... revisionCount).map { self.id(Int32($0), namespace: Namespaces.Message.ArchivedVersion) }
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            let versions = versionIds.enumerated().map { offset, id in
                self.message(id, text: "previous revision \(offset)", attributes: [
                    UnrelatedArchiveProbeAttribute(), ArchivedMessageVersionAttribute(capturedAt: Int32(offset))])
            }
            let _ = transaction.addMessages(versions + [self.message(liveId, text: "archivehotpathneedle", attributes: [
                EagerArchiveRevisionLinksAttribute(versionIds: versionIds)])], location: .Random)
            return true
        }), true)

        let result = self.wait(self.postbox.transaction { transaction -> ([Int], [Int], Int, Bool) in
            func measure(_ label: String, _ body: () -> Int) -> (Int, Int) {
                let _ = UnrelatedArchiveProbeAttribute.reads.swap(0)
                let started = CFAbsoluteTimeGetCurrent()
                let rows = body()
                let reads = UnrelatedArchiveProbeAttribute.reads.with { $0 }
                print("CodeGram archive render benchmark \(label): rows=\(rows), revision_decodes=\(reads), milliseconds=\((CFAbsoluteTimeGetCurrent() - started) * 1_000)")
                return (rows, reads)
            }
            func workload(_ label: String) -> [Int] {
                let direct = measure(label + "/getMessage") { transaction.getMessage(liveId) == nil ? 0 : 1 }
                let history = measure(label + "/history") {
                    transaction.getMessages(peerId: self.peer, namespace: Namespaces.Message.Cloud,
                        from: MessageIndex.upperBound(peerId: self.peer, namespace: Namespaces.Message.Cloud), includeFrom: false,
                        to: MessageIndex.lowerBound(peerId: self.peer, namespace: Namespaces.Message.Cloud), limit: 50).count
                }
                let search = measure(label + "/search") {
                    transaction.searchMessages(peerId: self.peer, query: "archivehotpathneedle", tags: nil).count
                }
                XCTAssertEqual(direct.0, 1)
                XCTAssertEqual(history.0, 1)
                XCTAssertEqual(search.0, 1)
                return [direct.1, history.1, search.1]
            }
            let eagerReads = workload("legacy-eager")
            transaction.updateMessage(liveId, update: { _ in
                .update(self.message(liveId, text: "archivehotpathneedle", attributes: [
                    ArchivedMessageAttribute(originalMessageId: liveId, versionIds: versionIds, deletedAt: nil, sessionId: 1)]))
            })
            let lazyReads = workload("production-lazy")
            let storedIdsPreserved = transaction.getMessage(liveId)?.archivedMessageAttribute?.versionIds == versionIds
            let menu = measure("production-lazy/explicit-version-menu") {
                _internal_archivedMessageVersions(transaction: transaction, id: liveId).count
            }
            return (eagerReads, lazyReads, menu.1, storedIdsPreserved && menu.0 == revisionCount + 1)
        })
        XCTAssertEqual(result?.0, [revisionCount, revisionCount, revisionCount],
            "Legacy association must reproduce the actual renderer's revision amplification")
        XCTAssertEqual(result?.1, [0, 0, 0], "Opening a chat, search or message must not render its entire edit history")
        XCTAssertEqual(result?.2, revisionCount, "Opening the versions menu still loads every stored revision")
        XCTAssertEqual(result?.3, true, "Stored version IDs and the complete revision history must survive")
    }

    func testMixedEditAndDeletesShareOneSnapshotAndRetentionPass() {
        let first = self.id(1), second = self.id(2), third = self.id(3)
        let mediaBox = self.postbox.mediaBox
        let result = self.wait(self.postbox.transaction { transaction -> (Int, Int, Int, Int, Int, Bool) in
            let _ = transaction.addMessages([self.message(first, text: "before"), self.message(second, text: "two"),
                self.message(third, text: "three")], location: .Random)
            var loads = 0, saves = 0, retentions = 0
            let batch = DeletedMessageArchiveBatch(loadSettings: { .defaultSettings }, loadIndex: {
                loads += 1
                return transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty
            }, saveIndex: { index in
                saves += 1
                transaction.updatePreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex, { _ in PreferencesEntry(index) })
            }, loadRemoteState: { nil }, saveRemoteState: { _ in XCTFail("No remote references to consume") },
                retainMedia: { _, _ in retentions += 1 })
            transaction.updateMessage(first, update: { _ in
                .update(archivePreviousMessageVersionIfNeeded(transaction: transaction, id: first,
                    updatedMessage: self.message(first, text: "after"), mediaBox: mediaBox, batch: batch))
            })
            // These are the production delete calls used by state replay, in the
            // same transaction after the edit has already loaded the batch index.
            for id in [second, third] {
                _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: [id],
                    archiveCloudMessages: true, archiveBatch: batch)
            }
            batch.finish()
            let index = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)!.get(DeletedMessageArchiveIndex.self)!
            let messages = index.messageIds.compactMap { transaction.getMessage($0.messageId) }
            let deleted = messages.filter { $0.id.namespace == Namespaces.Message.Archived }
            let versions = messages.filter { $0.id.namespace == Namespaces.Message.ArchivedVersion }
            let preserved = Set(deleted.compactMap { $0.archivedMessageAttribute?.originalMessageId }) == Set([second, third])
                && versions.first?.text == "before" && transaction.getMessage(first)?.text == "after"
                && transaction.getMessage(second) == nil && transaction.getMessage(third) == nil
                && index.liveMessageIds.map(\.messageId) == [first]
            return (loads, saves, retentions, deleted.count, versions.count, preserved)
        })
        XCTAssertEqual(result?.0, 1)
        XCTAssertEqual(result?.1, 1)
        XCTAssertEqual(result?.2, 1)
        XCTAssertEqual(result?.3, 2)
        XCTAssertEqual(result?.4, 1)
        XCTAssertEqual(result?.5, true)
    }

    func testEmptyAndRepeatedPagesDoNotDecodeUnrelatedArchive() throws {
        let original = self.id(10)
        let archived = self.id(10, namespace: Namespaces.Message.Archived)
        let mediaBox = self.postbox.mediaBox
        XCTAssertEqual(self.wait(self.postbox.transaction { transaction -> Bool in
            let unrelated = (1 ... 2_000).map { number -> StoreMessage in
                let id = self.id(Int32(number), peer: self.unrelatedPeer, namespace: Namespaces.Message.Archived)
                return self.message(id, text: "unrelated", attributes: [UnrelatedArchiveProbeAttribute(),
                    ArchivedMessageAttribute(originalMessageId: self.id(Int32(number), peer: self.unrelatedPeer),
                        versionIds: [], deletedAt: 100, sessionId: 1)])
            }
            let target = self.message(archived, text: "saved", attributes: [
                ArchivedMessageAttribute(originalMessageId: original, versionIds: [], deletedAt: 100, sessionId: 1)])
            let _ = transaction.addMessages(unrelated + [target], location: .Random)
            let entries = unrelated.compactMap { message -> DeletedMessageArchiveIndexEntry? in
                if case let .Id(id) = message.id { return DeletedMessageArchiveIndexEntry(id) }
                return nil
            } + [DeletedMessageArchiveIndexEntry(archived)]
            transaction.updatePreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex, { _ in
                PreferencesEntry(DeletedMessageArchiveIndex(messageIds: entries, liveMessageIds: []))
            })
            return true
        }), true)
        let eventData = Data("""
        {"seq":1,"peer_type":"user","peer_id":700,"message_id":10,"outgoing":false,
         "date":100,"captured_at":100,"text":"saved","media_title":"","kind":"delete"}
        """.utf8)
        let event = try JSONDecoder().decode(NikitaRemoteArchiveEvent.self, from: eventData)
        let _ = UnrelatedArchiveProbeAttribute.reads.swap(0)
        let imported = self.wait(self.postbox.transaction { transaction -> (Int?, Int?, Bool) in
            let before = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)
            var state = NikitaRemoteArchiveState()
            let empty = importNikitaArchiveEvents(transaction: transaction, mediaBox: mediaBox,
                events: [], accountId: 1, serverId: "test", state: &state)
            let repeated = importNikitaArchiveEvents(transaction: transaction, mediaBox: mediaBox,
                events: [event], accountId: 1, serverId: "test", state: &state)
            return (empty, repeated, before == transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex))
        })
        XCTAssertEqual(imported?.0, 0)
        XCTAssertEqual(imported?.1, 0)
        XCTAssertEqual(imported?.2, true)
        XCTAssertEqual(UnrelatedArchiveProbeAttribute.reads.with { $0 }, 0,
            "Idle/repeated page must not load 2,000 messages from unrelated chats")
    }
}
