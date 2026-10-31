#!/usr/bin/env python3
"""Parse changed Swift surfaces before the full iOS typecheck and link."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FILES = [
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
for relative in FILES:
    subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", str(ROOT / relative)], check=True)
print(f"Swift syntax parsed: {len(FILES)} files. Full typechecking is performed by the app build.")

