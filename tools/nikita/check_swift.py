#!/usr/bin/env python3
"""Parse changed Swift surfaces before the full iOS typecheck and link."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FILES = [
    "submodules/SettingsUI/Sources/CodeGramIconPickerView.swift",
    "submodules/SettingsUI/Sources/CodeGramIconPickerController.swift",
    "submodules/SettingsUI/Sources/CodeGramProfileTrackingController.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramVPSClient.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramSocialVideoLink.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramSocialVideoMedia.swift",
    "submodules/TelegramUI/Sources/CodeGramSocialVideoConversion.swift",
    "submodules/TelegramUI/Sources/ChatControllerNode.swift",
    "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift",
    "submodules/SettingsUI/Sources/CodeGramSettingsCells.swift",
    "submodules/SettingsUI/Sources/CodeGramDashboardComponents.swift",
    "submodules/SettingsUI/Sources/CodeGramSettingsTheme.swift",
    "submodules/SettingsUI/Sources/CodeGramFeatureControllers.swift",
    "submodules/SettingsUI/Sources/InterfaceTuningSettingsController.swift",
    "submodules/SettingsUI/Sources/GhostModeSettingsController.swift",
    "submodules/SettingsUI/Sources/MessageFilterSettingsController.swift",
    "submodules/SettingsUI/Sources/BusinessBotPanelExceptionsController.swift",
    "submodules/SettingsUI/Sources/Data and Storage/LocalMessageArchiveSettingsController.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramEnergyPolicy.swift",
    "submodules/SettingsUI/Sources/CodeGramDashboardController.swift",
    "submodules/AuthorizationUI/Sources/AuthorizationSequenceSplashController.swift",
    "submodules/Display/Source/WindowContent.swift",
    "submodules/SettingsUI/Sources/MadgramSettingsController.swift",
    "submodules/SettingsUI/Sources/NikitaToolsController.swift",
    "submodules/TelegramCore/Sources/Nikita/NikitaSettings.swift",
    "submodules/TelegramCore/Sources/Nikita/NikitaArchiveSync.swift",
    "submodules/TelegramCore/Sources/Nikita/NikitaArchiveMediaResource.swift",
    "submodules/TelegramCore/Sources/Nikita/NikitaArchiveMedia.swift",
    "submodules/TelegramCore/Sources/Nikita/FetchNikitaArchiveMedia.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_CloudFileMediaResource.swift",
    "submodules/TelegramCore/Sources/State/Fetch.swift",
    "submodules/TelegramCore/Sources/Account/AccountManager.swift",
    "submodules/TelegramCore/Sources/Nikita/NikitaVoiceProcessor.swift",
    "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_ArchivedMessageAttribute.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift",
    "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeletedMessageArchive.swift",
    "submodules/TelegramUI/Sources/NikitaArchiveSyncManager.swift",
    "submodules/TelegramUI/Sources/AccountContext.swift",
    "submodules/TelegramUI/Sources/AppDelegate.swift",
    "submodules/TelegramUI/Sources/ManagedAudioRecorder.swift",
    "submodules/TelegramUI/Sources/SharedWakeupManager.swift",
    "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageStickerItemNode/Sources/ChatMessageStickerItemNode.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageInstantVideoItemNode/Sources/ChatMessageInstantVideoItemNode.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode/Sources/StringForMessageTimestampStatus.swift",
]
FILES += [
    "submodules/ChatPresentationInterfaceState/Sources/ChatPresentationInterfaceState.swift",
    "submodules/TelegramCore/Sources/ApiUtils/TelegramUser.swift",
    "submodules/TelegramCore/Sources/ApiUtils/ApiGroupOrChannel.swift",
    "submodules/TelegramPresentationData/Sources/LocalFeatureStrings.swift",
    "submodules/Display/Source/CodeGramDeletedAppearance.swift",
    "submodules/SettingsUI/Sources/CodeGramSettingsControllers.swift",
    "submodules/SettingsUI/Sources/CodeGramArchiveSettings.swift",
    "submodules/SettingsUI/Sources/CodeGramPeerAppearanceController.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramPeerAppearance.swift",
    "submodules/AvatarNode/Sources/AvatarNode.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramUser.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramGroup.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramChannel.swift",
    "submodules/TelegramCore/Sources/Settings/GhostModeSettings.swift",
    "submodules/TelegramCore/Sources/Utils/MessageUtils.swift",
    "submodules/TelegramCore/Sources/Utils/PeerUtils.swift",
    "submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift",
    "submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryItemSetContainerComponent.swift",
]
FILES += [
    "submodules/TelegramCore/Sources/Nikita/DeletedMessageArchiveBatch.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramArchiveTokenCache.swift",
    "submodules/TelegramCore/Sources/Nikita/CodeGramMediaConsumptionPolicy.swift",
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_AutoremoveTimeoutMessageAttribute.swift",
    "submodules/TelegramCore/Sources/TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift",
    "submodules/GalleryUI/Sources/SecretMediaPreviewController.swift",
    "submodules/TelegramUI/Sources/Chat/ChatControllerOpenViewOnceMediaMessage.swift",
    "submodules/TelegramUI/Sources/ChatMessageContextControllerContentSource.swift",
    "submodules/SaveToCameraRoll/Sources/CodeGramDisappearingMediaExport.swift",
    "submodules/SaveToCameraRoll/Sources/CodeGramExportFile.swift",
    "submodules/Display/Source/CodeGramMediaActions.swift",
]
for relative in FILES:
    subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", str(ROOT / relative)], check=True)
print(f"Swift syntax parsed: {len(FILES)} files. Full typechecking is performed by the app build.")




