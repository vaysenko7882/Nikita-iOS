import Foundation
import Combine
import AVFoundation
import PushToTalk
import CryptoKit
import UIKit

/// System audio ownership for the explicitly enabled walkie-talkie channel.
/// Streaming and APNs delivery are implemented by the app's transport layer.
@MainActor
final class SystemPTT: NSObject, ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var joined = false
    @Published private(set) var audioActive = false
    @Published private(set) var transmitting = false
    @Published private(set) var status = "Системная рация выключена"
    @Published private(set) var error: String?
    private(set) var manager: PTChannelManager?
    private(set) var channelUUID: UUID?

    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onActivated: (() -> Void)?
    var onDeactivated: (() -> Void)?
    var onIncomingSpeaker: ((String) -> Void)?
    var onPushToken: ((Data) -> Void)? {
        didSet {
            if joined, let token = ephemeralPushToken { onPushToken?(token) }
        }
    }

    private var configuring = false
    private var pendingJoin: (UUID, String)?
    private var ephemeralPushToken: Data?
    private var endRequested = false
    private static let channelKey = "Radio.SystemPTT.Channel"
    private static let titleKey = "Radio.SystemPTT.Title"

    /// Must be initialized early to receive restoration and incoming PTT pushes.
    /// An unsigned profile without the Push to Talk capability is handled as a
    /// normal foreground-only mode; this code never activates AVAudioSession.
    func configure() {
        guard manager == nil, !configuring else { return }
        configuring = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.configuring = false }
            do {
                let value = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self)
                self.manager = value
                self.available = true
                self.error = nil
                if let active = value.activeChannelUUID {
                    self.channelUUID = active
                    self.joined = true
                    self.status = "Системная рация подключена"
                } else {
                    self.status = "Системная рация готова"
                }
                self.performPendingJoin()
            } catch {
                self.available = false
                self.joined = false
                self.status = "Доступен режим внутри приложения"
                self.error = "Для системной рации нужна подпись с Push to Talk. \(error.localizedDescription)"
                self.pendingJoin = nil
            }
        }
    }

    /// Call in response to the person's explicit Enable/Connect action.
    func join(roomCode: String, title: String) {
        let code = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let identifier = Self.roomUUID(for: code)
        let safeTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        pendingJoin = (identifier, safeTitle.isEmpty ? "Рация" : safeTitle)
        error = nil
        endRequested = false
        if manager == nil { configure(); return }
        performPendingJoin()
    }

    private func performPendingJoin() {
        guard let manager, let next = pendingJoin else { return }
        if let active = manager.activeChannelUUID, active != next.0 {
            manager.leaveChannel(channelUUID: active)
            return
        }
        if manager.activeChannelUUID == next.0 {
            pendingJoin = nil
            channelUUID = next.0
            joined = true
            status = "Системная рация подключена"
            return
        }
        channelUUID = next.0
        UserDefaults.standard.set(next.0.uuidString, forKey: Self.channelKey)
        UserDefaults.standard.set(next.1, forKey: Self.titleKey)
        let descriptor = PTChannelDescriptor(name: next.1, image: UIImage(systemName: "waveform"))
        pendingJoin = nil
        status = "Подключение системной рации…"
        manager.requestJoinChannel(channelUUID: next.0, descriptor: descriptor)
    }

    func leave() {
        pendingJoin = nil
        endRequested = true
        if let manager, let channel = manager.activeChannelUUID ?? channelUUID {
            if transmitting { manager.stopTransmitting(channelUUID: channel) }
            manager.leaveChannel(channelUUID: channel)
        }
        if transmitting { onEnd?() }
        transmitting = false
        joined = false
        channelUUID = nil
        ephemeralPushToken = nil
        UserDefaults.standard.removeObject(forKey: Self.channelKey)
        UserDefaults.standard.removeObject(forKey: Self.titleKey)
        status = "Системная рация выключена"
    }

    func begin() {
        guard joined, let manager, let channelUUID else { return }
        endRequested = false
        manager.requestBeginTransmitting(channelUUID: channelUUID)
    }

    func end() {
        // This also handles a very short press: a late didBegin delegate event
        // is immediately stopped rather than leaving the microphone active.
        endRequested = true
        if let manager, let channelUUID { manager.stopTransmitting(channelUUID: channelUUID) }
        if transmitting { onEnd?() }
        transmitting = false
    }

    func setRemoteSpeaker(name: String?) {
        guard joined, let manager, let channelUUID else { return }
        let participant = name.map { PTParticipant(name: String($0.prefix(64)), image: nil) }
        if participant != nil, transmitting { end() }
        Task { [weak self] in
            do {
                try await manager.setActiveRemoteParticipant(participant, channelUUID: channelUUID)
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    nonisolated static func roomUUID(for code: String) -> UUID {
        // Stable room identity without storing or publishing the room code.
        var bytes = Array(SHA256.hash(data: Data(("radio-channel-v1:" + code).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension SystemPTT: PTChannelManagerDelegate, PTChannelRestorationDelegate {
    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   didJoinChannel channelUUID: UUID,
                                   reason: PTChannelJoinReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.channelUUID = channelUUID
            self.joined = true
            self.status = "Системная рация подключена"
            self.error = nil
            if let token = self.ephemeralPushToken { self.onPushToken?(token) }
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   didLeaveChannel channelUUID: UUID,
                                   reason: PTChannelLeaveReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.joined = false
            self.transmitting = false
            self.audioActive = false
            self.channelUUID = nil
            self.ephemeralPushToken = nil
            self.status = "Системная рация выключена"
            self.onEnd?()
            self.onDeactivated?()
            self.performPendingJoin()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   failedToJoinChannel channelUUID: UUID, error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.joined = false
            self?.channelUUID = nil
            self?.error = message
            self?.status = "Не удалось включить системную рацию"
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   failedToLeaveChannel channelUUID: UUID, error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.error = message }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   channelUUID: UUID,
                                   didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if (self.endRequested && source == .developerRequest) || !self.joined {
                channelManager.stopTransmitting(channelUUID: channelUUID)
                return
            }
            self.endRequested = false
            self.transmitting = true
            self.status = "Передача голоса"
            self.onBegin?()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   channelUUID: UUID,
                                   didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasTransmitting = self.transmitting
            self.transmitting = false
            self.status = "Системная рация подключена"
            if wasTransmitting { self.onEnd?() }
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   failedToBeginTransmittingInChannel channelUUID: UUID, error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.transmitting = false
            self?.error = message
            self?.onEnd?()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager,
                                   failedToStopTransmittingInChannel channelUUID: UUID, error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            if self?.transmitting == true { self?.error = message }
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.audioActive = true
            self?.onActivated?()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.audioActive = false
            self?.onDeactivated?()
        }
    }

    nonisolated func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // In-memory only. APNs tokens are never written to preferences/files.
            self.ephemeralPushToken = pushToken
            if self.joined { self.onPushToken?(pushToken) }
        }
    }

    nonisolated func incomingPushResult(channelManager: PTChannelManager,
                                       channelUUID: UUID,
                                       pushPayload: [String: Any]) -> PTPushResult {
        // Custom server fields: channelUUID and speakerName. The APNs headers
        // must use pushtotalk and <bundle-id>.voip-ptt, expiration 0, priority 10.
        if let value = pushPayload["channelUUID"] as? String,
           UUID(uuidString: value) != channelUUID { return .leaveChannel }
        guard let rawName = (pushPayload["speakerName"] ?? pushPayload["activeSpeaker"]) as? String,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .leaveChannel }
        let name = String(rawName.prefix(64))
        channelManager.stopTransmitting(channelUUID: channelUUID)
        Task { @MainActor [weak self] in
            self?.transmitting = false
            self?.onEnd?()
            self?.onIncomingSpeaker?(name)
        }
        return .activeRemoteParticipant(PTParticipant(name: name, image: nil))
    }

    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        let savedChannel = UserDefaults.standard.string(forKey: "Radio.SystemPTT.Channel")
        let savedTitle = savedChannel == channelUUID.uuidString
            ? UserDefaults.standard.string(forKey: "Radio.SystemPTT.Title") : nil
        return PTChannelDescriptor(name: savedTitle ?? "Рация", image: nil)
    }
}
