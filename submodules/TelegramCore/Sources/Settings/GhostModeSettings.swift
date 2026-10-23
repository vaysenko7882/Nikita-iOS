import Foundation
import MtProtoKit
import Postbox
import SwiftSignalKit

public let ghostModeStoryNamespace: MessageId.Namespace = Int32.min + 53

private struct GhostModeReadStateVersion: Codable {
    var value: Int64
}

private struct GhostModeReadStateRepairVersion: Codable {
    var value: Int32
}

public struct GhostModeSettings: Codable, Equatable {
    public static let defaultSettings = GhostModeSettings(
        isEnabled: false,
        suppressMessageReadReceipts: true,
        suppressStoryReadReceipts: true,
        suppressOnlineStatus: true,
        suppressTypingStatus: true,
        revealOnInteractions: false,
        goOfflineAutomatically: true,
        keepViewOnceMedia: false
    )

    public var isEnabled: Bool
    public var suppressMessageReadReceipts: Bool
    public var suppressStoryReadReceipts: Bool
    public var suppressOnlineStatus: Bool
    public var suppressTypingStatus: Bool
    public var revealOnInteractions: Bool
    public var goOfflineAutomatically: Bool
    public var keepViewOnceMedia: Bool

    public init(
        isEnabled: Bool,
        suppressMessageReadReceipts: Bool,
        suppressStoryReadReceipts: Bool,
        suppressOnlineStatus: Bool,
        suppressTypingStatus: Bool,
        revealOnInteractions: Bool,
        goOfflineAutomatically: Bool,
        keepViewOnceMedia: Bool
    ) {
        self.isEnabled = isEnabled
        self.suppressMessageReadReceipts = suppressMessageReadReceipts
        self.suppressStoryReadReceipts = suppressStoryReadReceipts
        self.suppressOnlineStatus = suppressOnlineStatus
        self.suppressTypingStatus = suppressTypingStatus
        self.revealOnInteractions = revealOnInteractions
        self.goOfflineAutomatically = goOfflineAutomatically
        self.keepViewOnceMedia = keepViewOnceMedia
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        self.suppressMessageReadReceipts = try container.decode(Bool.self, forKey: .suppressMessageReadReceipts)
        self.suppressStoryReadReceipts = try container.decode(Bool.self, forKey: .suppressStoryReadReceipts)
        self.suppressOnlineStatus = try container.decode(Bool.self, forKey: .suppressOnlineStatus)
        self.suppressTypingStatus = try container.decode(Bool.self, forKey: .suppressTypingStatus)
        self.revealOnInteractions = try container.decode(Bool.self, forKey: .revealOnInteractions)
        self.goOfflineAutomatically = try container.decode(Bool.self, forKey: .goOfflineAutomatically)
        self.keepViewOnceMedia = try container.decodeIfPresent(Bool.self, forKey: .keepViewOnceMedia) ?? false
    }

    public var hidesMessageReadReceipts: Bool {
        return self.isEnabled && self.suppressMessageReadReceipts
    }

    public var hidesStoryReadReceipts: Bool {
        return self.isEnabled && self.suppressStoryReadReceipts
    }

    public var hidesOnlineStatus: Bool {
        return self.isEnabled && self.suppressOnlineStatus
    }

    public var hidesTypingStatus: Bool {
        return self.isEnabled && self.suppressTypingStatus
    }

    public var keepsViewOnceMedia: Bool {
        return self.isEnabled && self.keepViewOnceMedia
    }
}

public func ghostModeDefersViewOnceConsumption(
    settings: GhostModeSettings,
    isViewOnce: Bool,
    isSecretChat: Bool,
    force: Bool
) -> Bool {
    if force {
        return false
    }
    if !isViewOnce {
        return false
    }
    return settings.keepsViewOnceMedia
}

public func ghostModeAllowsViewOnceCapture(
    settings: GhostModeSettings,
    isViewOnce: Bool,
    isIncoming: Bool,
    isConsumed: Bool,
    hasExplicitCopyProtection: Bool,
    hasPaidContent: Bool
) -> Bool {
    return settings.keepsViewOnceMedia
        && isViewOnce
        && isIncoming
        && !isConsumed
        && !hasExplicitCopyProtection
        && !hasPaidContent
}

func ghostModeSettings(transaction: Transaction) -> GhostModeSettings {
    return transaction.getPreferencesEntry(key: PreferencesKeys.ghostModeSettings)?.get(GhostModeSettings.self) ?? .defaultSettings
}

func updateGhostModeReadStateVersion(transaction: Transaction) {
    let current = transaction.getPreferencesEntry(key: PreferencesKeys.ghostModeReadStateVersion)?.get(GhostModeReadStateVersion.self)?.value ?? 0
    transaction.setPreferencesEntry(
        key: PreferencesKeys.ghostModeReadStateVersion,
        value: PreferencesEntry(GhostModeReadStateVersion(value: current &+ 1))
    )
}

