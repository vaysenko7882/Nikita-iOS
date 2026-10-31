import AccountContext
import ComponentFlow
import Display
import Foundation
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

public enum MadgramDeepLinkRoute: String, CaseIterable {
    case settings
    case ghost
    case filters
    case archive
    case interface
    case powerSaving = "power-saving"
    case premium
    case messageShot = "message-shot"
    case forwardWithoutAuthor = "forward-without-author"

    fileprivate static func parse(_ url: URL) -> MadgramDeepLinkRoute? {
        guard ["nikita", "mad"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }

        var components: [String] = []
        if let host = url.host, !host.isEmpty {
            components.append(host.lowercased())
        }
        components.append(contentsOf: url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() })

        if components.first == "settings" {
            components.removeFirst()
        }
        guard let route = components.first else {
            return .settings
        }

        switch route {
        case "settings", "nikita", "madgram", "privacy":
            return .settings
        case "ghost", "ghost-mode":
            return .ghost
        case "filters", "message-filters":
            return .filters
        case "archive", "local-archive", "local-message-archive":
            return .archive
        case "interface", "tuning", "tabs", "profiles", "stories", "camera", "media":
            return .interface
        case "power", "power-saving":
            return .powerSaving
        case "premium", "local-premium":
            return .premium
        case "message-shot", "messageshot":
            return .messageShot
        case "forward-without-author", "anonymous-forward":
            return .forwardWithoutAuthor
        default:
            return nil
        }
    }
}

public func madgramControllerForDeepLink(context: AccountContext, url: URL) -> ViewController? {
    guard let route = MadgramDeepLinkRoute.parse(url) else {
        return nil
    }
    switch route {
    case .ghost:
        return ghostModeSettingsController(context: context)
    case .filters:
        return messageFilterSettingsController(context: context)
    case .archive:
        return localMessageArchiveSettingsController(context: context)
    case .interface:
        return interfaceTuningSettingsController(context: context)
    case .settings, .powerSaving, .premium, .messageShot, .forwardWithoutAuthor:
        return madgramSettingsController(context: context)
    }
}

private final class MadgramControllerArguments {
    let openGhostMode: () -> Void
    let openMessageFilters: () -> Void
    let openLocalMessageArchive: () -> Void
    let openInterfaceTuning: () -> Void
    let openNikitaTools: () -> Void
    let setGhostMode: (Bool) -> Void
    let setPersistentArchive: (Bool) -> Void
    let updateInterfaceTuning: (@escaping (InterfaceTuningSettings) -> InterfaceTuningSettings) -> Void
    let setLocalPremium: (Bool) -> Void
    let setPowerSaving: (Bool) -> Void
    let showInfo: (String, UIView) -> Void

    init(
        openGhostMode: @escaping () -> Void,
        openMessageFilters: @escaping () -> Void,
        openLocalMessageArchive: @escaping () -> Void,
        openInterfaceTuning: @escaping () -> Void,
        openNikitaTools: @escaping () -> Void,
        setGhostMode: @escaping (Bool) -> Void,
        setPersistentArchive: @escaping (Bool) -> Void,
        updateInterfaceTuning: @escaping (@escaping (InterfaceTuningSettings) -> InterfaceTuningSettings) -> Void,
        setLocalPremium: @escaping (Bool) -> Void,
        setPowerSaving: @escaping (Bool) -> Void,
        showInfo: @escaping (String, UIView) -> Void
    ) {
        self.openGhostMode = openGhostMode
        self.openMessageFilters = openMessageFilters
        self.openLocalMessageArchive = openLocalMessageArchive
        self.openInterfaceTuning = openInterfaceTuning
        self.openNikitaTools = openNikitaTools
        self.setGhostMode = setGhostMode
        self.setPersistentArchive = setPersistentArchive
        self.updateInterfaceTuning = updateInterfaceTuning
        self.setLocalPremium = setLocalPremium
        self.setPowerSaving = setPowerSaving
        self.showInfo = showInfo
    }
}

private enum MadgramSection: Int32 {
    case nikita
    case privacy
    case messages
    case interface
    case other
}

