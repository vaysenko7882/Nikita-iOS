import Foundation

/// Telegram's blockedSlice can also be the final response. The request cursor
/// counts raw entries returned by the server, not successfully rendered peers:
/// duplicate or unavailable peers must not make pagination repeat an offset.
struct BlockedPeersPageProgress {
    let nextOffset: Int32
    let canLoadMore: Bool

    init(requestOffset: Int32, returnedCount: Int, totalCount: Int?) {
        let offset = max(0, requestOffset)
        let count = max(0, returnedCount)
        let remaining = Int(Int32.max - offset)
        self.nextOffset = offset + Int32(min(remaining, count))
        if let totalCount {
            self.canLoadMore = count > 0 && self.nextOffset > offset && self.nextOffset < Int32.max && Int(self.nextOffset) < max(0, totalCount)
        } else {
            self.canLoadMore = false
        }
    }
}

struct BlockedPeersPagination {
    private(set) var nextOffset: Int32 = 0
    private(set) var generation: UInt64 = 0

    mutating func restart() {
        self.generation &+= 1
        self.nextOffset = 0
    }

    /// A response queued before a local mutation must neither restore removed
    /// peers nor overwrite the restarted cursor after cancellation.
    mutating func completePage(generation: UInt64, returnedCount: Int, totalCount: Int?) -> Bool? {
        guard self.generation == generation else { return nil }
        let progress = BlockedPeersPageProgress(requestOffset: self.nextOffset, returnedCount: returnedCount, totalCount: totalCount)
        self.nextOffset = progress.nextOffset
        return progress.canLoadMore
    }
}
