import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

class CodeGramFeatureController: CodeGramTableController {
    let subscriptions = DisposableSet()
    deinit { self.subscriptions.dispose() }
    func observe<T>(_ signal: Signal<T, NoError>, update: @escaping (T) -> Void) {
        self.subscriptions.add((signal |> deliverOnMainQueue).start(next: update))
    }
}

final class CodeGramGhostController: CodeGramFeatureController {
    private var settings: GhostModeSettings?
    init(context: AccountContext) {
        super.init(context: context, title: context.sharedContext.currentPresentationData.with { $0 }.strings.localFeatures.ghostMode.title)
        self.observe(context.engine.messages.ghostModeSettings()) { [weak self] value in self?.settings = value; self?.reloadContent() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func flag(_ title: String, _ info: String?, _ key: WritableKeyPath<GhostModeSettings, Bool>, icon: String, master: Bool = false) -> CodeGramSettingsRow {
        return self.switchRow(title, value: self.settings?[keyPath: key] ?? false, detail: info, icon: icon, enabled: master || self.settings?.isEnabled == true, changed: { [weak self] value in
            guard let self else { return }
            self.subscriptions.add(self.context.engine.messages.updateGhostModeSettingsInteractively { current in var current = current; current[keyPath: key] = value; return current }.start())
        })
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        guard self.settings != nil else { return [] }
        let s = self.context.sharedContext.currentPresentationData.with { $0 }.strings.localFeatures.ghostMode
        return [
            CodeGramSettingsSection(title: nil, footer: s.masterInfo, rows: [self.flag(s.title, nil, \.isEnabled, icon: "eye.slash", master: true)]),
            CodeGramSettingsSection(title: s.hideSection, footer: nil, rows: [
                self.flag(s.suppressMessageReadReceipts, s.suppressMessageReadReceiptsInfo, \.suppressMessageReadReceipts, icon: "checkmark.message"),
                self.flag(s.suppressStoryReadReceipts, s.suppressStoryReadReceiptsInfo, \.suppressStoryReadReceipts, icon: "eye.circle"),
                self.flag(s.suppressOnlineStatus, s.suppressOnlineStatusInfo, \.suppressOnlineStatus, icon: "person.crop.circle.badge.clock"),
                self.flag(s.suppressTypingStatus, s.suppressTypingStatusInfo, \.suppressTypingStatus, icon: "ellipsis.bubble"),
                self.flag(s.keepViewOnceMedia, s.keepViewOnceMediaInfo, \.keepViewOnceMedia, icon: "timer")]),
            CodeGramSettingsSection(title: s.behaviorSection, footer: nil, rows: [
                self.flag(s.revealOnInteractions, s.revealOnInteractionsInfo, \.revealOnInteractions, icon: "hand.tap"),
                self.flag(s.goOfflineAutomatically, s.goOfflineAutomaticallyInfo, \.goOfflineAutomatically, icon: "moon.zzz")])]
    }
}

final class CodeGramLocalArchiveController: CodeGramFeatureController {
    private var settings: DeletedMessageArchiveSettings?
    private var stats: DeletedMessageArchiveStats?
    private let statsRequest = MetaDisposable()
    init(context: AccountContext) {
        super.init(context: context, title: "Локальный архив")
        self.observe(context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.deletedMessageArchiveSettings))) { [weak self] entry in
            self?.settings = entry?.get(DeletedMessageArchiveSettings.self) ?? .defaultSettings; self?.reloadContent()
        }
        self.refreshStats()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.statsRequest.dispose() }
    private func refreshStats() {
        self.statsRequest.set((self.context.engine.messages.deletedMessageArchiveStats() |> deliverOnMainQueue).start(next: { [weak self] value in self?.stats = value; self?.reloadContent() }))
    }
    private func update(_ body: @escaping (inout DeletedMessageArchiveSettings) -> Void, refresh: Bool = false) {
        let signal = self.context.engine.messages.updateDeletedMessageArchiveSettingsInteractively { current in var current = current; body(&current); return current }
        self.subscriptions.add((signal |> then(refresh ? self.context.engine.messages.refreshDeletedMessageArchiveMediaLimit() : .complete()) |> deliverOnMainQueue).start(completed: { [weak self] in if refresh { self?.refreshStats() } }))
    }
    private func flag(_ title: String, _ key: WritableKeyPath<DeletedMessageArchiveSettings, Bool>, icon: String) -> CodeGramSettingsRow {
        return self.switchRow(title, value: self.settings?[keyPath: key] ?? false, icon: icon, changed: { [weak self] value in self?.update { $0[keyPath: key] = value } })
    }
    private func selectLimit(disappearing: Bool) {
        let alert = CodeGramPlainAlertController(title: "Лимит медиа", message: nil, preferredStyle: .alert)
        let values = disappearing ? DeletedMessageArchiveSettings.allowedDisappearingMediaLimitGigabytes : DeletedMessageArchiveSettings.allowedMediaLimitGigabytes
        for value in values {
            alert.addAction(CodeGramPlainAlertAction(title: "\(value) ГБ", style: .default, handler: { [weak self] _ in
                self?.update({ if disappearing { $0.disappearingMediaLimitGigabytes = value } else { $0.mediaLimitGigabytes = value } }, refresh: true)
            }))
        }
        alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel)); self.present(alert, animated: true)
    }
    private func editMarker() {
        let alert = CodeGramPlainAlertController(title: "Метка удалённого сообщения", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] in $0.text = self?.settings?.deletedMessageMarker }
        alert.addAction(CodeGramPlainAlertAction(title: "Сохранить", style: .default, handler: { [weak self, weak alert] _ in
            let value = String((alert?.textFields?.first?.text ?? "").prefix(DeletedMessageArchiveSettings.deletedMessageMarkerLimit))
            self?.update { $0.deletedMessageMarker = value }
        }))
        alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel)); self.present(alert, animated: true)
    }
    private func clear(mediaOnly: Bool) {
        let alert = CodeGramPlainAlertController(title: mediaOnly ? "Очистить медиа архива?" : "Очистить локальный архив?", message: "Это действие относится к данным на этом iPhone.", preferredStyle: .alert)
        alert.addAction(CodeGramPlainAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(CodeGramPlainAlertAction(title: "Очистить", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            let signal = mediaOnly ? self.context.engine.messages.clearDeletedMessageArchiveMedia() : self.context.engine.messages.clearDeletedMessageArchive()
            self.subscriptions.add((signal |> deliverOnMainQueue).start(completed: { [weak self] in self?.refreshStats() }))
        })); self.present(alert, animated: true)
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        guard let settings else { return [] }
        let s = self.context.sharedContext.currentPresentationData.with { $0 }.strings.localFeatures.localMessageArchive
        let usage = self.stats.map { "\($0.messageCount) удалённых · \($0.versionCount) версий · " + ByteCountFormatter.string(fromByteCount: $0.mediaSize, countStyle: .binary) } ?? "Загрузка…"
        return [CodeGramSettingsSection(title: s.saveSection, footer: nil, rows: [
            self.flag(s.archiveDeletedMessages, \.saveDeletedMessages, icon: "trash"), self.flag(s.archiveEditedMessages, \.saveEditedVersions, icon: "pencil.and.list.clipboard"),
            self.flag(s.archiveChats, \.saveMessagesFromArchivedChats, icon: "archivebox"), self.flag(s.keepBetweenLaunches, \.keepAcrossLaunches, icon: "internaldrive")]),
            CodeGramSettingsSection(title: s.deletedMessageMarker, footer: s.deletedMessageMarkerInfo, rows: [self.textRow(s.deletedMessageMarker, detail: settings.deletedMessageMarker, icon: "tag", action: { [weak self] in self?.editMarker() })]),
            CodeGramSettingsSection(title: s.storageSection, footer: s.clearActionsInfo, rows: [
                self.textRow(s.mediaLimit, detail: "\(settings.mediaLimitGigabytes) ГБ", icon: "internaldrive", action: { [weak self] in self?.selectLimit(disappearing: false) }),
                self.textRow(s.disappearingMediaLimit, detail: "\(settings.disappearingMediaLimitGigabytes) ГБ", icon: "timer", action: { [weak self] in self?.selectLimit(disappearing: true) }),
                self.textRow(s.archiveUsage, detail: usage, icon: "chart.bar"),
                self.textRow(s.clearMedia, icon: "trash", action: { [weak self] in self?.clear(mediaOnly: true) }),
                self.textRow(s.clearArchive, icon: "externaldrive.badge.xmark", action: { [weak self] in self?.clear(mediaOnly: false) })])]
    }
}

