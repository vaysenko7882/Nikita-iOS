import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

func _internal_refreshAccountPresence(account: Account) -> Signal<Never, NoError> {
    return account.network.request(Api.functions.users.getUsers(id: [.inputUserSelf]))
    |> `catch` { _ -> Signal<[Api.User], NoError> in
        return .single([])
    }
    |> mapToSignal { users -> Signal<Never, NoError> in
        guard let user = users.first, let presence = TelegramUserPresence(apiUser: user) else {
            return .complete()
        }
        return account.postbox.transaction { transaction -> Void in
            transaction.updatePeerPresencesInternal(presences: [account.peerId: presence], merge: { _, updated in return updated })
        }
        |> ignoreValues
    }
}
