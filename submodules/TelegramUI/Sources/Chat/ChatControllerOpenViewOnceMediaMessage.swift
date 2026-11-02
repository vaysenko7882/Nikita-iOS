import Foundation
import UIKit
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import SafariServices
import MobileCoreServices
import Intents
import LegacyComponents
import TelegramPresentationData
import TelegramUIPreferences
import DeviceAccess
import TextFormat
import TelegramBaseController
import AccountContext
import TelegramStringFormatting
import OverlayStatusController
import DeviceLocationManager
import UrlEscaping
import ContextUI
import AlertUI
import PresentationDataUtils
import UndoUI
import TelegramCallsUI
import TelegramNotices
import GameUI
import ScreenCaptureDetection
import GalleryUI
import OpenInExternalAppUI
import LegacyUI
import InstantPageUI
import LocationUI
import BotPaymentsUI
import DeleteChatPeerActionSheetItem
import HashtagSearchUI
import LegacyMediaPickerUI
import Emoji
import PeerAvatarGalleryUI
import PeerInfoUI
import RaiseToListen
import UrlHandling
import AvatarNode
import AppBundle
import LocalizedPeerData
import PhoneNumberFormat
import SettingsUI
import UrlWhitelist
import TelegramIntents
import TooltipUI
import StatisticsUI
import MediaResources
import GalleryData
import ChatInterfaceState
import InviteLinksUI
import Markdown
import TelegramPermissionsUI
import Speak
import TranslateUI
import UniversalMediaPlayer
import WallpaperBackgroundNode
import ChatListUI
import CalendarMessageScreen
import ReactionSelectionNode
import ReactionListContextMenuContent
import AttachmentUI
import AttachmentTextInputPanelNode
import MediaPickerUI
import ChatPresentationInterfaceState
import Pasteboard
import ChatSendMessageActionUI
import ChatTextLinkEditUI
import WebUI
import PremiumUI
import ImageTransparency
import StickerPackPreviewUI
import TextNodeWithEntities
import EntityKeyboard
import ChatTitleView
import EmojiStatusComponent
import ChatTimerScreen
import MediaPasteboardUI
import ChatListHeaderComponent
import ChatControllerInteraction
import FeaturedStickersScreen
import ChatEntityKeyboardInputNode
import StorageUsageScreen
import AvatarEditorScreen
import ChatScheduleTimeController
import ICloudResources
import StoryContainerScreen
import MoreHeaderButton
import VolumeButtons
import ChatAvatarNavigationNode
import ChatContextQuery
import PeerReportScreen
import PeerSelectionController
import SaveToCameraRoll
import ChatMessageDateAndStatusNode
import ReplyAccessoryPanelNode
import TextSelectionNode
import ChatMessagePollBubbleContentNode
import ChatMessageItem
import ChatMessageItemImpl
import ChatMessageItemView
import ChatMessageItemCommon
import ChatMessageAnimatedStickerItemNode
import ChatMessageBubbleItemNode
import ChatNavigationButton
import WebsiteType
import PeerInfoScreen
import MediaEditorScreen
import WallpaperGalleryScreen
import WallpaperGridScreen
import VideoMessageCameraScreen
import TopMessageReactions
import AudioWaveform
import PeerNameColorScreen
import ChatEmptyNode
import ChatMediaInputStickerGridItem

