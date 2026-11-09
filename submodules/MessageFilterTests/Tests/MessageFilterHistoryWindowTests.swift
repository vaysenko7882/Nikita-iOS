import TelegramUIPreferences
import XCTest

final class MessageFilterHistoryWindowTests: XCTestCase {
    private func loadedCounts(authors: [Int64], settings: MessageFilterSettings) -> [Int] {
        var count = MessageFilterHistoryWindow.initialMessageCount
        var result: [Int] = []
        while true {
            let messages = authors.prefix(count)
            result.append(messages.count)
            let hiddenCount = messages.reduce(0, { $0 + (settings.hidesMessages(fromAuthorId: $1) ? 1 : 0) })
            guard let expandedCount = MessageFilterHistoryWindow.expandedMessageCount(currentCount: count, loadedMessageCount: messages.count, hiddenMessageCount: hiddenCount, hasMoreMessages: messages.count < authors.count) else {
                return result
            }
            XCTAssertGreaterThan(expandedCount, count)
            count = expandedCount
        }
    }

    func testFiltersInOtherChatsKeepNormalHistoryWindow() {
        let settings = MessageFilterSettings(hideBlockedUsersMessages: true, shadowBannedPeerIds: Set(1 ... 10_000), blockedPeerIdsCache: [10_001])
        XCTAssertTrue(settings.isActive)
        XCTAssertEqual(self.loadedCounts(authors: Array(repeating: 20_000, count: 1_000), settings: settings), [44])
    }

    func testSparseHiddenMessagesOnlyReplaceMissingSlots() {
        let settings = MessageFilterSettings(hideBlockedUsersMessages: false, shadowBannedPeerIds: [42], blockedPeerIdsCache: [])
        var authors = Array(repeating: Int64(7), count: 1_000)
        authors[0] = 42
        XCTAssertEqual(self.loadedCounts(authors: authors, settings: settings), [44, 46])
    }

    func testEntirelyHiddenHistoryRemainsBounded() {
        let settings = MessageFilterSettings(hideBlockedUsersMessages: true, shadowBannedPeerIds: [], blockedPeerIdsCache: [42])
        XCTAssertEqual(self.loadedCounts(authors: Array(repeating: 42, count: 1_000), settings: settings), [44, 512])
    }

    func testHiddenPrefixFindsVisibleMessages() {
        let settings = MessageFilterSettings(hideBlockedUsersMessages: false, shadowBannedPeerIds: [42], blockedPeerIdsCache: [])
        let authors = Array(repeating: Int64(42), count: 100) + Array(repeating: Int64(7), count: 1_000)
        let counts = self.loadedCounts(authors: authors, settings: settings)
        XCTAssertGreaterThanOrEqual(counts.last!, 144)
        XCTAssertEqual(counts, [44, 512])
    }

    func testExhaustedHistoryDoesNotKeepReloading() {
        let settings = MessageFilterSettings(hideBlockedUsersMessages: false, shadowBannedPeerIds: [42], blockedPeerIdsCache: [])
        XCTAssertEqual(self.loadedCounts(authors: Array(repeating: 42, count: 20), settings: settings), [20])
    }
}
