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
    public static let serverChanged = Notification.Name("CodeGramArchiveServerChanged")
    private let defaults = UserDefaults.standard
    private let tokenCache = CodeGramArchiveTokenCache()
    private let tokenService = "personal.nikita.messenger.archive"

    private init() {
    }

    public var voiceEffect: NikitaVoiceEffect {
        get { return NikitaVoiceEffect(rawValue: self.defaults.string(forKey: "nikita.voiceEffect") ?? "off") ?? .off }
        set {
            self.defaults.set(newValue.rawValue, forKey: "nikita.voiceEffect")
            self.defaults.removeObject(forKey: "codegram.voice.configuration")
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    public var voiceConfiguration: NikitaVoiceConfiguration {
        get {
            if let data = self.defaults.data(forKey: "codegram.voice.configuration"),
                let value = try? JSONDecoder().decode(NikitaVoiceConfiguration.self, from: data) { return value.normalized }
            return .preset(self.voiceEffect)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.normalized) {
                self.defaults.set(data, forKey: "codegram.voice.configuration")
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    public var voicePresets: [CodeGramVoicePreset] {
        get {
            return self.defaults.data(forKey: "codegram.voice.presets").flatMap {
                try? JSONDecoder().decode([CodeGramVoicePreset].self, from: $0)
            } ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue.prefix(24))) {
                self.defaults.set(data, forKey: "codegram.voice.presets")
            }
        }
    }

    public var allowsProtectedExport: Bool {
        get { return self.defaults.bool(forKey: "codegram.allowProtectedExport") }
        set { self.defaults.set(newValue, forKey: "codegram.allowProtectedExport"); NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    public var allowsRestrictedContent: Bool {
        get { return self.defaults.bool(forKey: "codegram.allowRestrictedContent") }
        set { self.defaults.set(newValue, forKey: "codegram.allowRestrictedContent"); NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    public var keepsEphemeralMedia: Bool {
        get { return self.defaults.bool(forKey: "codegram.keepsEphemeralMedia") }
        set { self.defaults.set(newValue, forKey: "codegram.keepsEphemeralMedia"); NotificationCenter.default.post(name: Self.changed, object: nil) }
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

    public func isServerEnabled(account: String) -> Bool {
        return self.defaults.bool(forKey: "nikita.server.enabled.\(account)")
    }

    public func server(account: String) -> NikitaServerConfiguration {
        let token = self.tokenCache.token(account: account) {
            var query = self.tokenQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return "" }
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return NikitaServerConfiguration(
            enabled: self.defaults.bool(forKey: "nikita.server.enabled.\(account)"),
            address: self.defaults.string(forKey: "nikita.server.address.\(account)") ?? "", token: token)
    }

    /// The archive API bearer token stays in this device's Keychain, outside backups.
    @discardableResult
    public func setServer(_ configuration: NikitaServerConfiguration, account: String) -> Bool {
        if self.server(account: account) == configuration { return true }
        let saved = self.tokenCache.store(account: account, token: configuration.token) {
            let query = self.tokenQuery(account: account)
            let data = Data(configuration.token.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { return false }
            self.defaults.set(configuration.enabled, forKey: "nikita.server.enabled.\(account)")
            self.defaults.set(configuration.address, forKey: "nikita.server.address.\(account)")
            return true
        }
        guard saved else { return false }
        NotificationCenter.default.post(name: Self.serverChanged, object: account)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return true
    }
}

