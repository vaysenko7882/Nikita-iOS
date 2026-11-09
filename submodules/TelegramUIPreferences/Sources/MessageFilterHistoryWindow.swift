import Foundation

/// Hidden authors only require a larger history window in chats where their
/// messages actually displace the normal page of visible messages.
public enum MessageFilterHistoryWindow {
    public static let initialMessageCount = 44
    public static let maximumMessageCount = 512

    public static func expandedMessageCount(currentCount: Int, loadedMessageCount: Int, hiddenMessageCount: Int, hasMoreMessages: Bool) -> Int? {
        guard currentCount < self.maximumMessageCount,
              hiddenMessageCount > 0,
              loadedMessageCount - hiddenMessageCount < self.initialMessageCount,
              hasMoreMessages else {
            return nil
        }

        let visibleMessageCount = loadedMessageCount - hiddenMessageCount
        if visibleMessageCount == 0 {
            // An empty filtered page cannot drive normal scroll pagination.
            // Use the existing bounded fallback once rather than reloading a
            // succession of entirely hidden windows.
            return self.maximumMessageCount
        }

        // Estimate the window needed for a normal page using the observed
        // visible fraction. Sparse hidden authors only add a few slots.
        let projectedCount = (currentCount * self.initialMessageCount + visibleMessageCount - 1) / visibleMessageCount
        return min(self.maximumMessageCount, max(currentCount + 1, projectedCount))
    }
}