final class CodeGramFiltersController: CodeGramFeatureController {
    private var settings: MessageFilterSettings?
    private var peers: [EnginePeer] = []
    init(context: AccountContext) {
        super.init(context: context, title: "Фильтры сообщений")
        self.observe(messageFilterSettingsSignal() |> mapToSignal { settings -> Signal<(MessageFilterSettings, [EnginePeer]), NoError> in
            let ids = settings.shadowBannedPeerIds.sorted().map(EnginePeer.Id.init)
            if ids.isEmpty { return .single((settings, [])) }
            return context.engine.data.get(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) })) |> map { values in (settings, ids.compactMap { values[$0].flatMap { $0 } }) }
        }) { [weak self] value in self?.settings = value.0; self?.peers = value.1; self?.reloadContent() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func makeSections() -> [CodeGramSettingsSection] {
        guard let settings else { return [] }
        let s = self.context.sharedContext.currentPresentationData.with { $0 }.strings.localFeatures.messageFilter
        return [CodeGramSettingsSection(title: nil, footer: s.hideBlockedUsersInfo, rows: [
            self.switchRow(s.hideBlockedUsers, value: settings.hideBlockedUsersMessages, icon: "person.slash", changed: { value in MessageFilterSettingsStore.shared.update { current in var current = current; current.hideBlockedUsersMessages = value; return current } })]),
            CodeGramSettingsSection(title: s.hiddenPeersSection, footer: self.peers.isEmpty ? s.hiddenPeersEmpty : s.hiddenPeersInfo, rows: self.peers.map { peer in
                self.textRow(peer.debugDisplayTitle, detail: s.show, icon: "eye", action: {
                    MessageFilterSettingsStore.shared.update { current in var current = current; current.shadowBannedPeerIds.remove(peer.id.toInt64()); return current }
                })
            })]
    }
}

