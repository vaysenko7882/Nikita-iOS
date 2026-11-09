import Foundation
import Postbox
import SwiftSignalKit

private let deletedMessageArchiveSessionId = Int64.random(in: Int64.min ... Int64.max)

private let deletedMessageArchiveMediaRetentions = Atomic<[String: DeletedMessageArchiveMediaRetention]>(value: [:])
private let deletedMessageArchiveSessionInitialized = Atomic<Bool>(value: false)

private func archiveTimestamp() -> Int32 {
    return Int32(Date().timeIntervalSince1970)
}

private func removeDeletedMessageArchiveMetadata(transaction: Transaction, ids: [MessageId]) {
    for id in ids {
        transaction.updateMessage(id, update: { currentMessage in
            let attributes = attributesWithoutArchiveMetadata(currentMessage.attributes)
            if attributes.count == currentMessage.attributes.count {
                return .skip
            }
            return .update(StoreMessage(
                id: currentMessage.id,
                customStableId: nil,
                globallyUniqueId: currentMessage.globallyUniqueId,
                groupingKey: currentMessage.groupingKey,
                threadId: currentMessage.threadId,
                timestamp: currentMessage.timestamp,
                flags: StoreMessageFlags(currentMessage.flags),
                tags: currentMessage.tags,
                globalTags: currentMessage.globalTags,
                localTags: currentMessage.localTags,
                forwardInfo: currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                authorId: currentMessage.author?.id,
                text: currentMessage.text,
                attributes: attributes + [NikitaArchiveMetadataResetAttribute()],
                media: currentMessage.media
            ))
        })
    }
}

private func prepareDeletedMessageArchive(transaction: Transaction, mediaBox: MediaBox? = nil, batch: DeletedMessageArchiveBatch? = nil) -> DeletedMessageArchiveSettings? {
    if let batch { return batch.settings }
    guard deletedMessageArchiveSessionInitialized.with({ $0 }) else {
        return nil
    }
    var settings = deletedMessageArchiveSettings(transaction: transaction)
    if settings.sessionId != deletedMessageArchiveSessionId {
        if settings.sessionId != 0 && !settings.keepAcrossLaunches {
            let index = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty
            var resourceIds = Set<MediaResourceId>()
            for entry in index.messageIds {
                if let message = transaction.getMessage(entry.messageId) {
                    resourceIds.formUnion(archivedResourceIds(message))
                }
            }
            if let mediaBox, !resourceIds.isEmpty {
                let _ = mediaBox.removeCachedResources(Array(resourceIds), force: true).start()
            }
            transaction.deleteMessages(index.messageIds.map(\.messageId), forEachMedia: nil)
            removeDeletedMessageArchiveMetadata(transaction: transaction, ids: index.liveMessageIds.map(\.messageId))
            updateDeletedMessageArchiveIndex(transaction: transaction, { _ in .empty })
        }
        settings.sessionId = deletedMessageArchiveSessionId
        transaction.updatePreferencesEntry(key: PreferencesKeys.deletedMessageArchiveSettings, { _ in
            return PreferencesEntry(settings)
        })
    }
    return settings
}

private func archivedResourceIds(_ message: Message) -> [MediaResourceId] {
    return archivedResourceIds(media: message.effectiveMedia)
}

private func archivedResourceIds(media: [Media]) -> [MediaResourceId] {
    var result: [MediaResourceId] = []

    func append(_ media: Media) {
        addMessageMediaResourceIdsToRemove(media: media, resourceIds: &result)
        if let paidContent = media as? TelegramMediaPaidContent {
            for extendedMedia in paidContent.extendedMedia {
                if case let .full(nestedMedia) = extendedMedia {
                    append(nestedMedia)
                }
            }
        } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
            if let image = content.image {
                append(image)
            }
            if let file = content.file {
                append(file)
            }
            if let instantPage = content.instantPage?._parse() {
                for nestedMedia in instantPage.media.values {
                    append(nestedMedia._asMedia())
                }
            }
        }
    }

    for media in media {
        append(media)
    }
    return result
}

private func messageIsDisappearing(_ message: Message) -> Bool {
    for attribute in message.attributes {
        if attribute is AutoremoveTimeoutMessageAttribute
            || attribute is AutoclearTimeoutMessageAttribute
            || attribute is ConsumableContentMessageAttribute
            || attribute is EphemeralMessageAttribute
            || attribute is EphemeralOutgoingMessageAttribute {
            return true
        }
    }
    return false
}

public func deletedMessageArchiveRetentionPlan<ID: Hashable>(
    items: [(id: ID, size: Int64, isDisappearing: Bool)],
    limitBytes: Int64,
    disappearingLimitBytes: Int64
) -> (retained: [ID], removed: [ID]) {
    var removed = Set<ID>()

    func trim(candidates: [Int], budget: Int64) {
        let remaining = candidates.filter { !removed.contains(items[$0].id) }
        var total: Int64 = remaining.reduce(0) { $0 + items[$1].size }
        guard total > budget else {
            return
        }
        let ordered = remaining.sorted { lhs, rhs in
            if items[lhs].size != items[rhs].size {
                return items[lhs].size > items[rhs].size
            }
            return lhs < rhs
        }
        for index in ordered {
            if total <= budget {
                break
            }
            total -= items[index].size
            removed.insert(items[index].id)
        }
    }

    trim(candidates: items.indices.filter { items[$0].isDisappearing }, budget: disappearingLimitBytes)
    trim(candidates: Array(items.indices), budget: limitBytes)

    var retained: [ID] = []
    var removedIds: [ID] = []
    for item in items {
        if removed.contains(item.id) {
            removedIds.append(item.id)
        } else {
            retained.append(item.id)
        }
    }
    return (retained: retained, removed: removedIds)
}

struct DeletedMessageArchiveMediaRetentionWork {
    var messageReads = 0
    var largestReadBatch = 0
    var resourceStats = 0
}

private struct DeletedMessageArchiveMediaRecord {
    let resourceIds: [MediaResourceId]
    let isDisappearing: Bool
}

/// The archive index is durable; this disposable catalogue is rebuilt once per
/// launch. Replay only submits a snapshot, never scans old messages or stats files
/// on Postbox's shared queue. Existing pins survive an interrupted maintenance pass.
final class DeletedMessageArchiveMediaRetention {
    private weak var postbox: Postbox?
    private let queue = Queue(name: "CodeGram.ArchiveMediaRetention", qos: .utility)
    private let generation = Atomic<Int>(value: 0)
    private let initialPinsRestored = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let transactionDisposable = MetaDisposable()
    private let delay: Double
    private let batchDelay: Double
    private var index = DeletedMessageArchiveIndex.empty
    private var settings = DeletedMessageArchiveSettings.defaultSettings
    private var records: [DeletedMessageArchiveIndexEntry: DeletedMessageArchiveMediaRecord] = [:]
    private var invalidatedGenerations: [DeletedMessageArchiveIndexEntry: Int] = [:]
    private var resourceSizes: [MediaResourceId: Int64] = [:]
    private var pins: [MediaResourceId: Disposable] = [:]
    private var running = false
    private var scheduled = false
    private var suspended = false
    private var runId = 0
    private var requestedGeneration = 0
    private var refreshSizes = false
    private var lastSizeRefresh: Double = 0
    private var work = DeletedMessageArchiveMediaRetentionWork()
    private var completions: [(DeletedMessageArchiveMediaRetentionWork) -> Void] = []

    init(postbox: Postbox, delay: Double = 1.0, batchDelay: Double = 0.02) {
        self.postbox = postbox
        self.delay = delay
        self.batchDelay = batchDelay
    }

    deinit {
        self.transactionDisposable.dispose()
        for pin in self.pins.values { pin.dispose() }
    }

    var isAlive: Bool { self.postbox != nil }

    var initialMediaPinsRestored: Signal<Bool, NoError> { self.initialPinsRestored.get() }

