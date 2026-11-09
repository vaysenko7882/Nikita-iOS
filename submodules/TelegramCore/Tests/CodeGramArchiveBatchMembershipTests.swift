import Postbox
@testable import TelegramCore
import XCTest

final class CodeGramArchiveBatchMembershipTests: XCTestCase {
    private func entry(_ id: Int32, namespace: Int32 = Namespaces.Message.Cloud) -> DeletedMessageArchiveIndexEntry {
        return DeletedMessageArchiveIndexEntry(MessageId(peerId: PeerId(123), namespace: namespace, id: id))
    }

    func testTenThousandSnapshotsBuildLiveMembershipOnce() {
        let existing = (1 ... 10_000).map { self.entry(Int32($0)) }
        let added = (10_001 ... 20_000).map { self.entry(Int32($0)) }
        let snapshots = (1 ... 10_000).map { self.entry(Int32($0), namespace: Namespaces.Message.ArchivedVersion) }
        var index = DeletedMessageArchiveIndex(messageIds: [], liveMessageIds: existing)
        var reads = 0, writes = 0
        let batch = DeletedMessageArchiveBatch(loadSettings: { .defaultSettings }, loadIndex: {
            reads += 1
            return index
        }, saveIndex: {
            writes += 1
            index = $0
        }, loadRemoteState: { nil }, saveRemoteState: { _ in XCTFail("No pending versions") },
            retainMedia: { _, _ in XCTFail("Index membership must not request media retention") })
        for i in snapshots.indices { batch.appendSnapshot(snapshots[i], live: added[i]) }
        for entry in existing + added { batch.appendLiveMessage(entry) }
        batch.finish()

        XCTAssertEqual(batch.liveMessageIndexBuildCount, 1,
            "10,000 edits must not repeatedly scan the growing 10,000-entry live index")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(index.messageIds, snapshots)
        XCTAssertEqual(index.liveMessageIds, existing + added)
        // The previous Array.contains path performed L*E + E*(E-1)/2
        // comparisons for distinct appends: 149,995,000 for this fixture.
    }

    func testGenericMutationInvalidatesMembershipWithoutLosingReaddedEntries() {
        let first = self.entry(1), second = self.entry(2), third = self.entry(3)
        var index = DeletedMessageArchiveIndex(messageIds: [], liveMessageIds: [first])
        let batch = DeletedMessageArchiveBatch(loadSettings: { .defaultSettings }, loadIndex: { index },
            saveIndex: { index = $0 }, loadRemoteState: { nil }, saveRemoteState: { _ in }, retainMedia: { _, _ in })
        batch.appendLiveMessage(second)
        batch.updateIndex {
            $0.liveMessageIds.removeAll(where: { $0 == first })
            $0.liveMessageIds.append(third)
        }
        batch.appendLiveMessage(first)
        batch.appendLiveMessage(third)
        batch.finish()

        XCTAssertEqual(index.liveMessageIds, [second, third, first])
        XCTAssertEqual(batch.liveMessageIndexBuildCount, 2)
    }

    func testExistingLiveEntryDoesNotRewriteIndex() {
        let entry = self.entry(1)
        let index = DeletedMessageArchiveIndex(messageIds: [], liveMessageIds: [entry])
        var writes = 0
        let batch = DeletedMessageArchiveBatch(loadSettings: { .defaultSettings }, loadIndex: { index },
            saveIndex: { _ in writes += 1 }, loadRemoteState: { nil }, saveRemoteState: { _ in }, retainMedia: { _, _ in })
        batch.appendLiveMessage(entry)
        batch.finish()

        XCTAssertEqual(writes, 0)
    }
}
