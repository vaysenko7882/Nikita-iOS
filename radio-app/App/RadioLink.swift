import Foundation
import Combine
import CryptoKit
import MultipeerConnectivity

struct RadioPeer: Identifiable, Codable, Equatable {
    let id: String
    var name: String
}

enum RadioWire {
    static let maximumAudioBytes = 4096

    static func audio(_ payload: Data, sender: String, target: String?) -> Data? {
        guard !payload.isEmpty, payload.count <= maximumAudioBytes,
              let senderUUID = UUID(uuidString: sender) else { return nil }
        var data = Data([1, 0])
        var source = senderUUID.uuid
        withUnsafeBytes(of: &source) { data.append(contentsOf: $0) }
        var destination = (target.flatMap(UUID.init(uuidString:)) ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))).uuid
        withUnsafeBytes(of: &destination) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func readAudio(_ data: Data) -> (sender: String, target: String?, audio: Data)? {
        guard data.count > 34, data.count <= maximumAudioBytes + 34,
              data[0] == 1, data[1] == 0 else { return nil }
        func identifier(_ offset: Int) -> String {
            let bytes = Array(data[offset..<(offset + 16)])
            return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
        }
        let targetBytes = data[18..<34]
        return (identifier(2), targetBytes.allSatisfy { $0 == 0 } ? nil : identifier(18), Data(data.dropFirst(34)))
    }
}

@MainActor
final class RadioLink: NSObject, ObservableObject {
    @Published private(set) var peers: [RadioPeer] = []
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Рация выключена"
    @Published var error: String?
    @Published private(set) var ownName = "Я"
    let localID: String
    var onAudio: ((Data) -> Void)?
    var onRemoteTalk: ((String, Bool) -> Void)?
    var onTalkDenied: (() -> Void)?

    private let serviceType = "svyazi-ptt"
    private var roomIdentifier = ""
    private var roomKey = Data()
    private var localPeer: MCPeerID?
    private var nearbySession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var knownNames: [String: String] = [:]
    private var invitations = Set<String>()
    private var invitationNonces = Set<String>()
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var receiverTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var speaking = false
    private var targetID: String?
    private var remoteSpeaker: String?
    private var lastReceivedAudio = Date.distantPast
    private var receiveExpiry: Task<Void, Never>?
    private var generation = UUID()
    private var internetAddress = ""
    private var pendingPushToken: (token: Data, channelID: UUID)?

    override init() {
        if let saved = UserDefaults.standard.string(forKey: "Nasvyazi.LocalID"), UUID(uuidString: saved) != nil {
            localID = saved.lowercased()
        } else {
            localID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(localID, forKey: "Nasvyazi.LocalID")
        }
        super.init()
    }

    func connect(room: String, name: String, serverURL: String = "") {
        disconnect()
        error = nil
        let secret = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.count >= 6, secret.count <= 128 else {
            error = "Код комнаты должен содержать от 6 до 128 символов."
            return
        }
        ownName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if ownName.isEmpty { ownName = "Участник" }
        roomIdentifier = Self.digest("nasvyazi-room-id-v1:" + secret)
        roomKey = Data(SHA256.hash(data: Data(("nasvyazi-room-key-v1:" + secret).utf8)))
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        internetAddress = server
        if server.isEmpty { connectNearby() } else { connectInternet(server) }
    }

    func updatePushToken(_ token: Data, channelID: UUID) {
        pendingPushToken = (token, channelID)
        registerPushToken()
    }

    func resumeConnection() {
        guard !internetAddress.isEmpty, !isConnected, !roomKey.isEmpty else { return }
        generation = UUID()
        receiverTask?.cancel(); receiverTask = nil
        pingTask?.cancel(); pingTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socketSession?.invalidateAndCancel()
        socket = nil; socketSession = nil
        connectInternet(internetAddress)
    }

    private func registerPushToken() {
        guard socket != nil, isConnected, let token = pendingPushToken else { return }
        sendControl(["type": "pushToken", "token": token.token.map { String(format: "%02x", $0) }.joined(), "channelUUID": token.channelID.uuidString])
    }

    func disconnect() {
        generation = UUID()
        if speaking { setTalking(false, targetID: targetID) }
        receiverTask?.cancel(); receiverTask = nil
        pingTask?.cancel(); pingTask = nil
        receiveExpiry?.cancel(); receiveExpiry = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        socketSession?.invalidateAndCancel(); socketSession = nil
        browser?.stopBrowsingForPeers(); browser = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        nearbySession?.disconnect(); nearbySession = nil
        localPeer = nil
        peers = []
        knownNames = [:]
        invitations = []
        invitationNonces = []
        isConnected = false
        internetAddress = ""
        status = "Рация выключена"
        endRemoteSpeech()
    }