private enum MadgramEntry: ItemListNodeEntry {
    case nikitaHeader(String)
    case ghostQuick(String, Bool)
    case archiveQuick(String, Bool)
    case nikitaTools(String)
    case nikitaInfo(String)
    case privacyHeader(String)
    case ghostMode(String, String)
    case hidePhoneInSettings(String, String, Bool)
    case privacyInfo(String)
    case messagesHeader(String)
    case localMessageArchive(String, String)
    case messageFilters(String, String)
    case messagesInfo(String)
    case interfaceHeader(String)
    case classicDesign(String, Bool)
    case showAppBadge(String, String, Bool)
    case interfaceTuning(String)
    case interfaceInfo(String)
    case otherHeader(String)
    case powerSaving(String, String, Bool)
    case localPremium(String, String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .nikitaHeader, .ghostQuick, .archiveQuick, .nikitaTools, .nikitaInfo:
            return MadgramSection.nikita.rawValue
        case .privacyHeader, .ghostMode, .hidePhoneInSettings, .privacyInfo:
            return MadgramSection.privacy.rawValue
        case .messagesHeader, .localMessageArchive, .messageFilters, .messagesInfo:
            return MadgramSection.messages.rawValue
        case .interfaceHeader, .classicDesign, .showAppBadge, .interfaceTuning, .interfaceInfo:
            return MadgramSection.interface.rawValue
        case .otherHeader, .powerSaving, .localPremium:
            return MadgramSection.other.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .nikitaHeader: return -5
        case .ghostQuick: return -4
        case .archiveQuick: return -3
        case .nikitaTools: return -2
        case .nikitaInfo: return -1
        case .privacyHeader: return 0
        case .ghostMode: return 1
        case .hidePhoneInSettings: return 2
        case .privacyInfo: return 3
        case .messagesHeader: return 10
        case .localMessageArchive: return 11
        case .messageFilters: return 12
        case .messagesInfo: return 13
        case .interfaceHeader: return 20
        case .classicDesign: return 21
        case .showAppBadge: return 22
        case .interfaceTuning: return 23
        case .interfaceInfo: return 24
        case .otherHeader: return 30
        case .powerSaving: return 31
        case .localPremium: return 32
        }
    }

    static func ==(lhs: MadgramEntry, rhs: MadgramEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.nikitaHeader(lhsText), .nikitaHeader(rhsText)),
             let (.nikitaTools(lhsText), .nikitaTools(rhsText)),
             let (.nikitaInfo(lhsText), .nikitaInfo(rhsText)):
            return lhsText == rhsText
        case let (.ghostQuick(lhsText, lhsValue), .ghostQuick(rhsText, rhsValue)),
             let (.archiveQuick(lhsText, lhsValue), .archiveQuick(rhsText, rhsValue)):
            return lhsText == rhsText && lhsValue == rhsValue
        case let (.privacyHeader(lhsText), .privacyHeader(rhsText)),
             let (.privacyInfo(lhsText), .privacyInfo(rhsText)),
             let (.messagesHeader(lhsText), .messagesHeader(rhsText)),
             let (.messagesInfo(lhsText), .messagesInfo(rhsText)),
             let (.interfaceHeader(lhsText), .interfaceHeader(rhsText)),
             let (.interfaceTuning(lhsText), .interfaceTuning(rhsText)),
             let (.interfaceInfo(lhsText), .interfaceInfo(rhsText)),
             let (.otherHeader(lhsText), .otherHeader(rhsText)):
            return lhsText == rhsText
        case let (.ghostMode(lhsText, lhsValue), .ghostMode(rhsText, rhsValue)),
             let (.localMessageArchive(lhsText, lhsValue), .localMessageArchive(rhsText, rhsValue)),
             let (.messageFilters(lhsText, lhsValue), .messageFilters(rhsText, rhsValue)):
            return lhsText == rhsText && lhsValue == rhsValue
        case let (.classicDesign(lhsText, lhsValue), .classicDesign(rhsText, rhsValue)):
            return lhsText == rhsText && lhsValue == rhsValue
        case let (.hidePhoneInSettings(lhsText, lhsInfo, lhsValue), .hidePhoneInSettings(rhsText, rhsInfo, rhsValue)),
             let (.showAppBadge(lhsText, lhsInfo, lhsValue), .showAppBadge(rhsText, rhsInfo, rhsValue)),
             let (.localPremium(lhsText, lhsInfo, lhsValue), .localPremium(rhsText, rhsInfo, rhsValue)),
             let (.powerSaving(lhsText, lhsInfo, lhsValue), .powerSaving(rhsText, rhsInfo, rhsValue)):
            return lhsText == rhsText && lhsInfo == rhsInfo && lhsValue == rhsValue
        default:
            return false
        }
    }

    static func <(lhs: MadgramEntry, rhs: MadgramEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MadgramControllerArguments
        let switchItem: (String, String?, Bool, @escaping (Bool) -> Void) -> ListViewItem = { title, info, value, updated in
            var titleBadgeComponent: AnyComponent<Empty>?
            var titleBadgeAction: ((UIView) -> Void)?
            if let info {
                titleBadgeComponent = featureInfoBadgeComponent(color: presentationData.theme.list.itemAccentColor)
                titleBadgeAction = { sourceView in
                    arguments.showInfo(info, sourceView)
                }
            }
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: title,
                titleBadgeComponent: titleBadgeComponent,
                titleBadgeAction: titleBadgeAction,
                value: value,
                maximumNumberOfLines: 2,
                sectionId: self.section,
                style: .blocks,
                updated: updated
            )
        }
        switch self {
        case let .nikitaHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .nikitaInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .ghostQuick(text, value):
            return switchItem(text, nil, value, arguments.setGhostMode)
        case let .archiveQuick(text, value):
            return switchItem(text, nil, value, arguments.setPersistentArchive)
        case let .nikitaTools(text):
            return ItemListDisclosureItem(presentationData: presentationData, title: text, label: "", sectionId: self.section, style: .blocks, action: arguments.openNikitaTools)
        case let .privacyHeader(text), let .messagesHeader(text), let .interfaceHeader(text), let .otherHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .privacyInfo(text), let .messagesInfo(text), let .interfaceInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .ghostMode(text, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: text, label: value, sectionId: self.section, style: .blocks, action: arguments.openGhostMode)
        case let .hidePhoneInSettings(text, info, value):
            return switchItem(text, info, value, { value in
                arguments.updateInterfaceTuning { current in
                    var current = current
                    current.hidePhoneInSettings = value
                    return current
                }
            })
        case let .localMessageArchive(text, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: text, label: value, sectionId: self.section, style: .blocks, action: arguments.openLocalMessageArchive)
        case let .messageFilters(text, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: text, label: value, sectionId: self.section, style: .blocks, action: arguments.openMessageFilters)
        case let .classicDesign(text, value):
            return switchItem(text, nil, value, { value in
                arguments.updateInterfaceTuning { current in
                    var current = current
                    current.classicDesign = value
                    return current
                }
            })
        case let .showAppBadge(text, info, value):
            return switchItem(text, info, value, { value in
                arguments.updateInterfaceTuning { current in
                    var current = current
                    current.showAppBadge = value
                    return current
                }
            })
        case let .interfaceTuning(text):
            return ItemListDisclosureItem(presentationData: presentationData, title: text, label: "", sectionId: self.section, style: .blocks, action: arguments.openInterfaceTuning)
        case let .powerSaving(text, info, value):
            return switchItem(text, info, value, arguments.setPowerSaving)
        case let .localPremium(text, info, value):
            return switchItem(text, info, value, arguments.setLocalPremium)
        }
    }
}

