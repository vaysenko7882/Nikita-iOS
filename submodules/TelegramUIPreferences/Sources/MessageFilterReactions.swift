import Foundation
import TelegramCore

public extension MessageFilterSettings {
    func strippingHiddenReactions(from attribute: ReactionsMessageAttribute) -> ReactionsMessageAttribute? {
        if !self.isActive {
            return attribute
        }
        if attribute.isTags {
            return attribute
        }

        var removedCounts: [MessageReaction.Reaction: Int32] = [:]

        var recentPeers: [ReactionsMessageAttribute.RecentPeer] = []
        recentPeers.reserveCapacity(attribute.recentPeers.count)
        for peer in attribute.recentPeers {
            if self.hidesMessages(fromAuthorId: peer.peerId.toInt64()) {
                removedCounts[peer.value, default: 0] += 1
            } else {
                recentPeers.append(peer)
            }
        }

        var topPeers: [ReactionsMessageAttribute.TopPeer] = []
        topPeers.reserveCapacity(attribute.topPeers.count)
        for peer in attribute.topPeers {
            if let peerId = peer.peerId, self.hidesMessages(fromAuthorId: peerId.toInt64()) {
                removedCounts[.stars, default: 0] += peer.count
            } else {
                topPeers.append(peer)
            }
        }

        if removedCounts.isEmpty {
            return attribute
        }

        var reactions: [MessageReaction] = []
        reactions.reserveCapacity(attribute.reactions.count)
        for reaction in attribute.reactions {
            let removed = removedCounts[reaction.value] ?? 0
            var count = reaction.count - removed
            if reaction.isSelected {
                count = max(count, 1)
            }
            if count > 0 {
                reactions.append(MessageReaction(value: reaction.value, count: count, chosenOrder: reaction.chosenOrder))
            }
        }

        if reactions.isEmpty && recentPeers.isEmpty && topPeers.isEmpty {
            return nil
        }

        return ReactionsMessageAttribute(
            canViewList: attribute.canViewList,
            isTags: attribute.isTags,
            reactions: reactions,
            recentPeers: recentPeers,
            topPeers: topPeers
        )
    }
}
