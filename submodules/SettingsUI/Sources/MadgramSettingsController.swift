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

public func madgramSettingsController(context: AccountContext) -> ViewController {
    return CodeGramDashboardController(context: context)
}

enum CodeGramLegacySettingsSection: Int32 {
    case privacy = 1
    case messages = 2
    case appearance = 3
    case additional = 4

    var title: String {
        switch self {
        case .privacy: return "Приватность"
        case .messages: return "Сообщения"
        case .appearance: return "Оформление"
        case .additional: return "Локальные функции"
        }
    }
}

func codegramSectionSettingsController(context: AccountContext, section: CodeGramLegacySettingsSection) -> ViewController {
    return CodeGramGeneralController(context: context, section: section)
}