public func madgramSettingsController(context: AccountContext) -> ViewController {
    var presentTooltip: ((String, UIView) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let localPremiumValue = Atomic(value: LocalPremiumSettingsStore.shared.current)
    let localPremiumPromise = ValuePromise(localPremiumValue.with { $0 }, ignoreRepeated: true)

    let arguments = MadgramControllerArguments(
        openGhostMode: {
            pushControllerImpl?(ghostModeSettingsController(context: context))
        },
        openMessageFilters: {
            pushControllerImpl?(messageFilterSettingsController(context: context))
        },
        openLocalMessageArchive: {
            pushControllerImpl?(localMessageArchiveSettingsController(context: context))
        },
        openInterfaceTuning: {
            pushControllerImpl?(interfaceTuningSettingsController(context: context))
        },
        openNikitaTools: {
            pushControllerImpl?(NikitaToolsController(context: context))
        },
        setGhostMode: { value in
            let _ = context.engine.messages.updateGhostModeSettingsInteractively { current in
                var current = current
                current.isEnabled = value
                return current
            }.start()
        },
        setPersistentArchive: { value in
            let _ = context.engine.messages.updateDeletedMessageArchiveSettingsInteractively { current in
                var current = current
                current.keepAcrossLaunches = value
                if value {
                    current.saveDeletedMessages = true
                    current.saveEditedVersions = true
                }
                return current
            }.start()
        },
        updateInterfaceTuning: { f in
            InterfaceTuningSettingsStore.shared.update { current in
                return f(current)
            }
        },
        setLocalPremium: { value in
            let updated = LocalPremiumSettingsStore.shared.update { current in
                var current = current
                current.isEnabled = value
                return current
            }
            let _ = localPremiumValue.swap(updated)
            localPremiumPromise.set(updated)
        },
        setPowerSaving: { value in
            let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                if value {
                    settings.energyUsageSettings = EnergyUsageSettings.powerSavingDefault
                    settings.energyUsageSettings.activationThreshold = 96
                } else {
                    settings.energyUsageSettings = EnergyUsageSettings.default
                }
                return settings
            }).start()
            let _ = updatePresentationThemeSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.reduceMotion = value
                return settings
            }).start()
        },
        showInfo: { text, sourceView in
            presentTooltip?(text, sourceView)
        }
    )

    let ghostModeSettings = context.engine.messages.ghostModeSettings()

    let localArchiveSettings = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.deletedMessageArchiveSettings))
    |> map { entry -> DeletedMessageArchiveSettings in
        return entry?.get(DeletedMessageArchiveSettings.self) ?? .defaultSettings
    }
    |> distinctUntilChanged

    let hiddenSenderCount = messageFilterSettingsSignal()
    |> map { settings -> Int in
        return settings.shadowBannedPeerIds.count
    }
    |> distinctUntilChanged

    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings, ApplicationSpecificSharedDataKeys.presentationThemeSettings])
    |> map { sharedData -> Bool in
        let downloadSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]?.get(MediaAutoDownloadSettings.self) ?? .defaultSettings
        let themeSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? PresentationThemeSettings.defaultSettings
        let energy = downloadSettings.energyUsageSettings
        return energy.activationThreshold >= 96
            && !energy.autoplayVideo
            && !energy.autoplayGif
            && !energy.loopStickers
            && !energy.loopEmoji
            && !energy.fullTranslucency
            && !energy.extendBackgroundWork
            && !energy.autodownloadInBackground
            && themeSettings.reduceMotion
    }
    |> distinctUntilChanged

    let signal = combineLatest(
        context.sharedContext.presentationData,
        ghostModeSettings,
        localPremiumPromise.get(),
        sharedData,
        localArchiveSettings,
        hiddenSenderCount,
        interfaceTuningSettingsSignal()
    )
    |> map { presentationData, ghostModeSettings, localPremiumSettings, isPowerSavingEnabled, localArchiveSettings, hiddenSenderCount, interfaceTuningSettings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings.localFeatures
        let entries: [MadgramEntry] = [
            .nikitaHeader(strings.madgram.quickSection),
            .ghostQuick(strings.madgram.quickGhost, ghostModeSettings.isEnabled),
            .archiveQuick(strings.madgram.quickArchive, localArchiveSettings.keepAcrossLaunches && localArchiveSettings.saveDeletedMessages && localArchiveSettings.saveEditedVersions),
            .nikitaTools("VPS и VoiceChanger"),
            .nikitaInfo(strings.madgram.quickInfo),
            .privacyHeader(strings.madgram.privacySection),
            .ghostMode(strings.ghostMode.title, ghostModeSettings.isEnabled ? strings.ghostMode.on : strings.ghostMode.off),
            .hidePhoneInSettings(strings.interfaceTuning.hidePhoneInSettings, strings.interfaceTuning.hidePhoneInSettingsInfo, interfaceTuningSettings.hidePhoneInSettings),
            .privacyInfo(strings.madgram.privacyInfo),

            .messagesHeader(strings.madgram.messagesSection),
            .localMessageArchive(strings.localMessageArchive.title, localArchiveSettings.isEnabled ? strings.ghostMode.on : strings.ghostMode.off),
            .messageFilters(strings.messageFilter.title, hiddenSenderCount > 0 ? "\(hiddenSenderCount)" : ""),
            .messagesInfo(strings.madgram.messagesInfo),

            .interfaceHeader(strings.madgram.interfaceSection),
            .classicDesign(strings.madgram.classicDesign, interfaceTuningSettings.classicDesign),
            .showAppBadge(strings.interfaceTuning.showAppBadge, strings.interfaceTuning.showAppBadgeInfo, interfaceTuningSettings.showAppBadge),
            .interfaceTuning(strings.interfaceTuning.title),
            .interfaceInfo(strings.madgram.classicDesignInfo),

            .otherHeader(strings.madgram.otherSection),
            .powerSaving(strings.madgram.powerSaving, strings.madgram.powerSavingInfo, isPowerSavingEnabled),
            .localPremium(strings.localPremium.title, strings.localPremium.info, localPremiumSettings.isEnabled)
        ]
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(strings.madgram.title),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
                animateChanges: true
            ),
            (
                ItemListNodeState(
                    presentationData: ItemListPresentationData(presentationData),
                    entries: entries,
                    style: .blocks
                ),
                arguments
            )
        )
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    var currentTooltipController: TooltipController?
    presentTooltip = { [weak controller] text, sourceView in
        guard let controller else {
            return
        }
        currentTooltipController?.dismiss()
        currentTooltipController = presentFeatureInfoTooltip(
            text: text,
            sourceView: sourceView,
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            controller: controller
        )
    }
    return controller
}