    func request(settings: DeletedMessageArchiveSettings, index: DeletedMessageArchiveIndex,
        invalidatedIds: Set<MessageId> = [], refreshSizes: Bool = false,
        completed: ((DeletedMessageArchiveMediaRetentionWork) -> Void)? = nil) {
        // Increment before enqueuing: a finishing old pass must not evict using a
        // stale snapshot while a newer replay transaction has already changed it.
        let generation = self.generation.modify { $0 + 1 }
        self.queue.async {
            self.index = index
            self.settings = settings
            self.requestedGeneration = generation
            self.suspended = false
            self.refreshSizes = self.refreshSizes || refreshSizes
            for id in invalidatedIds {
                let entry = DeletedMessageArchiveIndexEntry(id)
                for resourceId in self.records[entry]?.resourceIds ?? [] where self.resourceSizes[resourceId] == 0 {
                    self.resourceSizes.removeValue(forKey: resourceId)
                }
                self.records.removeValue(forKey: entry)
                self.invalidatedGenerations[entry] = generation
            }
            if let completed { self.completions.append(completed) }
            self.schedule()
        }
    }

    /// Install a pin before the capture transaction returns. The maintenance
    /// queue takes ownership later; the MediaBox operation is enqueued now.
    func protect(resourceIds: [MediaResourceId]) {
        guard let mediaBox = self.postbox?.mediaBox else { return }
        // Capture can precede batch.finish by thousands of replay operations.
        // Invalidate pending eviction/pruning before installing these fresh pins.
        let _ = self.generation.modify { $0 + 1 }
        let pins = Set(resourceIds).map { ($0, mediaBox.keepResource(id: $0).start()) }
        self.queue.async {
            for (id, pin) in pins {
                // A resource can finish downloading between two captures using
                // the same ID. Its previous "incomplete" size is no longer valid.
                if self.resourceSizes[id] == 0 { self.resourceSizes.removeValue(forKey: id) }
                if self.pins[id] == nil { self.pins[id] = pin }
                else { pin.dispose() }
            }
        }
    }

    func releasePins(markInitialPinsRestored: Bool = false) {
        let _ = self.generation.modify { $0 + 1 }
        self.queue.async {
            self.suspended = true
            self.runId += 1
            self.running = false
            self.transactionDisposable.set(nil)
            for pin in self.pins.values { pin.dispose() }
            self.pins.removeAll()
            self.resourceSizes.removeAll()
            self.completions.removeAll()
            // An explicit user clear removes the protected archive media too.
            // Replacing a coordinator must not open its previous startup gate.
            if markInitialPinsRestored { self.initialPinsRestored.set(true) }
        }
    }

    private func schedule() {
        guard !self.running, !self.scheduled, !self.suspended else { return }
        self.scheduled = true
        self.queue.after(self.delay) {
            self.scheduled = false
            guard !self.running, !self.suspended else { return }
            self.work = DeletedMessageArchiveMediaRetentionWork()
            self.begin()
        }
    }

    private func begin() {
        guard self.postbox != nil, !self.suspended else { return }
        self.running = true
        self.runId += 1
        let runId = self.runId
        let generation = self.requestedGeneration
        let entries = Set(self.index.messageIds)
        self.records = self.records.filter { entries.contains($0.key) }
        self.invalidatedGenerations = self.invalidatedGenerations.filter { entries.contains($0.key) }
        let missing = self.index.messageIds.filter { self.records[$0] == nil }
        self.read(missing, offset: 0, runId: runId, generation: generation)
    }

    private func read(_ entries: [DeletedMessageArchiveIndexEntry], offset: Int, runId: Int, generation: Int) {
        guard self.runId == runId, !self.suspended, let postbox = self.postbox else { return }
        guard self.generation.with({ $0 }) == generation else {
            self.running = false
            self.schedule()
            return
        }
        guard offset < entries.count else {
            self.finish(runId: runId, generation: generation)
            return
        }
        let batch = Array(entries[offset ..< min(offset + 64, entries.count)])
        self.transactionDisposable.set(postbox.transaction { transaction -> (Int, [DeletedMessageArchiveIndexEntry: DeletedMessageArchiveMediaRecord]) in
            let started = CFAbsoluteTimeGetCurrent()
            var records: [DeletedMessageArchiveIndexEntry: DeletedMessageArchiveMediaRecord] = [:]
            var reads = 0
            for entry in batch {
                let message = transaction.getMessage(entry.messageId)
                records[entry] = DeletedMessageArchiveMediaRecord(resourceIds: message.map(archivedResourceIds) ?? [],
                    isDisappearing: message.map(messageIsDisappearing) ?? false)
                reads += 1
                // A large message can exceed the time budget by itself; do not
                // compound it with another 63 decodes before chat/search can run.
                if CFAbsoluteTimeGetCurrent() - started >= 0.004 { break }
            }
            return (reads, records)
        }.start(next: { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.runId == runId, !self.suspended else { return }
                let (reads, records) = result
                self.work.messageReads += reads
                self.work.largestReadBatch = max(self.work.largestReadBatch, reads)
                let validRecords = records.filter { (self.invalidatedGenerations[$0.key] ?? 0) <= generation }
                self.records.merge(validRecords, uniquingKeysWith: { _, updated in updated })
                if let mediaBox = self.postbox?.mediaBox {
                    for record in validRecords.values {
                        for id in record.resourceIds where self.pins[id] == nil {
                            self.pins[id] = mediaBox.keepResource(id: id).start()
                        }
                    }
                }
                self.queue.after(self.batchDelay) { self.read(entries, offset: offset + reads, runId: runId, generation: generation) }
            }
        }))
    }

    private func finish(runId: Int, generation: Int) {
        guard self.runId == runId, !self.suspended, let postbox = self.postbox else { return }
        guard self.generation.with({ $0 }) == generation else {
            // Requests submitted during a pass reuse all decoded rows and only
            // add the newly captured messages. No full scan starts over.
            self.running = false
            self.schedule()
            return
        }
        var resources: [MediaResourceId] = []
        var disappearing = Set<MediaResourceId>()
        var seen = Set<MediaResourceId>()
        for entry in self.index.messageIds.reversed() {
            guard self.generation.with({ $0 }) == generation else {
                self.running = false
                self.schedule()
                return
            }
            guard let record = self.records[entry] else { continue }
            for id in record.resourceIds.reversed() where seen.insert(id).inserted {
                resources.append(id)
                if record.isDisappearing { disappearing.insert(id) }
            }
        }
        resources.reverse()
        let mediaBox = postbox.mediaBox
        // File I/O and quota planning run on the utility queue. Unchanged replay
        // packets reuse sizes; an occasional refresh accounts for later downloads.
        let now = CFAbsoluteTimeGetCurrent()
        let refreshAll = self.refreshSizes || now - self.lastSizeRefresh >= 30.0
        if refreshAll { self.lastSizeRefresh = now }
        self.refreshSizes = false
        self.resourceSizes = self.resourceSizes.filter { seen.contains($0.key) }
        var completed: [(id: MediaResourceId, size: Int64, isDisappearing: Bool)] = []
        for id in resources {
            guard self.generation.with({ $0 }) == generation else {
                self.running = false
                self.schedule()
                return
            }
            if refreshAll || self.resourceSizes[id] == nil {
                self.work.resourceStats += 1
                self.resourceSizes[id] = mediaBox.completedResourcePath(id: id).flatMap { fileSize($0) } ?? 0
            }
            if let size = self.resourceSizes[id], size > 0 {
                if self.pins[id] == nil { self.pins[id] = mediaBox.keepResource(id: id).start() }
                completed.append((id: id, size: size, isDisappearing: disappearing.contains(id)))
            }
        }
        let gigabyte: Int64 = 1024 * 1024 * 1024
        let plan = deletedMessageArchiveRetentionPlan(items: completed,
            limitBytes: Int64(self.settings.mediaLimitGigabytes) * gigabyte,
            disappearingLimitBytes: Int64(self.settings.disappearingMediaLimitGigabytes) * gigabyte)
        let removed = Set(plan.removed)
        // Match the archive's existing policy: only completed files consume the
        // quota and keep persistent pins. Capture/in-progress pins are temporary.
        let desiredPins = Set(plan.retained)
        // Authorize eviction in a tiny serialized transaction, after all replay
        // mutations before it have submitted their new generation. No old plan
        // can delete resources after a newer index/settings snapshot arrived.
        self.transactionDisposable.set(postbox.transaction { _ -> Bool in
            guard self.generation.with({ $0 }) == generation else { return false }
            if !plan.removed.isEmpty {
                let _ = mediaBox.removeCachedResources(plan.removed, force: true,
                    shouldRemove: { self.generation.with({ $0 }) == generation }).start()
            }
            return true
        }.start(next: { [weak self] accepted in
            guard let self else { return }
            self.queue.async {
                guard self.runId == runId, !self.suspended else { return }
                self.running = false
                guard accepted, self.generation.with({ $0 }) == generation else { self.schedule(); return }
                for id in Array(self.pins.keys) where !desiredPins.contains(id) {
                    self.pins.removeValue(forKey: id)?.dispose()
                }
                // The I/O queue may still cancel removal after a new request.
                // Re-stat next time instead of caching an unconfirmed deletion.
                for id in removed { self.resourceSizes.removeValue(forKey: id) }
                // A settings/capture transaction can supersede a large pin-prune
                // loop. Restore its newer pin set before opening the cold gate.
                guard self.generation.with({ $0 }) == generation else { self.schedule(); return }
                // keepResource operations were enqueued on MediaBox before this
                // signal. Automatic peer eviction may now queue behind them.
                self.initialPinsRestored.set(true)
                let callbacks = self.completions
                self.completions.removeAll()
                for callback in callbacks { callback(self.work) }
            }
        }))
    }
}

