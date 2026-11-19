import SwiftUI

/// Состояние приложения: адрес сервера, ссылка, которую нужно открыть, и что сейчас происходит на странице
final class AppModel: ObservableObject {
    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    /// Путь на сервере, который нужно открыть (из ссылки slou://r/КОД)
    @Published var pendingPath: String?
    @Published var showSettings = false
    /// Человек в комнате — экран не гаснет
    @Published var inRoom = false
    /// Идёт битва за корону — прячем строку состояния и полоску «домой»
    @Published var duel = false
    /// Плеер на весь экран — тоже прячем
    @Published var immersive = false

    init() {
        let preset = (Bundle.main.object(forInfoDictionaryKey: "SlouServer") as? String) ?? ""
        server = UserDefaults.standard.string(forKey: "server") ?? preset
    }

    var serverURL: URL? { AppModel.normalize(server) }

    /// «slows.best», «203.0.113.7» или полный адрес → https://хост
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty, host.contains(".") || host == "localhost" else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// slou://r/КОД, slou://КОД, slou://settings и обычная ссылка-приглашение ?join=КОД
    func handle(url: URL) {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "slou" {
            var parts: [String] = []
            if let host = url.host, !host.isEmpty { parts.append(host) }
            parts += url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if parts.first?.lowercased() == "settings" {
                showSettings = true
                return
            }
            if let last = parts.last {
                let code = String(last.uppercased().filter { $0.isLetter || $0.isNumber })
                if code.count == 8 { pendingPath = "/?join=" + code }
            }
            return
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let join = items.first(where: { $0.name == "join" })?.value, !join.isEmpty {
            pendingPath = "/?join=" + join
        }
    }
}