    func sendAudio(_ audio: Data) {
        guard isConnected, speaking,
              let frame = RadioWire.audio(audio, sender: localID, target: targetID) else { return }
        if let session = nearbySession {
            let destinations = session.connectedPeers.filter { targetID == nil || $0.displayName == targetID }
            guard !destinations.isEmpty else { return }
            do { try session.send(frame, toPeers: destinations, with: .unreliable) }
            catch { self.error = "Не удалось передать звук. Проверьте соединение." }
        } else if let socket {
            let current = generation
            Task { [weak self] in
                do { try await socket.send(.data(frame)) }
                catch { if self?.generation == current { self?.transportFailed(error) } }
            }
        }
    }

    func setTalking(_ active: Bool, targetID: String? = nil) {
        guard isConnected || !active else { return }
        let target = targetID.flatMap { UUID(uuidString: $0) == nil ? nil : $0.lowercased() }
        speaking = active
        if active { self.targetID = target }
        sendControl(["type": "talk", "id": localID, "name": ownName, "active": active, "target": self.targetID as Any? ?? NSNull()])
        if !active { self.targetID = nil }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func proof(_ text: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: roomKey))
        return Data(mac).base64EncodedString()
    }

    private func connectNearby() {
        let peer = MCPeerID(displayName: localID)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        localPeer = peer
        nearbySession = session
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["room": roomIdentifier, "name": ownName, "v": "1"], serviceType: serviceType)
        advertiser?.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)
        browser?.delegate = self
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
        isConnected = true
        status = "Ищем друзей рядом…"
    }

    private func connectInternet(_ address: String) {
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), let host = components.host,
              scheme == "wss" || (scheme == "ws" && Self.isLocalHost(host)) else {
            error = "Нужен адрес wss:// сервера. ws:// разрешён только в локальной сети."
            return
        }
        var accessToken: String?
        if let fragment = components.fragment {
            accessToken = URLComponents(string: "https://local/?" + fragment)?.queryItems?.first(where: { $0.name == "token" })?.value
        }
        components.fragment = nil
        if components.path.isEmpty || components.path == "/" { components.path = "/ws" }
        guard let url = components.url else { error = "Некорректный адрес сервера."; return }
        var request = URLRequest(url: url)
        if let accessToken, !accessToken.isEmpty { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let connection = session.webSocketTask(with: request)
        socketSession = session
        socket = connection
        status = "Подключаемся к серверу…"
        let current = generation
        connection.resume()
        receiverTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await connection.receive()
                    guard let self, self.generation == current else { return }
                    switch message {
                    case .string(let text): self.receiveControl(Data(text.utf8), from: nil)
                    case .data(let data): self.receiveAudio(data, from: nil)
                    @unknown default: break
                    }
                } catch {
                    if let self, self.generation == current, !Task.isCancelled { self.transportFailed(error) }
                    return
                }
            }
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, self?.generation == current else { return }
                connection.sendPing { [weak self] error in
                    if let error { Task { @MainActor in if self?.generation == current { self?.transportFailed(error) } } }
                }
            }
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        let pieces = host.split(separator: ".")
        return pieces.count == 4 && pieces[0] == "172" && (Int(pieces[1]).map { 16...31 ~= $0 } ?? false)
    }

    private func transportFailed(_ failure: Error) {
        guard socket != nil else { return }
        isConnected = false
        status = "Соединение потеряно"
        error = "Проверьте сервер и интернет, затем подключитесь снова."
        speaking = false
        onTalkDenied?()
        endRemoteSpeech()
    }

    private func sendControl(_ object: [String: Any], to destination: MCPeerID? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        if let session = nearbySession {
            let destinations = destination.map { [$0] } ?? session.connectedPeers.filter { targetID == nil || $0.displayName == targetID }
            guard !destinations.isEmpty else { return }
            do { try session.send(data, toPeers: destinations, with: .reliable) }
            catch { error = "Друг отключился от комнаты." }
        } else if let socket, let string = String(data: data, encoding: .utf8) {
            let current = generation
            Task { [weak self] in
                do { try await socket.send(.string(string)) }
                catch { if self?.generation == current { self?.transportFailed(error) } }
            }
        }
    }

    private func receiveControl(_ data: Data, from peer: MCPeerID?) {
        guard data.count <= 8192,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        if type == "challenge", peer == nil, let nonce = message["nonce"] as? String {
            let key = roomKey.map { String(format: "%02x", $0) }.joined()
            sendControl(["type": "hello", "room": roomIdentifier, "key": key, "id": localID, "name": ownName,
                         "proof": proof(nonce + ":" + localID + ":" + roomIdentifier)])
        } else if type == "welcome", peer == nil {
            isConnected = true
            status = "В комнате · интернет"
            registerPushToken()
        } else if type == "peers", peer == nil, let list = message["peers"] as? [[String: String]] {
            peers = list.compactMap { item in
                guard let id = item["id"], UUID(uuidString: id) != nil, id != localID else { return nil }
                return RadioPeer(id: id.lowercased(), name: String((item["name"] ?? "Участник").prefix(24)))
            }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            knownNames = [:]
            for peer in peers { knownNames[peer.id] = peer.name }
        } else if type == "hello", let peer {
            guard message["id"] as? String == peer.displayName else { return }
            knownNames[peer.displayName] = String((message["name"] as? String ?? "Участник").prefix(24))
            refreshNearbyPeers()
        } else if type == "talk", let id = message["id"] as? String, let active = message["active"] as? Bool {
            guard peer == nil || id == peer?.displayName else { return }
            if let target = message["target"] as? String, target != localID { return }
            guard id != localID, knownNames[id] != nil else { return }
            if active {
                remoteSpeaker = id
                lastReceivedAudio = Date()
                onRemoteTalk?(knownNames[id] ?? "Участник", true)
                armReceiveExpiry()
            } else if remoteSpeaker == id { endRemoteSpeech() }
        } else if type == "busy" || type == "error" {
            error = String((message["message"] as? String ?? "Сервер отклонил запрос.").prefix(200))
            if type == "busy" { speaking = false; onTalkDenied?() }
        }
    }

    private func receiveAudio(_ frame: Data, from peer: MCPeerID?) {
        guard let packet = RadioWire.readAudio(frame), packet.sender != localID,
              packet.target == nil || packet.target == localID,
              peer == nil || packet.sender == peer?.displayName,
              knownNames[packet.sender] != nil else { return }
        if remoteSpeaker != packet.sender {
            remoteSpeaker = packet.sender
            onRemoteTalk?(knownNames[packet.sender] ?? "Участник", true)
            armReceiveExpiry()
        }
        lastReceivedAudio = Date()
        onAudio?(packet.audio)
    }

    private func armReceiveExpiry() {
        receiveExpiry?.cancel()
        receiveExpiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastReceivedAudio) > 2.5 { self.endRemoteSpeech(); return }
            }
        }
    }

    private func endRemoteSpeech() {
        if let remoteSpeaker { onRemoteTalk?(knownNames[remoteSpeaker] ?? "Участник", false) }
        remoteSpeaker = nil
        receiveExpiry?.cancel(); receiveExpiry = nil
    }

    private func refreshNearbyPeers() {
        peers = (nearbySession?.connectedPeers ?? []).map { RadioPeer(id: $0.displayName, name: knownNames[$0.displayName] ?? "Участник") }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        status = peers.isEmpty ? "Ищем друзей рядом…" : "В комнате · рядом"
    }
}