final class CodeGramGeneralController: CodeGramFeatureController {
    private let section: CodeGramLegacySettingsSection
    private var interface: InterfaceTuningSettings?
    private var powerSaving = false
    init(context: AccountContext, section: CodeGramLegacySettingsSection) {
        self.section = section
        super.init(context: context, title: section.title)
        self.observe(interfaceTuningSettingsSignal()) { [weak self] value in self?.interface = value; self?.reloadContent() }
        self.observe(context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings, ApplicationSpecificSharedDataKeys.presentationThemeSettings])) { [weak self] data in
            let download = data.entries[ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]?.get(MediaAutoDownloadSettings.self) ?? .defaultSettings
            let theme = data.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? .defaultSettings
            let energy = download.energyUsageSettings
            self?.powerSaving = energy.activationThreshold >= 96 && !energy.autoplayVideo && !energy.autoplayGif && !energy.loopStickers && !energy.loopEmoji && !energy.fullTranslucency && !energy.extendBackgroundWork && !energy.autodownloadInBackground && theme.reduceMotion
            self?.reloadContent()
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func flag(_ title: String, info: String, key: WritableKeyPath<InterfaceTuningSettings, Bool>, icon: String) -> CodeGramSettingsRow {
        return self.switchRow(title, value: self.interface?[keyPath: key] ?? false, detail: info, icon: icon, changed: { value in InterfaceTuningSettingsStore.shared.update { current in var current = current; current[keyPath: key] = value; return current } })
    }
    private func setPowerSaving(_ value: Bool) {
        self.subscriptions.add(updateMediaDownloadSettingsInteractively(accountManager: self.context.sharedContext.accountManager, { settings in
            var settings = settings
            settings.energyUsageSettings = value ? .powerSavingDefault : .default
            if value { settings.energyUsageSettings.activationThreshold = 96 }
            return settings
        }).start())
        self.subscriptions.add(updatePresentationThemeSettingsInteractively(accountManager: self.context.sharedContext.accountManager, { settings in var settings = settings; settings.reduceMotion = value; return settings }).start())
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        let s = self.context.sharedContext.currentPresentationData.with { $0 }.strings.localFeatures
        let rows: [CodeGramSettingsRow]
        let footer: String
        switch self.section {
        case .privacy:
            footer = s.madgram.privacyInfo
            rows = [self.textRow(s.ghostMode.title, icon: "eye.slash", action: { [weak self] in guard let self else { return }; self.push(CodeGramGhostController(context: self.context)) }),
                self.flag(s.interfaceTuning.hidePhoneInSettings, info: s.interfaceTuning.hidePhoneInSettingsInfo, key: \.hidePhoneInSettings, icon: "phone")]
        case .messages:
            footer = s.madgram.messagesInfo
            rows = [self.textRow(s.localMessageArchive.title, icon: "archivebox", action: { [weak self] in guard let self else { return }; self.push(CodeGramLocalArchiveController(context: self.context)) }),
                self.textRow(s.messageFilter.title, icon: "line.3.horizontal.decrease", action: { [weak self] in guard let self else { return }; self.push(CodeGramFiltersController(context: self.context)) })]
        case .appearance:
            footer = "Liquid Glass отключён во всём приложении. Панели и элементы управления используют непрозрачное оформление."
            rows = [self.textRow("Иконка приложения", detail: "Твои иконки и живая карусель", icon: "app", action: { [weak self] in guard let self else { return }; self.push(CodeGramIconPickerController(context: self.context)) }),
                self.textRow("Непрозрачное оформление", detail: "Liquid Glass отключён во всём приложении.", icon: "rectangle.on.rectangle"),
                self.flag(s.interfaceTuning.showAppBadge, info: s.interfaceTuning.showAppBadgeInfo, key: \.showAppBadge, icon: "capsule"),
                self.textRow(s.interfaceTuning.title, icon: "slider.horizontal.3", action: { [weak self] in guard let self else { return }; self.push(CodeGramInterfaceController(context: self.context)) })]
        case .additional:
            footer = s.madgram.powerSavingInfo
            rows = [self.switchRow(s.madgram.powerSaving, value: self.powerSaving, detail: s.madgram.powerSavingInfo, icon: "leaf", changed: { [weak self] value in self?.setPowerSaving(value) }),
                self.switchRow(s.localPremium.title, value: LocalPremiumSettingsStore.shared.current.isEnabled, detail: s.localPremium.info, icon: "star", changed: { value in LocalPremiumSettingsStore.shared.update { current in var current = current; current.isEnabled = value; return current } })]
        }
        return [CodeGramSettingsSection(title: nil, footer: footer, rows: rows)]
    }
}

