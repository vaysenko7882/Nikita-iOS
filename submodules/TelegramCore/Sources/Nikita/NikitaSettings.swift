import Foundation
import Security

public struct NikitaServerConfiguration: Equatable {
    public let enabled: Bool
    public let address: String
    public let token: String

    public init(enabled: Bool, address: String, token: String) {
        self.enabled = enabled
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var baseURL: URL? {
        guard let components = URLComponents(string: self.address),
            components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil else {
            return nil
        }
        return components.url
    }

    public var hasValidToken: Bool {
        return self.token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil
    }
}

public final class NikitaSettingsStore {
    public static let shared = NikitaSettingsStore()
    public static let changed = Notification.Name("NikitaSettingsChanged")
    private let defaults = UserDefaults.standard
    private let tokenService = "personal.nikita.messenger.archive"

    private init() {
    }

    public var voiceEffect: NikitaVoiceEffect {
        get { return NikitaVoiceEffect(rawValue: self.defaults.string(forKey: "nikita.voiceEffect") ?? "off") ?? .off }
        set {
            self.defaults.set(newValue.rawValue, forKey: "nikita.voiceEffect")
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    public var extendArchiveInBackground: Bool {
        get { return self.defaults.object(forKey: "nikita.extendArchiveInBackground") as? Bool ?? true }
        set {
            self.defaults.set(newValue, forKey: "nikita.extendArchiveInBackground")
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private func tokenQuery(account: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.tokenService,
            kSecAttrAccount as String: account]
    }

    public func server(account: String) -> NikitaServerConfiguration {
        var query = self.tokenQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let token = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
        return NikitaServerConfiguration(
            enabled: self.defaults.bool(forKey: "nikita.server.enabled.\(account)"),
            address: self.defaults.string(forKey: "nikita.server.address.\(account)") ?? "", token: token)
    }

    /// The archive API bearer token stays in this device's Keychain, outside backups.
    @discardableResult
    public func setServer(_ configuration: NikitaServerConfiguration, account: String) -> Bool {
        let query = self.tokenQuery(account: account)
        let data = Data(configuration.token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            return false
        }
        self.defaults.set(configuration.enabled, forKey: "nikita.server.enabled.\(account)")
        self.defaults.set(configuration.address, forKey: "nikita.server.address.\(account)")
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return true
    }
}