extension ChatControllerImpl {
    func openViewOnceMediaMessage(_ message: EngineMessage) {
        if self.screenCaptureManager?.isRecordingActive == true {
            let controller = textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: self.presentationData.strings.Chat_PlayOnceMesasge_DisableScreenCapture, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {
            })])
            self.present(controller, in: .window(.root))
            return
        }
        
        let isIncoming = message.effectivelyIncoming(self.context.account.peerId)
        let waitsForCountdown = message._asMessage().codeGramRequiresExplicitMediaCountdown
        var countdownStarted = !waitsForCountdown
        var mediaActions: [ContextMenuItem] = []
        if isIncoming {
            mediaActions.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Common_Save, icon: { theme in
                return UIImage(systemName: "square.and.arrow.down")?.withTintColor(theme.contextMenu.primaryColor, renderingMode: .alwaysOriginal)
            }, action: { [weak self] controller, completion in
                let save: () -> Void = { [weak self] in
                    guard let self else { return }
                    self.context.sharedContext.mediaManager.setPlaylist(nil, type: .voice, control: .playback(.pause))
                    exportCodeGramDisappearingMedia(context: self.context, message: message, sourceView: self.chatDisplayNode.view, failed: { [weak self] in
                        guard let self else { return }
                        let alert = UIAlertController(title: nil, message: self.presentationData.strings.localFeatures.disappearingMedia.exportFailed, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_OK, style: .default))
                        self.context.sharedContext.applicationBindings.presentNativeController(alert)
                    })
                }
                if let controller { controller.dismiss(result: .default, completion: save) }
                else { completion(.default); save() }
            })))
            if waitsForCountdown {
                mediaActions.append(.action(ContextMenuActionItem(text: self.presentationData.strings.localFeatures.disappearingMedia.startCountdown, icon: { theme in
                    return UIImage(systemName: "timer")?.withTintColor(theme.contextMenu.primaryColor, renderingMode: .alwaysOriginal)
                }, action: { [weak self] _, completion in
                    countdownStarted = true
                    if let self {
                        let _ = self.context.engine.messages.markMessageContentAsConsumedInteractively(messageId: message.id, force: true).startStandalone()
                    }
                    completion(.default)
                })))
            }
        }

        var presentImpl: ((ViewController) -> Void)?
        let configuration = ContextController.Configuration(
            sources: [
                ContextController.Source(
                    id: 0,
                    title: "",
                    source: .extracted(ChatViewOnceMessageContextExtractedContentSource(
                        context: self.context,
                        presentationData: self.presentationData,
                        chatNode: self.chatDisplayNode,
                        backgroundNode: self.chatBackgroundNode,
                        engine: self.context.engine,
                        message: message,
                        restoreMessage: { waitsForCountdown && !countdownStarted },
                        present: { c in
                            presentImpl?(c)
                        }
                    )),
                    items: .single(ContextController.Items(content: .list(mediaActions))),
                    closeActionTitle: isIncoming && !waitsForCountdown ? self.presentationData.strings.Chat_PlayOnceMesasgeCloseAndDelete : self.presentationData.strings.Chat_PlayOnceMesasgeClose,
                    closeAction: { [weak self] in
                        if let self {
                            self.context.sharedContext.mediaManager.setPlaylist(nil, type: .voice, control: .playback(.pause))
                        }
                    }
                )
            ], initialId: 0
        )
        
        let contextController = makeContextController(presentationData: self.presentationData, configuration: configuration)
        contextController.getOverlayViews = { [weak self] in
            guard let self else {
                return []
            }
            return [self.chatDisplayNode.navigateButtons.view]
        }
        self.currentContextController = contextController
        self.presentInGlobalOverlay(contextController)
        
        presentImpl = { [weak contextController] c in
            contextController?.present(c, in: .current)
        }
        
        let _ = self.context.sharedContext.openChatMessage(OpenChatMessageParams(context: self.context, chatLocation: nil, chatFilterTag: nil, chatLocationContextHolder: nil, message: message._asMessage(), standalone: false, reverseMessageGalleryOrder: false, navigationController: nil, dismissInput: { }, present: { _, _, _ in }, transitionNode: { _, _, _ in return nil }, addToTransitionSurface: { _ in }, openUrl: { _ in }, openPeer: { _, _ in }, callPeer: { _, _ in }, openConferenceCall: { _ in
        }, enqueueMessage: { _ in }, sendSticker: nil, sendEmoji: nil, setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in }, playlistLocation: .singleMessage(message.id)))
    }
}
