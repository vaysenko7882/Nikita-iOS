import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine.Messages {
    func updateDeletedMessageArchiveSettingsInteractively(_ f: @escaping (DeletedMessageArchiveSettings) -> DeletedMessageArchiveSettings) -> Signal<Never, NoError> {
        return TelegramCore.updateDeletedMessageArchiveSettingsInteractively(postbox: self.account.postbox, f)
    }
}
