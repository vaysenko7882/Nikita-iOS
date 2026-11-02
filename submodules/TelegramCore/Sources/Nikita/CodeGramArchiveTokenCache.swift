import Foundation

/// Successful device-local Keychain reads are stable until setServer writes a
/// new token. A locked/unavailable Keychain returns nil and is retried later.
final class CodeGramArchiveTokenCache {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(account: String, load: () -> String?) -> String {
        self.lock.lock(); defer { self.lock.unlock() }
        if let token = self.tokens[account] { return token }
        guard let token = load() else { return "" }
        self.tokens[account] = token
        return token
    }

    func store(account: String, token: String, write: () -> Bool) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard write() else { return false }
        self.tokens[account] = token
        return true
    }
}