final class CodeGramInterfaceController: CodeGramFeatureController {
    private var settings: InterfaceTuningSettings?
    init(context: AccountContext) {
        super.init(context: context, title: "Параметры интерфейса")
        self.observe(interfaceTuningSettingsSignal()) { [weak self] value in self?.settings = value; self?.reloadContent() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func flag(_ key: InterfaceTuningKey, title: String, info: String, value: Bool, enabled: Bool, icon: String) -> CodeGramSettingsRow {
        return self.switchRow(title, value: value, detail: info, icon: icon, enabled: enabled, changed: { value in
            InterfaceTuningSettingsStore.shared.update { updatedInterfaceTuningSettings($0, key: key, value: value) }
        })
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        guard let settings else { return [] }
        let strings = self.context.sharedContext.currentPresentationData.with { $0 }.strings.localFeatures.interfaceTuning
        let barControlsEnabled = !settings.concealBottomBar
        return [CodeGramSettingsSection(title: strings.tabsSection, footer: strings.restartNotice, rows: [
                self.flag(.concealBottomBar, title: strings.concealBottomBar, info: strings.concealBottomBarInfo, value: settings.concealBottomBar, enabled: true, icon: "rectangle.bottomthird.inset.filled"),
                self.flag(.showContactsShortcut, title: strings.showContactsShortcut, info: strings.showContactsShortcutInfo, value: settings.showContactsShortcut, enabled: barControlsEnabled, icon: "person.crop.circle"),
                self.flag(.showCallsShortcut, title: strings.showCallsShortcut, info: strings.showCallsShortcutInfo, value: settings.showCallsShortcut, enabled: barControlsEnabled, icon: "phone"),
                self.flag(.showTabLabels, title: strings.showTabLabels, info: strings.showTabLabelsInfo, value: settings.showTabLabels, enabled: barControlsEnabled, icon: "textformat.abc"),
                self.flag(.showSearchShortcut, title: strings.showSearchShortcut, info: strings.showSearchShortcutInfo, value: settings.showSearchShortcut, enabled: barControlsEnabled, icon: "magnifyingglass"),
                self.flag(.stretchBottomBar, title: strings.stretchBottomBar, info: strings.stretchBottomBarInfo, value: settings.stretchBottomBar, enabled: barControlsEnabled, icon: "arrow.left.and.right")]),
            CodeGramSettingsSection(title: strings.profilesSection, footer: nil, rows: [
                self.flag(.showProfileIdentifiers, title: strings.showProfileIdentifiers, info: strings.showProfileIdentifiersInfo, value: settings.showProfileIdentifiers, enabled: true, icon: "number"),
                self.flag(.showDataCenter, title: strings.showDataCenter, info: strings.showDataCenterInfo, value: settings.showDataCenter, enabled: true, icon: "server.rack"),
                self.flag(.showRegistrationDate, title: strings.showRegistrationDate, info: strings.showRegistrationDateInfo, value: settings.showRegistrationDate, enabled: true, icon: "calendar.badge.clock"),
                self.flag(.showChatCreationDate, title: strings.showChatCreationDate, info: strings.showChatCreationDateInfo, value: settings.showChatCreationDate, enabled: true, icon: "calendar.badge.plus")]),
            CodeGramSettingsSection(title: strings.storiesSection, footer: nil, rows: [
                self.flag(.hideStoryStrip, title: strings.hideStoryStrip, info: strings.hideStoryStripInfo, value: settings.hideStoryStrip, enabled: true, icon: "rectangle.stack.badge.minus"),
                self.flag(.disableStoryCameraSwipe, title: strings.disableStoryCameraSwipe, info: strings.disableStoryCameraSwipeInfo, value: settings.disableStoryCameraSwipe, enabled: true, icon: "hand.draw"),
                self.flag(.confirmStoryOpen, title: strings.confirmStoryOpen, info: strings.confirmStoryOpenInfo, value: settings.confirmStoryOpen, enabled: true, icon: "hand.raised"),
                self.flag(.allowStoryRepost, title: strings.allowStoryRepost, info: strings.allowStoryRepostInfo, value: settings.allowStoryRepost, enabled: true, icon: "arrowshape.turn.up.right")]),
            CodeGramSettingsSection(title: strings.chatsSection, footer: strings.businessBotPanelExceptionsInfo, rows: [
                self.flag(.showCallbackData, title: strings.showCallbackData, info: strings.showCallbackDataInfo, value: settings.showCallbackData, enabled: true, icon: "curlybraces"),
                self.flag(.hideBusinessBotPanel, title: strings.hideBusinessBotPanel, info: strings.hideBusinessBotPanelInfo, value: settings.hideBusinessBotPanel, enabled: true, icon: "briefcase"),
                self.textRow(strings.businessBotPanelExceptions, icon: "person.crop.rectangle", action: { [weak self] in guard let self else { return }; self.push(CodeGramBusinessExceptionsController(context: self.context)) })]),
            CodeGramSettingsSection(title: strings.cameraSection, footer: nil, rows: [
                self.flag(.startRoundVideoWithRearCamera, title: strings.startRoundVideoWithRearCamera, info: strings.startRoundVideoWithRearCameraInfo, value: settings.startRoundVideoWithRearCamera, enabled: true, icon: "arrow.triangle.2.circlepath.camera"),
                self.flag(.hideGalleryCamera, title: strings.hideGalleryCamera, info: strings.hideGalleryCameraInfo, value: settings.hideGalleryCamera ?? false, enabled: true, icon: "camera.badge.ellipsis")])]
    }
}

final class CodeGramBusinessExceptionsController: CodeGramFeatureController {
    private var settings: InterfaceTuningSettings?
    private var peers: [EnginePeer] = []
    init(context: AccountContext) {
        super.init(context: context, title: "Исключения панели ботов")
        self.observe(interfaceTuningSettingsSignal() |> mapToSignal { settings -> Signal<(InterfaceTuningSettings, [EnginePeer]), NoError> in
            let ids = settings.businessBotPanelVisibilityOverrides.keys.sorted().map(EnginePeer.Id.init)
            if ids.isEmpty { return .single((settings, [])) }
            return context.engine.data.get(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) })) |> map { values in (settings, ids.compactMap { values[$0].flatMap { $0 } }) }
        }) { [weak self] value in self?.settings = value.0; self?.peers = value.1; self?.reloadContent() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func add() {
        let selection = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, filter: [.onlyPrivateChats, .excludeSavedMessages, .excludeSecretChats, .excludeRecent, .doNotSearchMessages, .removeSearchHeader], hasContactSelector: false, title: "Добавить исключение"))
        selection.peerSelected = { [weak self, weak selection] peer, _ in
            guard let self else { return }
            self.observe(self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.ChatManagingBot(id: peer.id))) { [weak self, weak selection] bot in
                guard bot != nil else { self?.notice("Этот диалог не управляется бизнес-ботом."); return }
                InterfaceTuningSettingsStore.shared.update { current in var current = current; current.businessBotPanelVisibilityOverrides[peer.id.toInt64()] = current.hideBusinessBotPanel; return current }
                selection?.dismiss()
            }
        }
        self.push(selection)
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        guard let settings else { return [] }
        let rows = self.peers.map { peer in
            self.switchRow(peer.debugDisplayTitle, value: settings.isBusinessBotPanelVisible(peerId: peer.id.toInt64()), icon: "person.crop.rectangle", changed: { value in
                InterfaceTuningSettingsStore.shared.update { current in
                    var current = current
                    if value == !current.hideBusinessBotPanel { current.businessBotPanelVisibilityOverrides.removeValue(forKey: peer.id.toInt64()) }
                    else { current.businessBotPanelVisibilityOverrides[peer.id.toInt64()] = value }
                    return current
                }
            })
        }
        return [CodeGramSettingsSection(title: nil, footer: "Переключатель определяет видимость панели в выбранном диалоге. Возврат к общему значению удаляет исключение.", rows: [self.textRow("Добавить исключение", icon: "plus", action: { [weak self] in self?.add() })] + rows)]
    }
}