func updateDeletedMessageArchiveMediaRetention(transaction: Transaction, mediaBox: MediaBox,
    settings suppliedSettings: DeletedMessageArchiveSettings? = nil, index suppliedIndex: DeletedMessageArchiveIndex? = nil,
    invalidatedIds: Set<MessageId> = [], refreshSizes: Bool = false) {
    guard let retention = deletedMessageArchiveMediaRetentions.with({ $0[mediaBox.basePath] }) else { return }
    let settings = suppliedSettings ?? deletedMessageArchiveSettings(transaction: transaction)
    let index = suppliedIndex ?? (transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty)
    retention.request(settings: settings, index: index, invalidatedIds: invalidatedIds, refreshSizes: refreshSizes)
}

func makeDeletedMessageArchiveBatch(transaction: Transaction, mediaBox: MediaBox) -> DeletedMessageArchiveBatch {
    return DeletedMessageArchiveBatch(
        loadSettings: { prepareDeletedMessageArchive(transaction: transaction, mediaBox: mediaBox) },
        loadIndex: { transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty },
        saveIndex: { index in transaction.updatePreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex, { _ in PreferencesEntry(index) }) },
        loadRemoteState: { transaction.getPreferencesEntry(key: PreferencesKeys.nikitaServerArchive)?.get(NikitaRemoteArchiveState.self) },
        saveRemoteState: { state in transaction.updatePreferencesEntry(key: PreferencesKeys.nikitaServerArchive, { _ in PreferencesEntry(state) }) },
        retainMedia: { settings, index in updateDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox, settings: settings, index: index) }
    )
}

private func mutateDeletedMessageArchiveIndex(transaction: Transaction, batch: DeletedMessageArchiveBatch?, _ update: (inout DeletedMessageArchiveIndex) -> Void) {
    if let batch { batch.updateIndex(update) }
    else {
        transaction.updatePreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex, { entry in
            var index = entry?.get(DeletedMessageArchiveIndex.self) ?? .empty
            update(&index)
            return PreferencesEntry(index)
        })
    }
}

private func appendDeletedMessageArchiveSnapshot(transaction: Transaction, batch: DeletedMessageArchiveBatch?, snapshot: MessageId, live: MessageId) {
    let snapshotEntry = DeletedMessageArchiveIndexEntry(snapshot)
    let liveEntry = DeletedMessageArchiveIndexEntry(live)
    if let batch {
        batch.appendSnapshot(snapshotEntry, live: liveEntry)
    } else {
        mutateDeletedMessageArchiveIndex(transaction: transaction, batch: nil, { index in
            index.messageIds.append(snapshotEntry)
            if !index.liveMessageIds.contains(liveEntry) { index.liveMessageIds.append(liveEntry) }
        })
    }
}

private func appendDeletedMessageArchiveLiveMessage(transaction: Transaction, batch: DeletedMessageArchiveBatch?, id: MessageId) {
    let entry = DeletedMessageArchiveIndexEntry(id)
    if let batch {
        batch.appendLiveMessage(entry)
    } else {
        mutateDeletedMessageArchiveIndex(transaction: transaction, batch: nil, { index in
            if !index.liveMessageIds.contains(entry) { index.liveMessageIds.append(entry) }
        })
    }
}

private func requestDeletedMessageArchiveMediaRetention(transaction: Transaction, mediaBox: MediaBox, batch: DeletedMessageArchiveBatch?) {
    if let batch { batch.requestMediaRetention() }
    else { updateDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox) }
}

private func archiveAttribute(_ attributes: [MessageAttribute]) -> ArchivedMessageAttribute? {
    return attributes.first(where: { $0 is ArchivedMessageAttribute }) as? ArchivedMessageAttribute
}

private func attributesWithoutArchiveMetadata(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    return attributes.filter {
        !($0 is ArchivedMessageAttribute) && !($0 is ArchivedMessageVersionAttribute)
    }
}

private func isVolatileEditedMessageAttribute(_ attribute: MessageAttribute) -> Bool {
    return attribute is ArchivedMessageAttribute
        || attribute is ArchivedMessageVersionAttribute
        || attribute is EditedMessageAttribute
        || attribute is ReactionsMessageAttribute
        || attribute is PendingReactionsMessageAttribute
        || attribute is PendingStarsReactionsMessageAttribute
        || attribute is ViewCountMessageAttribute
        || attribute is ForwardCountMessageAttribute
        || attribute is NotificationInfoMessageAttribute
        || attribute is ChannelMessageStateVersionAttribute
        || attribute is PeerGroupMessageStateVersionAttribute
        || attribute is TranslationMessageAttribute
        || attribute is ConsumableContentMessageAttribute
        || attribute is ConsumablePersonalMentionMessageAttribute
        || attribute is ReplyThreadMessageAttribute
}

private func encodedContentAttributes(_ attributes: [MessageAttribute]) -> [Data] {
    return attributes.compactMap { attribute -> Data? in
        if isVolatileEditedMessageAttribute(attribute) {
            return nil
        }
        let encoder = PostboxEncoder()
        encoder.encodeRootObject(attribute)
        var data = Data(String(describing: type(of: attribute)).utf8)
        data.append(encoder.makeData())
        return data
    }
}

private func archiveImageRepresentationsAreEqual(_ lhs: [TelegramMediaImageRepresentation], _ rhs: [TelegramMediaImageRepresentation]) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }
    for i in 0 ..< lhs.count {
        if !lhs[i].isSemanticallyEqual(to: rhs[i]) {
            return false
        }
    }
    return true
}

private func archiveOptionalMediaAreEqual(_ lhs: Media?, _ rhs: Media?) -> Bool {
    switch (lhs, rhs) {
    case let (.some(lhs), .some(rhs)):
        return archiveMediaAreEqual(lhs, rhs)
    case (nil, nil):
        return true
    default:
        return false
    }
}

private func archiveExtendedMediaAreEqual(_ lhs: TelegramExtendedMedia, _ rhs: TelegramExtendedMedia) -> Bool {
    if case let .full(lhsMedia) = lhs, case let .full(rhsMedia) = rhs {
        return archiveMediaAreEqual(lhsMedia, rhsMedia)
    }
    return lhs == rhs
}

