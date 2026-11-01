import AccountContext
import Display
import TelegramCore
import TelegramUIPreferences

enum InterfaceTuningKey: Int32 {
    case concealBottomBar
    case showContactsShortcut
    case showCallsShortcut
    case showTabLabels
    case showSearchShortcut
    case stretchBottomBar
    case showProfileIdentifiers
    case showDataCenter
    case showRegistrationDate
    case showChatCreationDate
    case showCallbackData
    case hideStoryStrip
    case disableStoryCameraSwipe
    case confirmStoryOpen
    case allowStoryRepost
    case startRoundVideoWithRearCamera
    case hideGalleryCamera
    case hideBusinessBotPanel
}

func updatedInterfaceTuningSettings(
    _ current: InterfaceTuningSettings,
    key: InterfaceTuningKey,
    value: Bool
) -> InterfaceTuningSettings {
    var current = current
    switch key {
    case .concealBottomBar:
        current.concealBottomBar = value
    case .showContactsShortcut:
        current.showContactsShortcut = value
    case .showCallsShortcut:
        current.showCallsShortcut = value
    case .showTabLabels:
        current.showTabLabels = value
    case .showSearchShortcut:
        current.showSearchShortcut = value
    case .stretchBottomBar:
        current.stretchBottomBar = value
    case .showProfileIdentifiers:
        current.showProfileIdentifiers = value
    case .showDataCenter:
        current.showDataCenter = value
    case .showRegistrationDate:
        current.showRegistrationDate = value
    case .showChatCreationDate:
        current.showChatCreationDate = value
    case .showCallbackData:
        current.showCallbackData = value
    case .hideStoryStrip:
        current.hideStoryStrip = value
    case .disableStoryCameraSwipe:
        current.disableStoryCameraSwipe = value
    case .confirmStoryOpen:
        current.confirmStoryOpen = value
    case .allowStoryRepost:
        current.allowStoryRepost = value
    case .startRoundVideoWithRearCamera:
        current.startRoundVideoWithRearCamera = value
    case .hideGalleryCamera:
        current.hideGalleryCamera = value
    case .hideBusinessBotPanel:
        current.hideBusinessBotPanel = value
    }
    return current
}

public func interfaceTuningSettingsController(context: AccountContext) -> ViewController {
    return CodeGramInterfaceController(context: context)
}
