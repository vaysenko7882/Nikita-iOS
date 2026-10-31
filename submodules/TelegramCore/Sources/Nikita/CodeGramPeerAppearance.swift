import Foundation
import Postbox
import SwiftSignalKit

public struct CodeGramPeerAppearance: Codable, Equatable {
    public var title: String?
    public var avatar: String?
    public var resourceId: Int64
    public var revision: Int64
    public init(title: String? = nil, avatar: String? = nil, resourceId: Int64 = 0, revision: Int64 = 0) {
        self.title = title; self.avatar = avatar; self.resourceId = resourceId; self.revision = revision
    }
}

/// Presentation metadata stays on this iPhone. Original peer names and photos
/// are always used by Postbox/FlatBuffers encoders and Telegram RPCs.
public final class CodeGramPeerAppearanceStore {
    public static let shared = CodeGramPeerAppearanceStore()
    private let lock = NSLock()
    private var values: [String: CodeGramPeerAppearance]
    private let images = NSCache<NSString, NSData>()
    private init() {
        self.values = UserDefaults.standard.data(forKey: "codegram.peerAppearance").flatMap {
            try? JSONDecoder().decode([String: CodeGramPeerAppearance].self, from: $0)
        } ?? [:]
        self.images.totalCostLimit = 8 * 1024 * 1024
    }
    private var directory: URL {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodeGramAvatars", isDirectory: true)
    }
    public func appearance(_ id: PeerId) -> CodeGramPeerAppearance {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.values[String(id.toInt64())] ?? CodeGramPeerAppearance()
    }
    public var peerIds: [PeerId] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.values.filter { $0.value.title != nil || $0.value.avatar != nil }.keys.compactMap(Int64.init).map(PeerId.init)
    }
    public func imageData(_ appearance: CodeGramPeerAppearance) -> Data? {
        guard let name = appearance.avatar, UUID(uuidString: name) != nil else { return nil }
        if let value = self.images.object(forKey: name as NSString) { return value as Data }
        guard let data = try? Data(contentsOf: self.directory.appendingPathComponent(name)), data.count <= 1024 * 1024 else { return nil }
        self.images.setObject(data as NSData, forKey: name as NSString, cost: data.count)
        return data
    }
    @discardableResult public func set(_ id: PeerId, title: String?, jpeg: Data? = nil, removeAvatar: Bool = false, reset: Bool = false) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        let key = String(id.toInt64())
        let old = self.values[key] ?? CodeGramPeerAppearance()
        var value = old
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.title = title.flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        value.revision = old.revision &+ 1
        if let jpeg {
            guard jpeg.count <= 1024 * 1024 else { return false }
            let name = UUID().uuidString
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try jpeg.write(to: self.directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { return false }
            value.avatar = name
            value.resourceId = Int64.random(in: 1 ... Int64.max)
        } else if removeAvatar || reset { value.avatar = nil; value.resourceId = 0 }
        if reset { value.title = nil }
        self.values[key] = value
        guard let data = try? JSONEncoder().encode(self.values) else { return false }
        UserDefaults.standard.set(data, forKey: "codegram.peerAppearance")
        if let name = old.avatar, name != value.avatar {
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(name))
            self.images.removeObject(forKey: name as NSString)
        }
        return true
    }
}

func codegramUpdatePeerAppearance(postbox: Postbox, peerId: PeerId, title: String?, jpeg: Data? = nil, removeAvatar: Bool = false, reset: Bool = false) -> Signal<Bool, NoError> {
    return postbox.transaction { transaction -> Bool in
        guard let peer = transaction.getPeer(peerId) else { return false }
        let encoder = PostboxEncoder()
        encoder.encodeRootObject(peer)
        guard CodeGramPeerAppearanceStore.shared.set(peerId, title: title, jpeg: jpeg, removeAvatar: removeAvatar, reset: reset),
            let updated = PostboxDecoder(buffer: encoder.makeReadBuffer()).decodeRootObject() as? Peer else { return false }
        updatePeersCustom(transaction: transaction, peers: [updated], update: { _, next in next })
        return true
    }
}

public extension TelegramEngine {
    /// Feature-specific facade; callers never receive a Postbox/MediaBox handle.
    func codegramLocalPeerAppearances() -> Signal<[EnginePeer], NoError> {
        let ids = CodeGramPeerAppearanceStore.shared.peerIds
        return self.account.postbox.transaction { transaction in
            ids.compactMap { transaction.getPeer($0).map(EnginePeer.init) }
        }
    }
    func updateCodeGramPeerAppearance(peerId: EnginePeer.Id, title: String?, jpeg: Data? = nil, removeAvatar: Bool = false, reset: Bool = false) -> Signal<Bool, NoError> {
        return codegramUpdatePeerAppearance(postbox: self.account.postbox, peerId: peerId, title: title, jpeg: jpeg, removeAvatar: removeAvatar, reset: reset)
    }
}