private func archiveFileArraysAreEqual(_ lhs: [TelegramMediaFile], _ rhs: [TelegramMediaFile]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for i in 0 ..< lhs.count {
        if !archiveMediaAreEqual(lhs[i], rhs[i]) { return false }
    }
    return true
}

private func archiveWebpageAttributesAreEqual(_ lhs: [TelegramMediaWebpageAttribute], _ rhs: [TelegramMediaWebpageAttribute]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for i in 0 ..< lhs.count {
        switch (lhs[i], rhs[i]) {
        case let (.theme(lhsAttribute), .theme(rhsAttribute)):
            if lhsAttribute.settings != rhsAttribute.settings
                || !archiveFileArraysAreEqual(lhsAttribute.files, rhsAttribute.files) { return false }
        case let (.stickerPack(lhsAttribute), .stickerPack(rhsAttribute)):
            if lhsAttribute.flags != rhsAttribute.flags
                || !archiveFileArraysAreEqual(lhsAttribute.files, rhsAttribute.files) { return false }
        case let (.giftCollection(lhsAttribute), .giftCollection(rhsAttribute)):
            if !archiveFileArraysAreEqual(lhsAttribute.files, rhsAttribute.files) { return false }
        default:
            if lhs[i] != rhs[i] { return false }
        }
    }
    return true
}

private func archiveInstantPagesAreEqual(_ lhs: InstantPage.Accessor?, _ rhs: InstantPage.Accessor?) -> Bool {
    switch (lhs, rhs) {
    case let (.some(lhs), .some(rhs)):
        if lhs == rhs { return true }
        let lhsPage = lhs._parse(), rhsPage = rhs._parse()
        guard lhsPage.blocks == rhsPage.blocks,
            lhsPage.isComplete == rhsPage.isComplete,
            lhsPage.rtl == rhsPage.rtl,
            lhsPage.url == rhsPage.url,
            lhsPage.rawMedia.count == rhsPage.rawMedia.count else { return false }
        for (id, lhsMedia) in lhsPage.rawMedia {
            guard let rhsMedia = rhsPage.rawMedia[id], archiveMediaAreEqual(lhsMedia, rhsMedia) else { return false }
        }
        // Page views, like message view counts, change without an authored edit.
        return true
    case (nil, nil):
        return true
    default:
        return false
    }
}

private func archiveLoadedWebpageContentsAreEqual(_ lhs: TelegramMediaWebpageLoadedContent, _ rhs: TelegramMediaWebpageLoadedContent) -> Bool {
    guard lhs.url == rhs.url,
        lhs.displayUrl == rhs.displayUrl,
        lhs.hash == rhs.hash,
        lhs.type == rhs.type,
        lhs.websiteName == rhs.websiteName,
        lhs.title == rhs.title,
        lhs.text == rhs.text,
        lhs.embedUrl == rhs.embedUrl,
        lhs.embedType == rhs.embedType,
        lhs.embedSize == rhs.embedSize,
        lhs.duration == rhs.duration,
        lhs.author == rhs.author,
        lhs.isMediaLargeByDefault == rhs.isMediaLargeByDefault,
        lhs.imageIsVideoCover == rhs.imageIsVideoCover else {
        return false
    }
    return archiveOptionalMediaAreEqual(lhs.image, rhs.image)
        && archiveOptionalMediaAreEqual(lhs.file, rhs.file)
        && archiveOptionalMediaAreEqual(lhs.story, rhs.story)
        && archiveWebpageAttributesAreEqual(lhs.attributes, rhs.attributes)
        && archiveInstantPagesAreEqual(lhs.instantPage, rhs.instantPage)
}

private func archiveMediaAreEqual(_ lhs: Media, _ rhs: Media) -> Bool {
    // Cloud file references and access hashes are refreshed fetch credentials.
    // Strict media equality turns a history refresh into an archived edit. Keep
    // content fields explicit: general semantic equality omits file attributes,
    // covers, emoji markup and some video representation details.
    if let lhs = lhs as? TelegramMediaFile {
        guard let rhs = rhs as? TelegramMediaFile,
            lhs.fileId == rhs.fileId,
            lhs.partialReference == rhs.partialReference,
            lhs.resource.id == rhs.resource.id,
            archiveImageRepresentationsAreEqual(lhs.previewRepresentations, rhs.previewRepresentations),
            lhs.videoThumbnails.count == rhs.videoThumbnails.count,
            lhs.immediateThumbnailData == rhs.immediateThumbnailData,
            lhs.size == rhs.size,
            lhs.mimeType == rhs.mimeType,
            lhs.attributes == rhs.attributes,
            lhs.alternativeRepresentations.count == rhs.alternativeRepresentations.count else {
            return false
        }
        for i in 0 ..< lhs.videoThumbnails.count {
            if lhs.videoThumbnails[i].dimensions != rhs.videoThumbnails[i].dimensions
                || lhs.videoThumbnails[i].resource.id != rhs.videoThumbnails[i].resource.id {
                return false
            }
        }
        if !archiveOptionalMediaAreEqual(lhs.videoCover, rhs.videoCover) {
            return false
        }
        for i in 0 ..< lhs.alternativeRepresentations.count {
            if !archiveMediaAreEqual(lhs.alternativeRepresentations[i], rhs.alternativeRepresentations[i]) {
                return false
            }
        }
        return true
    } else if let lhs = lhs as? TelegramMediaImage {
        guard let rhs = rhs as? TelegramMediaImage,
            lhs.imageId == rhs.imageId,
            archiveImageRepresentationsAreEqual(lhs.representations, rhs.representations),
            lhs.videoRepresentations.count == rhs.videoRepresentations.count,
            lhs.immediateThumbnailData == rhs.immediateThumbnailData,
            lhs.emojiMarkup == rhs.emojiMarkup,
            lhs.partialReference == rhs.partialReference,
            lhs.flags == rhs.flags else {
            return false
        }
        for i in 0 ..< lhs.videoRepresentations.count {
            if lhs.videoRepresentations[i].dimensions != rhs.videoRepresentations[i].dimensions
                || lhs.videoRepresentations[i].resource.id != rhs.videoRepresentations[i].resource.id
                || lhs.videoRepresentations[i].startTimestamp != rhs.videoRepresentations[i].startTimestamp {
                return false
            }
        }
        return archiveOptionalMediaAreEqual(lhs.video, rhs.video)
    } else if let lhs = lhs as? TelegramMediaWebpage {
        guard let rhs = rhs as? TelegramMediaWebpage, lhs.webpageId == rhs.webpageId else {
            return false
        }
        switch (lhs.content, rhs.content) {
        case let (.Loaded(lhsContent), .Loaded(rhsContent)):
            return archiveLoadedWebpageContentsAreEqual(lhsContent, rhsContent)
        default:
            return lhs.isEqual(to: rhs)
        }
    } else if let lhs = lhs as? TelegramMediaPaidContent {
        guard let rhs = rhs as? TelegramMediaPaidContent,
            lhs.amount == rhs.amount,
            lhs.extendedMedia.count == rhs.extendedMedia.count else {
            return false
        }
        for i in 0 ..< lhs.extendedMedia.count {
            if !archiveExtendedMediaAreEqual(lhs.extendedMedia[i], rhs.extendedMedia[i]) {
                return false
            }
        }
        return true
    }
    return lhs.isEqual(to: rhs)
}

private func mediaArraysAreEqual(_ lhs: [Media], _ rhs: [Media]) -> Bool {
    if lhs.count != rhs.count {
        return false
    }
    for i in 0 ..< lhs.count {
        if !archiveMediaAreEqual(lhs[i], rhs[i]) {
            return false
        }
    }
    return true
}

