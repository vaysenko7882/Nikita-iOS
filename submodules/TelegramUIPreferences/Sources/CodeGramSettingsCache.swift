import Foundation

/// Callers serialize access with their store's lock. Preferences are still read
/// on every lookup so changes from extensions are visible, but unchanged bytes
/// must not rebuild large blocked/shadow-ban sets during every row layout.
struct CodeGramSettingsCache<Value: Codable> {
    private var storedData: Data?
    private(set) var value: Value

    init(defaultValue: Value, data: Data?) {
        self.value = defaultValue
        self.reload(data: data)
    }

    mutating func reload(data: Data?) {
        guard self.storedData != data else { return }
        self.storedData = data
        if let data, let decoded = try? JSONDecoder().decode(Value.self, from: data) {
            self.value = decoded
        }
    }

    mutating func store(_ value: Value) -> Data? {
        self.value = value
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        self.storedData = data
        return data
    }
}
