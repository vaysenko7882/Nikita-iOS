import Foundation
import Postbox

/// Durable identity only. Credentials are obtained from this account's Keychain
/// when fetching, never persisted in Postbox or FlatBuffers media records.
public final class NikitaArchiveMediaResource: TelegramMediaResource {
    public let accountId: Int64
    public let serverId: String
    public let blobId: String
    public let size: Int64?
    public let sha256: String

    public init(accountId: Int64, serverId: String, blobId: String, size: Int64, sha256: String) {
        self.accountId = accountId
        self.serverId = serverId
        self.blobId = blobId
        self.size = size
        self.sha256 = sha256
    }

    public init(decoder: PostboxDecoder) {
        self.accountId = decoder.decodeInt64ForKey("a", orElse: 0)
        self.serverId = decoder.decodeStringForKey("e", orElse: "")
        self.blobId = decoder.decodeStringForKey("b", orElse: "")
        self.size = decoder.decodeInt64ForKey("s", orElse: 0)
        self.sha256 = decoder.decodeStringForKey("h", orElse: "")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64(self.accountId, forKey: "a")
        encoder.encodeString(self.serverId, forKey: "e")
        encoder.encodeString(self.blobId, forKey: "b")
        encoder.encodeInt64(self.size ?? 0, forKey: "s")
        encoder.encodeString(self.sha256, forKey: "h")
    }

    public var id: MediaResourceId {
        return MediaResourceId("nikita-archive-\(self.accountId)-\(self.serverId)-\(self.blobId)")
    }

    public var streamable: Bool { return true }

    var isValid: Bool {
        return self.accountId > 0 && self.serverId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
            && self.blobId.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
            && (self.size ?? 0) > 0 && (self.size ?? 0) <= 8 * 1024 * 1024 * 1024
            && (self.sha256.isEmpty || self.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
    }

    public func isEqual(to: MediaResource) -> Bool {
        guard let other = to as? NikitaArchiveMediaResource else { return false }
        return self.id == other.id && self.size == other.size
    }
}