public func deletedMessageArchiveContentsAreEqual(
    lhsText: String,
    lhsAttributes: [MessageAttribute],
    lhsMedia: [Media],
    rhsText: String,
    rhsAttributes: [MessageAttribute],
    rhsMedia: [Media]
) -> Bool {
    if lhsText != rhsText {
        return false
    }
    if !mediaArraysAreEqual(lhsMedia, rhsMedia) {
        return false
    }
    return encodedContentAttributes(lhsAttributes) == encodedContentAttributes(rhsAttributes)
}

private func archivedContentIsEqual(_ previous: Message, _ updated: StoreMessage) -> Bool {
    return deletedMessageArchiveContentsAreEqual(
        lhsText: previous.text,
        lhsAttributes: previous.attributes,
        lhsMedia: previous.media,
        rhsText: updated.text,
        rhsAttributes: updated.attributes,
        rhsMedia: updated.media
    )
}

private func isArchiveIneligible(_ message: Message) -> Bool {
    if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
        return true
    }
    if message.id.namespace != Namespaces.Message.Cloud {
        return true
    }
    return message.media.contains(where: { $0 is TelegramMediaExpiredContent })
}

private func attributesWithoutExpiry(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    return attributes.filter { attribute in
        if attribute is AutoremoveTimeoutMessageAttribute
            || attribute is AutoclearTimeoutMessageAttribute
            || attribute is ConsumableContentMessageAttribute
            || attribute is ConsumablePersonalMentionMessageAttribute {
            return false
        }
        return true
    }
}

private func makeStoredCopy(
    of message: Message,
    namespace: MessageId.Namespace,
    attributes: [MessageAttribute],
    globallyUniqueId: Int64,
    keepGlobalTags: Bool
) -> StoreMessage {
    let attributes = attributesWithoutExpiry(attributes)
    var flags = StoreMessageFlags(message.flags)
    flags.remove(.Unsent)
    flags.remove(.Failed)
    flags.remove(.Sending)
    flags.remove(.CountedAsIncoming)

    var tags = message.tags
    tags.remove(.unseenPersonalMessage)
    tags.remove(.unseenReaction)
    tags.remove(.unseenPollVote)
    tags.remove(.pinned)

    return StoreMessage(
        peerId: message.id.peerId,
        namespace: namespace,
        customStableId: nil,
        globallyUniqueId: globallyUniqueId,
        groupingKey: message.groupingKey,
        threadId: message.threadId,
        timestamp: message.timestamp,
        flags: flags,
        tags: tags,
        globalTags: keepGlobalTags ? message.globalTags : [],
        localTags: [],
        forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
        authorId: message.author?.id,
        text: message.text,
        attributes: attributes,
        media: message.media
    )
}

private func addStoredCopy(
    transaction: Transaction,
    message: Message,
    namespace: MessageId.Namespace,
    attributes: [MessageAttribute],
    keepGlobalTags: Bool = false,
    mediaBox: MediaBox? = nil
) -> MessageId? {
    let globallyUniqueId = Int64.random(in: Int64.min ... Int64.max)
    let copy = makeStoredCopy(
        of: message,
        namespace: namespace,
        attributes: attributes,
        globallyUniqueId: globallyUniqueId,
        keepGlobalTags: keepGlobalTags
    )
    let id = transaction.addMessages([copy], location: .Random)[globallyUniqueId]
    if id != nil, let mediaBox {
        deletedMessageArchiveMediaRetentions.with({ $0[mediaBox.basePath] })?.protect(resourceIds: archivedResourceIds(message))
    }
    return id
}

private func canArchiveMessageFromChat(transaction: Transaction, peerId: PeerId, settings: DeletedMessageArchiveSettings) -> Bool {
    if settings.saveMessagesFromArchivedChats {
        return true
    }
    return transaction.getPeerChatListInclusion(peerId).groupId != Namespaces.PeerGroup.archive
}

func archivePreviousMessageVersionIfNeeded(
    transaction: Transaction,
    id: MessageId,
    updatedMessage: StoreMessage,
    mediaBox: MediaBox? = nil,
    batch: DeletedMessageArchiveBatch? = nil
) -> StoreMessage {
    guard let settings = prepareDeletedMessageArchive(transaction: transaction, mediaBox: mediaBox, batch: batch), settings.saveEditedVersions else {
        return updatedMessage
    }
    let updatedMessage = attachNikitaPendingVersions(transaction: transaction, id: id, updated: updatedMessage, batch: batch)
    guard let previous = transaction.getMessage(id), !isArchiveIneligible(previous) else {
        return updatedMessage
    }

    let previousArchiveAttribute = archiveAttribute(updatedMessage.attributes) ?? archiveAttribute(previous.attributes)
    if !canArchiveMessageFromChat(transaction: transaction, peerId: id.peerId, settings: settings) {
        guard let previousArchiveAttribute else {
            return updatedMessage
        }
        var attributes = attributesWithoutArchiveMetadata(updatedMessage.attributes)
        attributes.append(previousArchiveAttribute)
        return updatedMessage.withUpdatedAttributes(attributes)
    }
    if archivedContentIsEqual(previous, updatedMessage) {
        guard let previousArchiveAttribute else {
            return updatedMessage
        }
        var attributes = attributesWithoutArchiveMetadata(updatedMessage.attributes)
        attributes.append(previousArchiveAttribute)
        return updatedMessage.withUpdatedAttributes(attributes)
    }

    let capturedAt = updatedMessage.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.first ?? archiveTimestamp()
    var snapshotAttributes = attributesWithoutArchiveMetadata(previous.attributes)
    snapshotAttributes.append(ArchivedMessageVersionAttribute(capturedAt: capturedAt))
    guard let snapshotId = addStoredCopy(
        transaction: transaction,
        message: previous,
        namespace: Namespaces.Message.ArchivedVersion,
        attributes: snapshotAttributes,
        mediaBox: mediaBox
    ) else {
        return updatedMessage
    }
    appendDeletedMessageArchiveSnapshot(transaction: transaction, batch: batch, snapshot: snapshotId, live: id)
    if let mediaBox {
        requestDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox, batch: batch)
    }

    var versionIds = previousArchiveAttribute?.versionIds ?? []
    if versionIds.last != snapshotId {
        versionIds.append(snapshotId)
    }
    let updatedArchiveAttribute = ArchivedMessageAttribute(
        originalMessageId: previousArchiveAttribute?.originalMessageId ?? previous.id,
        versionIds: versionIds,
        deletedAt: nil,
        sessionId: previousArchiveAttribute?.sessionId ?? deletedMessageArchiveSessionId
    )
    var attributes = attributesWithoutArchiveMetadata(updatedMessage.attributes)
    attributes.append(updatedArchiveAttribute)
    return updatedMessage.withUpdatedAttributes(attributes)
}

@discardableResult
func archiveMessagesBeforeCloudDeletion(
    transaction: Transaction,
    ids: [MessageId],
    deletedAt: Int32 = archiveTimestamp(),
    mediaBox: MediaBox? = nil,
    batch: DeletedMessageArchiveBatch? = nil
) -> [MessageId] {
    guard let settings = prepareDeletedMessageArchive(transaction: transaction, mediaBox: mediaBox, batch: batch) else {
        return []
    }
    var archiveIds: [MessageId] = []
    var excludedIds: [MessageId] = []
    for id in ids {
        if canArchiveMessageFromChat(transaction: transaction, peerId: id.peerId, settings: settings) {
            archiveIds.append(id)
        } else {
            excludedIds.append(id)
        }
    }
    if !excludedIds.isEmpty {
        removeDeletedMessageArchiveForLocalDeletion(transaction: transaction, mediaBox: mediaBox, ids: excludedIds, batch: batch)
    }
    if !settings.saveDeletedMessages {
        removeDeletedMessageArchiveForLocalDeletion(transaction: transaction, mediaBox: mediaBox, ids: ids, batch: batch)
        return []
    }
    var result: [MessageId] = []
    for id in archiveIds {
        guard let message = transaction.getMessage(id), !isArchiveIneligible(message) else {
            continue
        }
        let previousArchiveAttribute = archiveAttribute(message.attributes)
        var attributes = attributesWithoutArchiveMetadata(message.attributes)
        attributes.append(ArchivedMessageAttribute(
            originalMessageId: previousArchiveAttribute?.originalMessageId ?? message.id,
            versionIds: previousArchiveAttribute?.versionIds ?? [],
            deletedAt: deletedAt,
            sessionId: previousArchiveAttribute?.sessionId ?? deletedMessageArchiveSessionId
        ))
        if let archivedId = addStoredCopy(
            transaction: transaction,
            message: message,
            namespace: Namespaces.Message.Archived,
            attributes: attributes,
            mediaBox: mediaBox
        ) {
            result.append(archivedId)
        }
    }
    if !result.isEmpty {
        mutateDeletedMessageArchiveIndex(transaction: transaction, batch: batch, { current in
            current.messageIds.append(contentsOf: result.map(DeletedMessageArchiveIndexEntry.init))
            let deletedEntries = Set(ids.map(DeletedMessageArchiveIndexEntry.init))
            current.liveMessageIds.removeAll(where: { deletedEntries.contains($0) })
        })
        if let mediaBox {
            requestDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox, batch: batch)
        }
    }
    return result
}

