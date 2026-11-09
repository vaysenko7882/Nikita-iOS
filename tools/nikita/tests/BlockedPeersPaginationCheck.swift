import Foundation

@main enum BlockedPeersPaginationCheck {
    static func main() {
        let first = BlockedPeersPageProgress(requestOffset: 0, returnedCount: 200, totalCount: 250)
        precondition(first.nextOffset == 200 && first.canLoadMore)
        let lastSlice = BlockedPeersPageProgress(requestOffset: first.nextOffset, returnedCount: 50, totalCount: 250)
        precondition(lastSlice.nextOffset == 250 && !lastSlice.canLoadMore)

        // The server may return an empty slice with a stale/higher total. It
        // still must terminate; retrying the unchanged offset would spin.
        let empty = BlockedPeersPageProgress(requestOffset: 250, returnedCount: 0, totalCount: 500)
        precondition(empty.nextOffset == 250 && !empty.canLoadMore)
        let complete = BlockedPeersPageProgress(requestOffset: 0, returnedCount: 12, totalCount: nil)
        precondition(complete.nextOffset == 12 && !complete.canLoadMore)

        // Only 150 of 200 entries might resolve to distinct local peers. The
        // next RPC must use raw offset 200, then finish at the server's total,
        // even if the final page contains only duplicates/unavailable peers.
        var merged = Set(0 ..< 150)
        let duplicateFinalPage = Array(0 ..< 50)
        merged.formUnion(duplicateFinalPage)
        precondition(merged.count == 150 && lastSlice.nextOffset != Int32(merged.count))
        precondition(!lastSlice.canLoadMore)

        let shrunk = BlockedPeersPageProgress(requestOffset: 200, returnedCount: 10, totalCount: 180)
        precondition(!shrunk.canLoadMore)
        let overflow = BlockedPeersPageProgress(requestOffset: Int32.max - 10, returnedCount: 100, totalCount: Int.max)
        precondition(overflow.nextOffset == Int32.max && !overflow.canLoadMore)
        let exhausted = BlockedPeersPageProgress(requestOffset: overflow.nextOffset, returnedCount: 1, totalCount: Int.max)
        precondition(!exhausted.canLoadMore)

        // Unblocking a loaded peer shifts the remote prefix. Restarting rather
        // than guessing a delta also handles changes outside the loaded page.
        var pagination = BlockedPeersPagination()
        let initialGeneration = pagination.generation
        precondition(pagination.completePage(generation: initialGeneration, returnedCount: 200, totalCount: 250) == true)
        precondition(pagination.nextOffset == 200)
        pagination.restart()
        precondition(pagination.nextOffset == 0)
        precondition(pagination.completePage(generation: initialGeneration, returnedCount: 50, totalCount: 250) == nil)
        precondition(pagination.nextOffset == 0)
        let restartedGeneration = pagination.generation
        precondition(pagination.completePage(generation: restartedGeneration, returnedCount: 200, totalCount: 249) == true)
        precondition(pagination.completePage(generation: restartedGeneration, returnedCount: 49, totalCount: 249) == false)
        precondition(pagination.nextOffset == 249)
        print("Blocked peers: final/empty slices terminate; raw offsets survive duplicate and unavailable peers.")
    }
}
