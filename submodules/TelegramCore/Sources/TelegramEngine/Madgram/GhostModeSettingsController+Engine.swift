import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine.Messages {
    func updateGhostModeSettingsInteractively(_ f: @escaping (GhostModeSettings) -> GhostModeSettings) -> Signal<Never, NoError> {
        return TelegramCore.updateGhostModeSettingsInteractively(postbox: self.account.postbox, f)
    }
}