func _internal_deleteArchivedMessage(transaction: Transaction, mediaBox: MediaBox, id: MessageId) {
    guard id.namespace == Namespaces.Message.Archived, let message = transaction.getMessage(id) else {
        return
    }
    let versionIds = message.archivedMessageAttribute?.versionIds ?? []
    transaction.deleteMessages(versionIds + [id], forEachMedia: nil)
    let removedIds = Set((versionIds + [id]).map(DeletedMessageArchiveIndexEntry.init))
    updateDeletedMessageArchiveIndex(transaction: transaction, { current in
        var current = current
        current.messageIds.removeAll(where: { removedIds.contains($0) })
        return current
    })
    updateDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox)
}

func removeDeletedMessageArchiveForLocalDeletion(transaction: Transaction, mediaBox: MediaBox?, ids: [MessageId], batch: DeletedMessageArchiveBatch? = nil) {
    var versionIds: [MessageId] = []
    var archivedSourceIds: [MessageId] = []
    var resourceIds = Set<MediaResourceId>()
    for id in ids {
        guard let message = transaction.getMessage(id), let attribute = message.archivedMessageAttribute else {
            continue
        }
        archivedSourceIds.append(id)
        versionIds.append(contentsOf: attribute.versionIds)
        resourceIds.formUnion(archivedResourceIds(message))
        for versionId in attribute.versionIds {
            if let version = transaction.getMessage(versionId) {
                resourceIds.formUnion(archivedResourceIds(version))
            }
        }
    }
    guard !archivedSourceIds.isEmpty else {
        return
    }
    if !versionIds.isEmpty {
        transaction.deleteMessages(versionIds, forEachMedia: nil)
    }
    if let mediaBox, !resourceIds.isEmpty {
        let _ = mediaBox.removeCachedResources(Array(resourceIds), force: true).start()
    }
    let removedStoredEntries = Set(versionIds.map(DeletedMessageArchiveIndexEntry.init))
    let removedLiveEntries = Set(archivedSourceIds.map(DeletedMessageArchiveIndexEntry.init))
    mutateDeletedMessageArchiveIndex(transaction: transaction, batch: batch, { current in
        current.messageIds.removeAll(where: { removedStoredEntries.contains($0) })
        current.liveMessageIds.removeAll(where: { removedLiveEntries.contains($0) })
    })
    if let mediaBox {
        requestDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox, batch: batch)
    }
}

func _internal_archivedMessageVersions(transaction: Transaction, id: MessageId) -> [Message] {
    guard let message = transaction.getMessage(id), let attribute = message.archivedMessageAttribute else {
        return []
    }
    var result = attribute.versionIds.compactMap(transaction.getMessage).sorted {
        return ($0.archivedVersionCapturedAt ?? $0.timestamp) < ($1.archivedVersionCapturedAt ?? $1.timestamp)
    }
    result.append(message)
    return result
}

func _internal_clearDeletedMessageArchive(transaction: Transaction) {
    let index = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty
    transaction.deleteMessages(index.messageIds.map(\.messageId), forEachMedia: nil)
    removeDeletedMessageArchiveMetadata(transaction: transaction, ids: index.liveMessageIds.map(\.messageId))
    updateDeletedMessageArchiveIndex(transaction: transaction, { _ in .empty })
    transaction.updatePreferencesEntry(key: PreferencesKeys.nikitaServerArchive, { entry in
        guard var state = entry?.get(NikitaRemoteArchiveState.self) else { return entry }
        state.pendingVersions.removeAll()
        return PreferencesEntry(state)
    })
}

private func nikitaArchiveMessageKey(_ id: MessageId) -> String {
    return "\(id.peerId.toInt64()):\(id.id)"
}

private func attachNikitaPendingVersions(transaction: Transaction, id: MessageId, updated: StoreMessage, batch: DeletedMessageArchiveBatch? = nil) -> StoreMessage {
    let pending: [DeletedMessageArchiveIndexEntry]
    if let batch {
        guard let versions = batch.takePendingVersions(for: nikitaArchiveMessageKey(id)) else { return updated }
        pending = versions
    } else {
        guard var state = transaction.getPreferencesEntry(key: PreferencesKeys.nikitaServerArchive)?.get(NikitaRemoteArchiveState.self),
            let versions = state.pendingVersions.removeValue(forKey: nikitaArchiveMessageKey(id)) else { return updated }
        pending = versions
        transaction.updatePreferencesEntry(key: PreferencesKeys.nikitaServerArchive, { _ in PreferencesEntry(state) })
    }
    var ids = archiveAttribute(updated.attributes)?.versionIds ?? transaction.getMessage(id)?.archivedMessageAttribute?.versionIds ?? []
    for entry in pending where transaction.getMessage(entry.messageId) != nil && !ids.contains(entry.messageId) {
        ids.append(entry.messageId)
    }
    guard !ids.isEmpty else { return updated }
    appendDeletedMessageArchiveLiveMessage(transaction: transaction, batch: batch, id: id)
    var attributes = attributesWithoutArchiveMetadata(updated.attributes)
    attributes.append(ArchivedMessageAttribute(originalMessageId: id, versionIds: ids, deletedAt: nil, sessionId: deletedMessageArchiveSessionId))
    return updated.withUpdatedAttributes(attributes)
}

private func nikitaArchiveStoredUpdate(_ message: Message, attribute: ArchivedMessageAttribute) -> StoreMessage {
    var attributes = attributesWithoutArchiveMetadata(message.attributes)
    attributes.append(attribute)
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId,
        groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp,
        flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags,
        localTags: message.localTags, forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
        authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media)
}

private func nikitaArchiveContentMatches(_ message: Message, event: NikitaRemoteArchiveEvent) -> Bool {
    if message.media.isEmpty && message.text == event.displayText { return true }
    if message.media.isEmpty && event.media != nil && !event.mediaTitle.isEmpty {
        let legacy = event.text.isEmpty ? "[\(event.mediaTitle)]" : "\(event.text)\n[\(event.mediaTitle)]"
        if message.text == legacy { return true }
    }
    guard message.text == event.text else { return false }
    guard let mediaId = event.mediaId else { return message.media.isEmpty }
    return message.media.contains { media in
        if let file = media as? TelegramMediaFile { return file.fileId.id == mediaId }
        if let image = media as? TelegramMediaImage { return image.imageId.id == mediaId }
        return false
    }
}

