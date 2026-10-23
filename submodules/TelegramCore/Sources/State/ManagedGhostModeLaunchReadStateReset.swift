import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

private let ghostModeServerReadStateBatchSize = 100

func managedGhostModeLaunchReadStateReset(postbox: Postbox, network: Network) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> (peerIds: [PeerId], withoutSnapshot: Set<PeerId>) in
        let plan = ghostModeResetPlan(
            markers: transaction.getAllGhostModeReadStates(),
            includeMessages: true,
            includeStories: true
        )
        let rolledBackPeerIds = ghostModeApplyResetPlan(transaction: transaction, plan: plan)

        let withoutSnapshot = Set(plan.peersNeedingServerState.filter { peerId in
            return !ghostModeUserWroteLast(transaction: transaction, peerId: peerId, namespace: Namespaces.Message.Cloud)
        })
        var peerIds = withoutSnapshot
        peerIds.formUnion(rolledBackPeerIds)
        return (Array(peerIds), withoutSnapshot)
    }
    |> mapToSignal { reset -> Signal<Never, NoError> in
        let peerIds = reset.peerIds
        if peerIds.isEmpty {
            return .complete()
        }
        var signal: Signal<Never, NoError> = .complete()
        for offset in stride(from: 0, to: peerIds.count, by: ghostModeServerReadStateBatchSize) {
            let batch = Array(peerIds[offset ..< min(offset + ghostModeServerReadStateBatchSize, peerIds.count)])
            signal = signal
            |> then(applyServerReadStates(
                postbox: postbox,
                network: network,
                peerIds: batch,
                peerIdsWithoutSnapshot: reset.withoutSnapshot
            ))
        }
        return signal
    }
}

private func applyServerReadStates(
    postbox: Postbox,
    network: Network,
    peerIds: [PeerId],
    peerIdsWithoutSnapshot: Set<PeerId>
) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> [Api.InputDialogPeer] in
        return peerIds.compactMap { peerId -> Api.InputDialogPeer? in
            guard let inputPeer = transaction.getPeer(peerId).flatMap(apiInputPeer) else {
                return nil
            }
            return .inputDialogPeer(.init(peer: inputPeer))
        }
    }
    |> mapToSignal { inputPeers -> Signal<Never, NoError> in
        if inputPeers.isEmpty {
            return .complete()
        }
        return network.request(Api.functions.messages.getPeerDialogs(peers: inputPeers))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.PeerDialogs?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Never, NoError> in
            guard let result else {
                return .complete()
            }
            let dialogs: [Api.Dialog]
            switch result {
            case let .peerDialogs(peerDialogsData):
                dialogs = peerDialogsData.dialogs
            }
            return postbox.transaction { transaction -> Void in
                var readStates: [PeerId: [MessageId.Namespace: PeerReadState]] = [:]
                for dialog in dialogs {
                    guard case let .dialog(dialogData) = dialog, let peerId = dialog.peerId else {
                        continue
                    }
                    guard let readState = serverReadStateToApply(
                        transaction: transaction,
                        peerId: peerId,
                        dialogData: dialogData,
                        overwriteReadsAhead: peerIdsWithoutSnapshot.contains(peerId)
                    ) else {
                        continue
                    }
                    readStates[peerId] = [Namespaces.Message.Cloud: readState]
                }
                if !readStates.isEmpty {
                    transaction.resetIncomingReadStates(readStates)
                }
            }
            |> ignoreValues
        }
    }
}

private func serverReadStateToApply(
    transaction: Transaction,
    peerId: PeerId,
    dialogData: Api.Dialog.Cons_dialog,
    overwriteReadsAhead: Bool
) -> PeerReadState? {
    if transaction.getGhostModeReadState(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Cloud) != nil {
        return nil
    }

    var localMaxIncomingReadId: Int32 = 0
    var localMaxOutgoingReadId: Int32 = 0
    if let states = transaction.getPeerReadStates(peerId) {
        for (namespace, state) in states where namespace == Namespaces.Message.Cloud {
            if case let .idBased(maxIncomingReadId, maxOutgoingReadId, _, _, _) = state {
                localMaxIncomingReadId = maxIncomingReadId
                localMaxOutgoingReadId = maxOutgoingReadId
            }
            break
        }
    }
    if !overwriteReadsAhead && dialogData.readInboxMaxId < localMaxIncomingReadId {
        return nil
    }

    return .idBased(
        maxIncomingReadId: dialogData.readInboxMaxId,
        maxOutgoingReadId: max(dialogData.readOutboxMaxId, localMaxOutgoingReadId),
        maxKnownId: dialogData.topMessage,
        count: dialogData.unreadCount,
        markedUnread: (dialogData.flags & (1 << 3)) != 0
    )
}