extension RadioLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self, self.nearbySession === session else { return }
            if state == .connected {
                self.sendControl(["type": "hello", "id": self.localID, "name": self.ownName], to: peerID)
            } else if state == .notConnected {
                self.invitations.remove(peerID.displayName)
                if self.remoteSpeaker == peerID.displayName { self.endRemoteSpeech() }
            }
            self.refreshNearbyPeers()
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self, self.nearbySession === session else { return }
            if data.first == 1 { self.receiveAudio(data, from: peerID) } else { self.receiveControl(data, from: peerID) }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) { certificateHandler(true) }
}

extension RadioLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor [weak self] in
            guard let self, self.browser === browser, info?["room"] == self.roomIdentifier,
                  UUID(uuidString: peerID.displayName) != nil, peerID.displayName != self.localID else { return }
            self.knownNames[peerID.displayName] = String((info?["name"] ?? "Участник").prefix(24))
            guard self.localID < peerID.displayName, !self.invitations.contains(peerID.displayName),
                  let session = self.nearbySession, !session.connectedPeers.contains(peerID) else { return }
            let nonce = UUID().uuidString
            let context: [String: String] = ["room": self.roomIdentifier, "nonce": nonce,
                "proof": self.proof(nonce + ":" + self.localID + ":" + peerID.displayName)]
            guard let data = try? JSONSerialization.data(withJSONObject: context) else { return }
            self.invitations.insert(peerID.displayName)
            browser.invitePeer(peerID, to: session, withContext: data, timeout: 12)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in self?.invitations.remove(peerID.displayName) }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in self?.error = "Разрешите локальную сеть для поиска друзей рядом." }
    }
}

extension RadioLink: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, self.advertiser === advertiser, let context, context.count <= 1024,
                  let message = try? JSONSerialization.jsonObject(with: context) as? [String: String],
                  message["room"] == self.roomIdentifier, let nonce = message["nonce"], nonce.count <= 64,
                  !self.invitationNonces.contains(nonce),
                  message["proof"] == self.proof(nonce + ":" + peerID.displayName + ":" + self.localID),
                  let session = self.nearbySession else { invitationHandler(false, nil); return }
            if self.invitationNonces.count > 512 { self.invitationNonces.removeAll(keepingCapacity: true) }
            self.invitationNonces.insert(nonce)
            invitationHandler(true, session)
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in self?.error = "Не удалось включить обнаружение. Проверьте доступ к локальной сети." }
    }
}