private func reuseNikitaArchiveCachedMedia(_ original: [Media], remote: [Media], mediaBox: MediaBox) {
    func copy(_ source: TelegramMediaResource, _ destination: TelegramMediaResource) {
        guard let destination = destination as? NikitaArchiveMediaResource, source.id != destination.id,
            mediaBox.completedResourcePath(id: destination.id) == nil,
            let path = mediaBox.completedResourcePath(id: source.id),
            let size = fileSize(path), size == destination.size else { return }
        // Copy on MediaBox's queue, without loading a video into application RAM.
        mediaBox.copyResourceData(from: source.id, to: destination.id)
    }
    for item in remote {
        for existing in original {
            if let file = item as? TelegramMediaFile, let previous = existing as? TelegramMediaFile, file.fileId == previous.fileId {
                copy(previous.resource, file.resource)
                for representation in file.previewRepresentations {
                    for old in previous.previewRepresentations where old.dimensions == representation.dimensions {
                        copy(old.resource, representation.resource)
                    }
                }
            } else if let image = item as? TelegramMediaImage, let previous = existing as? TelegramMediaImage, image.imageId == previous.imageId {
                for representation in image.representations {
                    for old in previous.representations where old.dimensions == representation.dimensions {
                        copy(old.resource, representation.resource)
                    }
                }
            }
        }
    }
}

private func nikitaArchiveMediaTags(incoming: Bool, attributes: [MessageAttribute], media: [Media]) -> MessageTags {
    let entities = attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities
    var tags = tagsForStoreMessage(incoming: incoming, attributes: attributes, media: media, textEntities: entities, isPinned: false).0
    tags.remove(.unseenPersonalMessage)
    tags.remove(.unseenReaction)
    tags.remove(.unseenPollVote)
    tags.remove(.pinned)
    return tags
}

func importNikitaArchiveEvents(transaction: Transaction, mediaBox: MediaBox,
    events: [NikitaRemoteArchiveEvent], accountId: Int64, serverId: String, state: inout NikitaRemoteArchiveState) -> Int? {
    // Idle polling must not decode/rewrite the full local archive or load every
    // archived message. The sync cursor/server state is committed by the caller.
    guard !events.isEmpty else { return 0 }
    guard let settings = prepareDeletedMessageArchive(transaction: transaction, mediaBox: mediaBox) else { return nil }
    let events = events.filter { event in
        guard let originalId = event.originalId else { return false }
        return canArchiveMessageFromChat(transaction: transaction, peerId: originalId.peerId, settings: settings)
            && ((event.kind == "edit" && settings.saveEditedVersions) || (event.kind == "delete" && settings.saveDeletedMessages))
    }
    guard !events.isEmpty else { return 0 }
    var index = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty
    let initialIndex = index
    let originalIds = Set(events.compactMap(\.originalId))
    let peerIds = Set(originalIds.map { $0.peerId.toInt64() })
    var archivedByOriginal: [MessageId: MessageId] = [:]
    // Entries include the peer already; unrelated chats need no message loads.
    for entry in index.messageIds where entry.namespace == Namespaces.Message.Archived && peerIds.contains(entry.peerId) {
        if let message = transaction.getMessage(entry.messageId), let attribute = message.archivedMessageAttribute,
            originalIds.contains(attribute.originalMessageId) {
            archivedByOriginal[attribute.originalMessageId] = message.id
        }
    }
    var count = 0
    var failed = false
    var invalidatedMediaIds = Set<MessageId>()
    for event in events {
        guard let originalId = event.originalId else { continue }
        let key = nikitaArchiveMessageKey(originalId)
        let current = transaction.getMessage(originalId)
        let remoteMedia: [Media] = event.media.flatMap { $0.nativeMedia(accountId: accountId, serverId: serverId) }.map { [$0] } ?? []
        let archived = archivedByOriginal[originalId].flatMap(transaction.getMessage)
        reuseNikitaArchiveCachedMedia((current?.media ?? []) + (archived?.media ?? []), remote: remoteMedia, mediaBox: mediaBox)
        let target = archived ?? current
        var versionIds = target?.archivedMessageAttribute?.versionIds ?? []
        for entry in state.pendingVersions[key] ?? [] where !versionIds.contains(entry.messageId) {
            versionIds.append(entry.messageId)
        }
        versionIds = versionIds.filter { transaction.getMessage($0) != nil }

        func makeCopy(namespace: Int32, attributes: [MessageAttribute]) -> MessageId? {
            if remoteMedia.isEmpty, let current, nikitaArchiveContentMatches(current, event: event) {
                return addStoredCopy(transaction: transaction, message: current, namespace: namespace,
                    attributes: attributesWithoutArchiveMetadata(current.attributes) + attributes, mediaBox: mediaBox)
            }
            let uniqueId = Int64.random(in: Int64.min ... Int64.max)
            let source = current.flatMap { nikitaArchiveContentMatches($0, event: event) ? $0 : nil }
            var attributes = (source.map { attributesWithoutArchiveMetadata($0.attributes) } ?? []) + attributes
            if source == nil, let versionDate = event.versionDate, versionDate > event.date {
                attributes.append(EditedMessageAttribute(date: versionDate, isHidden: false))
            }
            if event.spoiler == true, !attributes.contains(where: { $0 is MediaSpoilerMessageAttribute }) {
                attributes.append(MediaSpoilerMessageAttribute())
            }
            attributes = attributesWithoutExpiry(attributes)
            let tags = nikitaArchiveMediaTags(incoming: !event.outgoing, attributes: attributes, media: remoteMedia)
            let copy = StoreMessage(peerId: originalId.peerId, namespace: namespace, customStableId: nil,
                globallyUniqueId: uniqueId, groupingKey: event.groupedId, threadId: event.threadId, timestamp: event.date,
                flags: event.outgoing ? [] : [.Incoming], tags: tags, globalTags: [], localTags: [], forwardInfo: nil,
                authorId: event.resolvedAuthorId, text: event.displayText, attributes: attributes, media: remoteMedia)
            let id = transaction.addMessages([copy], location: .Random)[uniqueId]
            if id != nil {
                deletedMessageArchiveMediaRetentions.with({ $0[mediaBox.basePath] })?.protect(resourceIds: archivedResourceIds(media: copy.media))
            }
            return id
        }

        if event.kind == "edit" {
            let alreadySaved = versionIds.contains { id in
                guard let version = transaction.getMessage(id) else { return false }
                let matches = version.archivedVersionCapturedAt == event.capturedAt && nikitaArchiveContentMatches(version, event: event)
                if matches && !remoteMedia.isEmpty {
                    invalidatedMediaIds.insert(id)
                    deletedMessageArchiveMediaRetentions.with({ $0[mediaBox.basePath] })?.protect(resourceIds: archivedResourceIds(media: remoteMedia))
                    reuseNikitaArchiveCachedMedia(version.media, remote: remoteMedia, mediaBox: mediaBox)
                    transaction.updateMessage(id, update: { message in
                        let attributes = attributesWithoutExpiry(message.attributes)
                        let tags = nikitaArchiveMediaTags(incoming: !event.outgoing, attributes: attributes, media: remoteMedia)
                        return .update(StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId,
                            groupingKey: event.groupedId, threadId: event.threadId, timestamp: event.date,
                            flags: StoreMessageFlags(message.flags), tags: tags, globalTags: message.globalTags, localTags: message.localTags,
                            forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: event.resolvedAuthorId,
                            text: event.displayText, attributes: attributes, media: remoteMedia))
                    })
                }
                return matches
            }
            if !alreadySaved {
                if let id = makeCopy(namespace: Namespaces.Message.ArchivedVersion,
                    attributes: [ArchivedMessageVersionAttribute(capturedAt: event.capturedAt)]) {
                    versionIds.append(id)
                    index.messageIds.append(DeletedMessageArchiveIndexEntry(id))
                    count += 1
                } else {
                    failed = true
                }
            }
            if let target {
                let attribute = ArchivedMessageAttribute(originalMessageId: originalId, versionIds: versionIds,
                    deletedAt: target.archivedMessageAttribute?.deletedAt, sessionId: deletedMessageArchiveSessionId)
                transaction.updateMessage(target.id, update: { message in .update(nikitaArchiveStoredUpdate(message, attribute: attribute)) })
                if target.id.namespace == Namespaces.Message.Cloud {
                    let entry = DeletedMessageArchiveIndexEntry(target.id)
                    if !index.liveMessageIds.contains(entry) { index.liveMessageIds.append(entry) }
                }
                state.pendingVersions.removeValue(forKey: key)
            } else {
                // The app may not have fetched this chat yet. Attach its references
                // when the ordinary Telegram history later supplies the message.
                state.pendingVersions[key] = versionIds.map(DeletedMessageArchiveIndexEntry.init)
            }
        } else {
            if let archived {
                let localVersionDate = archived.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.first ?? archived.timestamp
                let remoteVersionDate = event.versionDate ?? event.date
                let different = !nikitaArchiveContentMatches(archived, event: event)
                let useRemote = (different && remoteVersionDate >= localVersionDate) || (!different && !remoteMedia.isEmpty)
                if different {
                    let hasOtherCopy = versionIds.contains { id in
                        guard let version = transaction.getMessage(id) else { return false }
                        return useRemote ? version.text == archived.text && mediaArraysAreEqual(version.media, archived.media)
                            : nikitaArchiveContentMatches(version, event: event)
                    }
                    if !hasOtherCopy {
                        let snapshotId: MessageId?
                        if useRemote {
                            snapshotId = addStoredCopy(transaction: transaction, message: archived, namespace: Namespaces.Message.ArchivedVersion,
                                attributes: attributesWithoutArchiveMetadata(archived.attributes) + [ArchivedMessageVersionAttribute(capturedAt: event.capturedAt)], mediaBox: mediaBox)
                        } else {
                            snapshotId = makeCopy(namespace: Namespaces.Message.ArchivedVersion,
                                attributes: [ArchivedMessageVersionAttribute(capturedAt: event.capturedAt)])
                        }
                        guard let snapshotId else { failed = true; continue }
                        versionIds.append(snapshotId)
                        index.messageIds.append(DeletedMessageArchiveIndexEntry(snapshotId))
                        count += 1
                    }
                }
                let attribute = ArchivedMessageAttribute(originalMessageId: originalId, versionIds: versionIds,
                    deletedAt: event.capturedAt, sessionId: deletedMessageArchiveSessionId)
                invalidatedMediaIds.insert(archived.id)
                deletedMessageArchiveMediaRetentions.with({ $0[mediaBox.basePath] })?.protect(resourceIds: archivedResourceIds(media: remoteMedia))
                transaction.updateMessage(archived.id, update: { message in
                    if !useRemote { return .update(nikitaArchiveStoredUpdate(message, attribute: attribute)) }
                    let source = current.flatMap { nikitaArchiveContentMatches($0, event: event) ? $0 : nil }
                    var attributes = source.map { attributesWithoutArchiveMetadata($0.attributes) } ?? []
                    if source == nil, remoteVersionDate > event.date {
                        attributes.append(EditedMessageAttribute(date: remoteVersionDate, isHidden: false))
                    }
                    attributes.append(attribute)
                    if event.spoiler == true, !attributes.contains(where: { $0 is MediaSpoilerMessageAttribute }) {
                        attributes.append(MediaSpoilerMessageAttribute())
                    }
                    attributes = attributesWithoutExpiry(attributes)
                    let storedMedia = remoteMedia.isEmpty ? source?.media ?? [] : remoteMedia
                    let tags = nikitaArchiveMediaTags(incoming: !event.outgoing, attributes: attributes, media: storedMedia)
                    return .update(StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId,
                        groupingKey: event.groupedId ?? source?.groupingKey, threadId: event.threadId, timestamp: event.date,
                        flags: event.outgoing ? [] : [.Incoming], tags: tags, globalTags: [], localTags: [],
                        forwardInfo: source?.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: event.resolvedAuthorId,
                        text: source?.text ?? event.displayText, attributes: attributes, media: storedMedia))
                })
            } else {
                let attribute = ArchivedMessageAttribute(originalMessageId: originalId, versionIds: versionIds,
                    deletedAt: event.capturedAt, sessionId: deletedMessageArchiveSessionId)
                if let id = makeCopy(namespace: Namespaces.Message.Archived, attributes: [attribute]) {
                    archivedByOriginal[originalId] = id
                    index.messageIds.append(DeletedMessageArchiveIndexEntry(id))
                    count += 1
                } else {
                    failed = true
                }
            }
            if archivedByOriginal[originalId] != nil {
                transaction.deleteMessages([originalId], forEachMedia: nil)
                index.liveMessageIds.removeAll(where: { $0.messageId == originalId })
                state.pendingVersions.removeValue(forKey: key)
            }
        }
    }
    if index != initialIndex {
        updateDeletedMessageArchiveIndex(transaction: transaction, { _ in index })
    }
    if count != 0 || !invalidatedMediaIds.isEmpty {
        updateDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox, index: index, invalidatedIds: invalidatedMediaIds)
    }
    return failed ? nil : count
}

