import Foundation

public enum CodeGramSocialVideoLink {
    /// Only one standalone video URL is converted. Captions, multiple URLs,
    /// forwards, edits and arbitrary domains keep their ordinary send behavior.
    public static func url(in text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
            let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil, components.port == nil || components.port == 443,
            let host = components.host?.lowercased() else { return nil }
        let pattern: String
        switch host {
        case "tiktok.com", "www.tiktok.com", "m.tiktok.com": pattern = "^/@[A-Za-z0-9_.-]+/video/[0-9]+/?$"
        case "vm.tiktok.com", "vt.tiktok.com": pattern = "^/[A-Za-z0-9]+/?$"
        case "instagram.com", "www.instagram.com", "m.instagram.com": pattern = "^/(reel|reels|p|tv)/[A-Za-z0-9_-]+/?$"
        default: return nil
        }
        guard components.path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        var normalized = components
        normalized.host = host == "m.instagram.com" ? "www.instagram.com" : host == "m.tiktok.com" ? "www.tiktok.com" : host
        normalized.query = nil; normalized.fragment = nil
        return normalized.url
    }
}
