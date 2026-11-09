import Foundation
import SwiftSignalKit

public struct LocalPremiumSettings: Codable, Equatable {
    public var isEnabled: Bool

    public static let defaultSettings = LocalPremiumSettings(isEnabled: false)

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

public final class LocalPremiumSettingsStore {
    public static let shared = LocalPremiumSettingsStore()
    public static let didChangeNotification = Notification.Name("LocalPremiumSettingsStore.didChange")

    private let defaults: UserDefaults
    private let key = "localPremiumSettings.v1"
    private let lock = NSLock()
    private var cache: CodeGramSettingsCache<LocalPremiumSettings>

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cache = CodeGramSettingsCache(defaultValue: .defaultSettings, data: defaults.data(forKey: self.key))
    }

    public var current: LocalPremiumSettings {
        self.lock.lock()
        self.cache.reload(data: self.defaults.data(forKey: self.key))
        let value = self.cache.value
        self.lock.unlock()
        return value
    }

    @discardableResult
    public func update(_ f: (LocalPremiumSettings) -> LocalPremiumSettings) -> LocalPremiumSettings {
        self.lock.lock()
        self.cache.reload(data: self.defaults.data(forKey: self.key))
        let currentValue = self.cache.value
        let updatedValue = f(currentValue)
        if let data = self.cache.store(updatedValue) {
            self.defaults.set(data, forKey: self.key)
        }
        self.lock.unlock()

        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return updatedValue
    }
}

public func localPremiumSettingsSignal() -> Signal<LocalPremiumSettings, NoError> {
    return Signal { subscriber in
        subscriber.putNext(LocalPremiumSettingsStore.shared.current)
        let observer = NotificationCenter.default.addObserver(
            forName: LocalPremiumSettingsStore.didChangeNotification,
            object: nil,
            queue: nil,
            using: { _ in
                subscriber.putNext(LocalPremiumSettingsStore.shared.current)
            }
        )
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    |> distinctUntilChanged
}