func _internal_clearDeletedMessageArchiveMedia(transaction: Transaction, mediaBox: MediaBox) {
    deletedMessageArchiveMediaRetentions.with({ $0[mediaBox.basePath] })?.releasePins(markInitialPinsRestored: true)
    let index = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty
    var resourceIds = Set<MediaResourceId>()
    for entry in index.messageIds {
        if let message = transaction.getMessage(entry.messageId) {
            resourceIds.formUnion(archivedResourceIds(message))
        }
    }
    if !resourceIds.isEmpty {
        let _ = mediaBox.removeCachedResources(Array(resourceIds), force: true).start()
    }
}

public struct DeletedMessageArchiveStats: Equatable {
    public let messageCount: Int
    public let versionCount: Int
    public let mediaSize: Int64
}

func _internal_deletedMessageArchiveStats(transaction: Transaction, mediaBox: MediaBox) -> DeletedMessageArchiveStats {
    let index = transaction.getPreferencesEntry(key: PreferencesKeys.deletedMessageArchiveIndex)?.get(DeletedMessageArchiveIndex.self) ?? .empty
    var messageCount = 0
    var versionCount = 0
    var resourceIds = Set<MediaResourceId>()
    for entry in index.messageIds {
        guard let message = transaction.getMessage(entry.messageId) else {
            continue
        }
        if message.id.namespace == Namespaces.Message.Archived {
            messageCount += 1
        } else if message.id.namespace == Namespaces.Message.ArchivedVersion {
            versionCount += 1
        }
        resourceIds.formUnion(archivedResourceIds(message))
    }
    var mediaSize: Int64 = 0
    for id in resourceIds {
        if let path = mediaBox.completedResourcePath(id: id) {
            mediaSize += fileSize(path) ?? 0
        }
    }
    return DeletedMessageArchiveStats(messageCount: messageCount, versionCount: versionCount, mediaSize: mediaSize)
}

func _internal_refreshDeletedMessageArchiveMediaLimit(transaction: Transaction, mediaBox: MediaBox) {
    updateDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: mediaBox, refreshSizes: true)
}

func initializeDeletedMessageArchiveSession(postbox: Postbox) -> Signal<Never, NoError> {
    let _ = deletedMessageArchiveMediaRetentions.modify { current in
        var current = current.filter { $0.value.isAlive }
        current[postbox.mediaBox.basePath]?.releasePins()
        current[postbox.mediaBox.basePath] = DeletedMessageArchiveMediaRetention(postbox: postbox)
        return current
    }
    let _ = deletedMessageArchiveSessionInitialized.swap(true)
    return postbox.transaction { transaction -> Void in
        _ = prepareDeletedMessageArchive(transaction: transaction, mediaBox: postbox.mediaBox)
        updateDeletedMessageArchiveMediaRetention(transaction: transaction, mediaBox: postbox.mediaBox)
    }
    |> ignoreValues
}

func deletedMessageArchiveInitialMediaPinsRestored(postbox: Postbox) -> Signal<Bool, NoError> {
    return deletedMessageArchiveMediaRetentions.with({ $0[postbox.mediaBox.basePath]?.initialMediaPinsRestored }) ?? .single(true)
}