func ghostModePreviousReadState(transaction: Transaction, peerId: PeerId, namespace: MessageId.Namespace) -> GhostModePreviousReadState? {
    guard let state = transaction.getPeerReadStates(peerId)?.first(where: { $0.0 == namespace })?.1 else {
        return nil
    }
    switch state {
    case let .idBased(maxIncomingReadId, maxOutgoingReadId, maxKnownId, count, markedUnread):
        return GhostModePreviousReadState(
            maxIncomingReadId: maxIncomingReadId,
            maxOutgoingReadId: maxOutgoingReadId,
            maxKnownId: maxKnownId,
            count: count,
            markedUnread: markedUnread
        )
    case .indexBased:
        return nil
    }
}

public struct GhostModeResetPlan: Equatable {
    public struct PeerRollback: Equatable {
        public let peerId: PeerId
        public let namespace: MessageId.Namespace
        public let readState: GhostModePreviousReadState

        public init(peerId: PeerId, namespace: MessageId.Namespace, readState: GhostModePreviousReadState) {
            self.peerId = peerId
            self.namespace = namespace
            self.readState = readState
        }
    }

    public struct ThreadRollback: Equatable {
        public let peerId: PeerId
        public let threadId: Int64
        public let readState: GhostModePreviousThreadReadState

        public init(peerId: PeerId, threadId: Int64, readState: GhostModePreviousThreadReadState) {
            self.peerId = peerId
            self.threadId = threadId
            self.readState = readState
        }
    }

    public struct StoryRollback: Equatable {
        public let peerId: PeerId
        public let maxReadId: Int32

        public init(peerId: PeerId, maxReadId: Int32) {
            self.peerId = peerId
            self.maxReadId = maxReadId
        }
    }

    public var peerRollbacks: [PeerRollback]
    public var threadRollbacks: [ThreadRollback]
    public var storyRollbacks: [StoryRollback]
    public var peersNeedingServerState: [PeerId]
    public var consumedMarkers: [GhostModeReadStateMarker]

    public var isEmpty: Bool {
        return self.consumedMarkers.isEmpty
    }
}

public func ghostModeResetPlan(
    markers: [GhostModeReadStateMarker],
    includeMessages: Bool,
    includeStories: Bool
) -> GhostModeResetPlan {
    var peerRollbacks: [GhostModeResetPlan.PeerRollback] = []
    var threadRollbacks: [GhostModeResetPlan.ThreadRollback] = []
    var storyRollbacks: [GhostModeResetPlan.StoryRollback] = []
    var peersNeedingServerState: [PeerId] = []
    var consumedMarkers: [GhostModeReadStateMarker] = []

    for marker in markers {
        if marker.namespace == ghostModeStoryNamespace {
            guard includeStories else {
                continue
            }
            if let previousStoryReadId = marker.previousStoryReadId {
                storyRollbacks.append(GhostModeResetPlan.StoryRollback(
                    peerId: marker.peerId,
                    maxReadId: previousStoryReadId
                ))
            }
            consumedMarkers.append(marker)
            continue
        }

        guard includeMessages else {
            continue
        }
        if let threadId = marker.threadId {
            if let previousThreadReadState = marker.previousThreadReadState {
                threadRollbacks.append(GhostModeResetPlan.ThreadRollback(
                    peerId: marker.peerId,
                    threadId: threadId,
                    readState: previousThreadReadState
                ))
            }
        } else if let previousReadState = marker.previousReadState {
            peerRollbacks.append(GhostModeResetPlan.PeerRollback(
                peerId: marker.peerId,
                namespace: marker.namespace,
                readState: previousReadState
            ))
        } else {
            peersNeedingServerState.append(marker.peerId)
        }
        consumedMarkers.append(marker)
    }

    return GhostModeResetPlan(
        peerRollbacks: peerRollbacks,
        threadRollbacks: threadRollbacks,
        storyRollbacks: storyRollbacks,
        peersNeedingServerState: peersNeedingServerState,
        consumedMarkers: consumedMarkers
    )
}

func ghostModeUserWroteLast(transaction: Transaction, peerId: PeerId, namespace: MessageId.Namespace) -> Bool {
    guard let index = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: namespace) else {
        return false
    }
    guard let message = transaction.getMessage(index.id) else {
        return false
    }
    return message.flags.intersection(.IsIncomingMask).isEmpty
}

