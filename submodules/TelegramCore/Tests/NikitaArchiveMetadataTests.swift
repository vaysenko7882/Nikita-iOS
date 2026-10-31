import Postbox
@testable import TelegramCore
import XCTest

final class NikitaArchiveMetadataTests: XCTestCase {
    private var originalId: MessageId { return MessageId(peerId: PeerId(123), namespace: Namespaces.Message.Cloud, id: 10) }
    private var versionId: MessageId { return MessageId(peerId: PeerId(123), namespace: Namespaces.Message.ArchivedVersion, id: 1) }

    func testNetworkRefreshRetainsTheRevisionReferences() {
        let archive = ArchivedMessageAttribute(originalMessageId: self.originalId, versionIds: [self.versionId], deletedAt: nil, sessionId: 7)
        var incoming: [MessageAttribute] = [EditedMessageAttribute(date: 110, isHidden: false)]
        mergeNikitaArchiveMetadata(previous: [archive], updated: &incoming)
        let restored = incoming.compactMap { $0 as? ArchivedMessageAttribute }.first
        XCTAssertEqual(restored?.versionIds, [self.versionId])
        XCTAssertEqual(incoming.count, 2)
    }

    func testNewRevisionMetadataWinsOverOlderReferences() {
        let old = ArchivedMessageAttribute(originalMessageId: self.originalId, versionIds: [], deletedAt: nil, sessionId: 7)
        let new = ArchivedMessageAttribute(originalMessageId: self.originalId, versionIds: [self.versionId], deletedAt: nil, sessionId: 7)
        var incoming: [MessageAttribute] = [new]
        mergeNikitaArchiveMetadata(previous: [old], updated: &incoming)
        XCTAssertEqual((incoming[0] as? ArchivedMessageAttribute)?.versionIds, [self.versionId])
        XCTAssertEqual(incoming.count, 1)
    }

    func testExplicitClearRemovesMetadataWithoutLeavingASerializedMarker() {
        let archive = ArchivedMessageAttribute(originalMessageId: self.originalId, versionIds: [self.versionId], deletedAt: nil, sessionId: 7)
        let edited = EditedMessageAttribute(date: 110, isHidden: false)
        var incoming: [MessageAttribute] = [edited, NikitaArchiveMetadataResetAttribute()]
        mergeNikitaArchiveMetadata(previous: [archive], updated: &incoming)
        XCTAssertEqual(incoming.count, 1)
        XCTAssertTrue(incoming[0] is EditedMessageAttribute)
    }
}