@discardableResult
func ghostModeApplyResetPlan(transaction: Transaction, plan: GhostModeResetPlan) -> Set<PeerId> {
    var rolledBackPeerIds = Set<PeerId>()
    if plan.isEmpty {
        return rolledBackPeerIds
    }

    for rollback in plan.storyRollbacks {
        transaction.setPeerStoryState(
            peerId: rollback.peerId,
            state: Stories.PeerState(maxReadId: rollback.maxReadId).postboxRepresentation
        )
    }

    for rollback in plan.threadRollbacks {
        guard var data = transaction.getMessageHistoryThreadInfo(peerId: rollback.peerId, threadId: rollback.threadId)?.data.get(MessageHistoryThreadData.self) else {
            continue
        }
        data.maxIncomingReadId = rollback.readState.maxIncomingReadId
        data.maxKnownMessageId = rollback.readState.maxKnownMessageId
        data.incomingUnreadCount = rollback.readState.incomingUnreadCount
        data.isMarkedUnread = rollback.readState.markedUnread
        if let entry = StoredMessageHistoryThreadInfo(data) {
            transaction.setMessageHistoryThreadInfo(peerId: rollback.peerId, threadId: rollback.threadId, info: entry)
        }
    }

    var readStates: [PeerId: [MessageId.Namespace: PeerReadState]] = [:]
    for rollback in plan.peerRollbacks {
        if ghostModeUserWroteLast(transaction: transaction, peerId: rollback.peerId, namespace: rollback.namespace) {
            continue
        }
        readStates[rollback.peerId, default: [:]][rollback.namespace] = .idBased(
            maxIncomingReadId: rollback.readState.maxIncomingReadId,
            maxOutgoingReadId: rollback.readState.maxOutgoingReadId,
            maxKnownId: rollback.readState.maxKnownId,
            count: rollback.readState.count,
            markedUnread: rollback.readState.markedUnread
        )
        if rollback.namespace == Namespaces.Message.Cloud {
            rolledBackPeerIds.insert(rollback.peerId)
        }
    }
    if !readStates.isEmpty {
        transaction.resetIncomingReadStates(readStates)
    }

    for marker in plan.consumedMarkers {
        transaction.removeGhostModeReadState(
            peerId: marker.peerId,
            threadId: marker.threadId,
            namespace: marker.namespace
        )
    }
    updateGhostModeReadStateVersion(transaction: transaction)
    return rolledBackPeerIds
}

public func updateGhostModeSettingsInteractively(
    postbox: Postbox,
    _ f: @escaping (GhostModeSettings) -> GhostModeSettings
) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        let previous = ghostModeSettings(transaction: transaction)
        let updated = f(previous)
        transaction.updatePreferencesEntry(key: PreferencesKeys.ghostModeSettings, { _ in
            return PreferencesEntry(updated)
        })
        let shouldRestoreMessageReadStates = previous.hidesMessageReadReceipts && !updated.hidesMessageReadReceipts
        let shouldRestoreStoryReadStates = previous.hidesStoryReadReceipts && !updated.hidesStoryReadReceipts
        if shouldRestoreMessageReadStates || shouldRestoreStoryReadStates {
            let plan = ghostModeResetPlan(
                markers: transaction.getAllGhostModeReadStates(),
                includeMessages: shouldRestoreMessageReadStates,
                includeStories: shouldRestoreStoryReadStates
            )
            ghostModeApplyResetPlan(transaction: transaction, plan: plan)
        }
    }
    |> ignoreValues
}

func managedGhostModeReadStateRepair(accountPeerId: PeerId, postbox: Postbox, network: Network) -> Signal<Never, NoError> {
    let shouldRepair = postbox.preferencesView(keys: [
        PreferencesKeys.ghostModeSettings,
        PreferencesKeys.ghostModeReadStateRepairVersion
    ])
    |> map { view -> Bool in
        let settings = view.values[PreferencesKeys.ghostModeSettings]?.get(GhostModeSettings.self) ?? .defaultSettings
        let repairVersion = view.values[PreferencesKeys.ghostModeReadStateRepairVersion]?.get(GhostModeReadStateRepairVersion.self)?.value ?? 0
        return !settings.isEnabled && repairVersion < 1
    }
    |> distinctUntilChanged
    |> filter { $0 }
    |> take(1)

    return shouldRepair
    |> mapToSignal { _ -> Signal<Never, NoError> in
        return fetchChatList(
            accountPeerId: accountPeerId,
            postbox: postbox,
            network: network,
            location: .general,
            upperBound: .absoluteUpperBound(),
            hash: 0,
            limit: 100
        )
        |> mapToSignal { fetchedChatList -> Signal<Never, NoError> in
            guard let fetchedChatList else {
                return .complete()
            }
            return postbox.transaction { transaction -> Void in
                transaction.resetIncomingReadStates(fetchedChatList.readStates)
                transaction.setPreferencesEntry(
                    key: PreferencesKeys.ghostModeReadStateRepairVersion,
                    value: PreferencesEntry(GhostModeReadStateRepairVersion(value: 1))
                )
            }
            |> ignoreValues
        }
    }
}
