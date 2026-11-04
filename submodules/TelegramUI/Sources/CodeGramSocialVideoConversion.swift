import AccountContext
import ChatControllerInteraction
import ChatInterfaceState
import ChatTextInputPanelNode
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Only prepares bytes. Its owner is the account queue, never a chat controller.
final class CodeGramSocialVideoConversion {
    private let client: CodeGramVPSClient
    private var task: URLSessionTask?
    private var pending: DispatchWorkItem?
    private var cancelled = false
    private var handedOff = false
    private let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-video-\(UUID().uuidString).mp4")
    private let started = Date()
    private var sourceURL: URL?
    private let progress: (String) -> Void
    private let completion: (Result<(CodeGramSocialVideoFileCache.Metadata, URL), CodeGramVPSError>) -> Void
    init(context: AccountContext, progress: @escaping (String) -> Void, completion: @escaping (Result<(CodeGramSocialVideoFileCache.Metadata, URL), CodeGramVPSError>) -> Void) {
        let account = String(context.account.peerId.id._internalGetInt64Value())
        self.client = CodeGramVPSClient(configuration: NikitaSettingsStore.shared.server(account: account), accountId: account)
        self.progress = progress; self.completion = completion
    }
    deinit { self.cancel() }
    func cancel() {
        self.cancelled = true; self.pending?.cancel(); self.task?.cancel(); self.client.close()
        if !self.handedOff { try? FileManager.default.removeItem(at: self.destination) }
    }
    func start(url: URL) {
        self.sourceURL = url
        self.task = self.client.json(path: "video", method: "POST", body: ["url": url.absoluteString], completion: { [weak self] in self?.received($0) })
    }
    private func finish(_ result: Result<(CodeGramSocialVideoFileCache.Metadata, URL), CodeGramVPSError>) {
        guard !self.cancelled else { return }
        self.pending?.cancel(); self.client.close()
        self.completion(result)
    }
    private func received(_ result: Result<[String: Any], CodeGramVPSError>) {
        guard !self.cancelled else { return }
        switch result {
        case let .failure(error): self.finish(.failure(error))
        case let .success(value):
            guard let id = value["job_id"] as? String, id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { self.finish(.failure(CodeGramVPSError("VPS вернул некорректное видео."))); return }
            switch value["state"] as? String ?? "" {
            case "ready":
                guard let sourceURL = self.sourceURL,
                    let size = (value["size"] as? NSNumber)?.int64Value,
                    let width = (value["width"] as? NSNumber)?.int32Value, let height = (value["height"] as? NSNumber)?.int32Value,
                    let duration = (value["duration"] as? NSNumber)?.doubleValue,
                    let epoch = value["server_id"] as? String else { self.finish(.failure(CodeGramVPSError("Видео имеет неподдерживаемые параметры."))); return }
                let metadata = CodeGramSocialVideoFileCache.Metadata(sourceURL: sourceURL.absoluteString, size: size, duration: duration, width: width, height: height)
                guard metadata.isValid else { self.finish(.failure(CodeGramVPSError("Видео имеет неподдерживаемые параметры."))); return }
                self.progress("Загружаю видео на iPhone…")
                self.task = self.client.download(path: "video/\(id)/file", epoch: epoch, size: size, destination: self.destination, completion: { [weak self] result in
                    guard let self else {
                        if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }; return
                    }
                    guard !self.cancelled else { try? FileManager.default.removeItem(at: self.destination); return }
                    switch result {
                    case let .failure(error): self.finish(.failure(error))
                    case let .success(url):
                        self.handedOff = true
                        self.finish(.success((metadata, url)))
                    }
                })
            case "queued", "downloading":
                guard Date().timeIntervalSince(self.started) < 600 else { self.finish(.failure(CodeGramVPSError("VPS не успел подготовить видео. Повтори отправку."))); return }
                self.progress(value["state"] as? String == "queued" ? "Видео в очереди VPS…" : "Получаю публичное видео через VPS…")
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.task = self.client.json(path: "video/\(id)", completion: { [weak self] in self?.received($0) })
                }
                self.pending = work
                // One request in flight; rapid completion is seen without a one-second floor.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            case "failed":
                self.finish(.failure(CodeGramVPSError.socialVideoFailure(code: value["error"] as? String, serviceVersion: value["service_version"] as? String, stage: value["error_stage"] as? String, workerExitCode: value["worker_exit_code"] as? Int, exceptionType: value["exception_type"] as? String)))
            default: self.finish(.failure(CodeGramVPSError("VPS вернул неизвестное состояние подготовки видео.")))
            }
        }
    }
}

private final class CodeGramSocialVideoSendEntry {
    var state: CodeGramSocialVideoSendState
    let peerId: EnginePeer.Id
    let threadId: Int64?
    let template: EnqueueMessage
    let correlationId: Int64
    var detail = "Подготовка видео…"
    var diagnostic = ""
    var temporary: URL?
    let disposable = MetaDisposable()
    init(session: String, peerId: EnginePeer.Id, threadId: Int64?, sourceURL: URL, template: EnqueueMessage, correlationId: Int64) {
        self.state = CodeGramSocialVideoSendState(accountSession: session, destination: "\(peerId.toInt64()):\(threadId.map(String.init) ?? "-")", sourceURL: sourceURL)
        self.peerId = peerId; self.threadId = threadId; self.template = template; self.correlationId = correlationId
    }
    deinit { self.disposable.dispose(); if let temporary = self.temporary { try? FileManager.default.removeItem(at: temporary) } }
}

private final class CodeGramSocialVideoPreparation {
    let id = UUID()
    var operation: CodeGramSocialVideoConversion?
    var participants: [UUID: Int] = [:]
    var source: URL?
    var metadata: CodeGramSocialVideoFileCache.Metadata?
    var copying = CodeGramSocialVideoCopyClaims()
    deinit { self.operation?.cancel(); if let source = self.source { try? FileManager.default.removeItem(at: source) } }
}

/// Main-thread, account-session owned. Navigating away only detaches the view.
private final class CodeGramSocialVideoAccountQueue {
    private static var queues: [ObjectIdentifier: CodeGramSocialVideoAccountQueue] = [:]
    static func get(_ context: AccountContext) -> CodeGramSocialVideoAccountQueue {
        let key = ObjectIdentifier(context.account)
        if let queue = self.queues[key] { return queue }
        let queue = CodeGramSocialVideoAccountQueue(context: context)
        self.queues[key] = queue
        queue.observeAccountLifetime()
        return queue
    }
    let context: AccountContext
    private let session = UUID().uuidString
    private let fileCache: CodeGramSocialVideoFileCache
    private var entries: [CodeGramSocialVideoSendEntry] = []
    private var preparations: [String: CodeGramSocialVideoPreparation] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private let accountDisposable = MetaDisposable()
    private var closed = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private struct CloudFile { let reference: AnyMediaReference; let stored: Date }
    private var cloudFiles: [String: CloudFile] = [:]
    private var cloudLearning: [UUID: (DispatchWorkItem?, MetaDisposable)] = [:]
    private init(context: AccountContext) {
        self.context = context
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeGramVideo", isDirectory: true)
            .appendingPathComponent(String(context.account.id.int64), isDirectory: true)
        self.fileCache = CodeGramSocialVideoFileCache(directory: directory)
    }
    private func observeAccountLifetime() {
        self.accountDisposable.set((self.context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            if !value.accounts.contains(where: { $0.1.account === self.context.account }) { self.close() }
        }))
    }
    private func close() {
        guard !self.closed else { return }
        self.closed = true
        self.accountDisposable.dispose()
        self.preparations.removeAll()
        for entry in self.entries { entry.state.cancel(); entry.disposable.dispose() }
        self.entries.removeAll(); self.cloudFiles.removeAll()
        for (_, value) in self.cloudLearning { value.0?.cancel(); value.1.dispose() }
        self.cloudLearning.removeAll(); self.fileCache.invalidate()
        self.notify()
        self.observers.removeAll()
        if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
        Self.queues.removeValue(forKey: ObjectIdentifier(self.context.account))
    }
    func observe(_ action: @escaping () -> Void) -> UUID { let id = UUID(); self.observers[id] = action; return id }
    func detach(_ id: UUID) { self.observers.removeValue(forKey: id) }
    private func notify() {
        let actions = Array(self.observers.values)
        for action in actions { action() }
        self.updateBackgroundTask()
    }
    private func updateBackgroundTask() {
        let active = self.entries.contains { $0.state.phase == .preparing || $0.state.phase == .enqueueing }
        if active && self.backgroundTask == .invalid {
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CodeGram video send", expirationHandler: { [weak self] in
                guard let self else { return }
                self.preparations.removeAll()
                for entry in self.entries where entry.state.phase == .preparing {
                    self.fail(entry, attempt: entry.state.attempt, message: "iOS приостановила подготовку. Нажми «Повторить» — ссылка сохранена в этой записи.")
                }
                if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
            })
        } else if !active && self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid
        }
    }
    var canAccept: Bool { !self.closed && self.entries.filter { $0.state.phase == .preparing || $0.state.phase == .enqueueing }.count < 8 }
    func submit(peerId: EnginePeer.Id, threadId: Int64?, url: URL, template: EnqueueMessage, correlationId: Int64) {
        guard self.canAccept else { return }
        // Keep failed/cancelled intents, but bound session memory.
        while self.entries.count >= 20, let index = self.entries.firstIndex(where: { $0.state.phase == .failed || $0.state.phase == .cancelled }) {
            self.entries.remove(at: index)
        }
        let entry = CodeGramSocialVideoSendEntry(session: self.session, peerId: peerId, threadId: threadId, sourceURL: url, template: template, correlationId: correlationId)
        self.entries.append(entry); self.notify()
        self.prepare(entry)
    }
    func visible(peerId: EnginePeer.Id, threadId: Int64?) -> [CodeGramSocialVideoSendEntry] {
        let matching = self.entries.filter { $0.peerId == peerId && $0.threadId == threadId && $0.state.phase != .enqueued }
        let active = matching.filter { $0.state.phase == .preparing || $0.state.phase == .enqueueing }
        return active + matching.filter { $0.state.phase == .failed || $0.state.phase == .cancelled }
    }
    func cancel(_ entry: CodeGramSocialVideoSendEntry) {
        guard entry.state.cancel() else { return }
        self.removeParticipant(entry)
        if let temporary = entry.temporary { try? FileManager.default.removeItem(at: temporary); entry.temporary = nil }
        entry.detail = "Отправка отменена. Исходная ссылка сохранена."
        self.notify()
    }
    func dismiss(_ entry: CodeGramSocialVideoSendEntry) {
        guard entry.state.phase == .failed || entry.state.phase == .cancelled else { return }
        self.entries.removeAll(where: { $0 === entry }); self.notify()
    }
    func retry(_ entry: CodeGramSocialVideoSendEntry) {
        guard self.canAccept, entry.state.retry() != nil else { return }
        entry.detail = "Повторная подготовка…"; entry.diagnostic = ""
        self.notify(); self.prepare(entry)
    }
    private func valid(_ entry: CodeGramSocialVideoSendEntry, _ attempt: Int) -> Bool {
        return !self.closed && entry.state.phase == .preparing && entry.state.attempt == attempt && self.entries.contains(where: { $0 === entry })
    }
    private func removeParticipant(_ entry: CodeGramSocialVideoSendEntry) {
        let key = entry.state.sourceURL.absoluteString
        if let group = self.preparations[key] {
            group.participants.removeValue(forKey: entry.state.id)
            if group.participants.isEmpty { self.preparations.removeValue(forKey: key) }
        }
    }
    private func fail(_ entry: CodeGramSocialVideoSendEntry, attempt: Int, message: String) {
        guard entry.state.fail(attempt: attempt) else { return }
        self.removeParticipant(entry)
        if let temporary = entry.temporary { try? FileManager.default.removeItem(at: temporary); entry.temporary = nil }
        entry.detail = message; entry.diagnostic = message + "\nURL: " + entry.state.sourceURL.absoluteString
        self.notify()
    }
    private func prepare(_ entry: CodeGramSocialVideoSendEntry) {
        let attempt = entry.state.attempt
        let key = entry.state.sourceURL.absoluteString
        if entry.peerId.namespace != Namespaces.Peer.SecretChat, let cached = self.cloudFiles[key], Date().timeIntervalSince(cached.stored) < 3600 {
            entry.detail = "Отправляю сохранённое видео…"; self.notify()
            self.handoff(entry, attempt: attempt, reference: cached.reference, temporary: nil)
            return
        }
        self.fileCache.copyForSend(sourceURL: entry.state.sourceURL, completion: { [weak self, weak entry] result in
            guard let self, let entry, self.valid(entry, attempt) else {
                if let result { try? FileManager.default.removeItem(at: result.1) }; return
            }
            if let (metadata, url) = result {
                self.handoffFile(entry, attempt: attempt, metadata: metadata, url: url)
            } else {
                self.joinPreparation(entry, attempt: attempt)
            }
        })
    }
    private func joinPreparation(_ entry: CodeGramSocialVideoSendEntry, attempt: Int) {
        guard self.valid(entry, attempt) else { return }
        let key = entry.state.sourceURL.absoluteString
        if let group = self.preparations[key] {
            group.participants[entry.state.id] = attempt
            if let metadata = group.metadata, let url = group.source { self.clonePrepared(entry, attempt: attempt, group: group, metadata: metadata, url: url) }
            return
        }
        let group = CodeGramSocialVideoPreparation()
        group.participants[entry.state.id] = attempt
        self.preparations[key] = group
        group.operation = CodeGramSocialVideoConversion(context: self.context, progress: { [weak self, weak group] message in
            guard let self, let group, self.preparations[key] === group else { return }
            for entry in self.entries where group.participants[entry.state.id] == entry.state.attempt && entry.state.phase == .preparing { entry.detail = message }
            self.notify()
        }, completion: { [weak self, weak group] result in
            guard let self, let group, self.preparations[key] === group, !self.closed else {
                if case let .success((_, url)) = result { try? FileManager.default.removeItem(at: url) }; return
            }
            switch result {
            case let .failure(error):
                let participants = group.participants
                self.preparations.removeValue(forKey: key)
                for entry in self.entries {
                    if let attempt = participants[entry.state.id] { self.fail(entry, attempt: attempt, message: error.message) }
                }
            case let .success((metadata, url)):
                group.source = url
                self.fileCache.store(source: url, metadata: metadata, completion: { [weak self, weak group] _ in
                    guard let self, let group, self.preparations[key] === group, !self.closed else { return }
                    group.metadata = metadata
                    for entry in self.entries {
                        guard let attempt = group.participants[entry.state.id], self.valid(entry, attempt) else { continue }
                        self.clonePrepared(entry, attempt: attempt, group: group, metadata: metadata, url: url)
                    }
                })
            }
        })
        group.operation?.start(url: entry.state.sourceURL)
    }
    private func clonePrepared(_ entry: CodeGramSocialVideoSendEntry, attempt: Int, group: CodeGramSocialVideoPreparation, metadata: CodeGramSocialVideoFileCache.Metadata, url: URL) {
        guard group.copying.claim(id: entry.state.id, attempt: attempt) else { return }
        let key = entry.state.sourceURL.absoluteString
        // Keep the master alive until all copies complete, even if another intent is cancelled.
        DispatchQueue.global(qos: .utility).async { [group] in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-send-\(UUID().uuidString).mp4")
            var success = false
            do { try FileManager.default.linkItem(at: url, to: copy); success = true } catch {
                do { try FileManager.default.copyItem(at: url, to: copy); success = true } catch {}
            }
            let copied = success
            DispatchQueue.main.async { [weak self, weak entry, group] in
                if let entry { group.copying.release(id: entry.state.id, attempt: attempt) }
                guard let self, let entry, self.valid(entry, attempt), self.preparations[key] === group else { try? FileManager.default.removeItem(at: copy); return }
                if copied { self.handoffFile(entry, attempt: attempt, metadata: metadata, url: copy) }
                else { self.fail(entry, attempt: attempt, message: "Не удалось сохранить видео на iPhone. Освободи место и повтори.") }
            }
        }
    }
    private func handoffFile(_ entry: CodeGramSocialVideoSendEntry, attempt: Int, metadata: CodeGramSocialVideoFileCache.Metadata, url: URL) {
        guard self.valid(entry, attempt) else { try? FileManager.default.removeItem(at: url); return }
        let file = codegramSocialVideoMedia(path: url.path, size: metadata.size, duration: metadata.duration, width: metadata.width, height: metadata.height)
        self.handoff(entry, attempt: attempt, reference: .standalone(media: file), temporary: url)
    }
    private func handoff(_ entry: CodeGramSocialVideoSendEntry, attempt: Int, reference: AnyMediaReference, temporary: URL?) {
        guard self.valid(entry, attempt) else { if let temporary { try? FileManager.default.removeItem(at: temporary) }; return }
        entry.temporary = temporary
        // Re-read the captured destination's permissions. Never consult the visible chat.
        entry.disposable.set((self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: entry.peerId)) |> deliverOnMainQueue).start(next: { [weak self, weak entry] peer in
            guard let self, let entry, self.valid(entry, attempt) else { if let temporary { try? FileManager.default.removeItem(at: temporary) }; return }
            guard let peer, canSendMessagesToPeer(peer) else {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                self.fail(entry, attempt: attempt, message: "В этом чате больше нельзя отправлять сообщения."); return
            }
            if let channel = peer._asPeer() as? TelegramChannel, channel.hasBannedPermission(.banSendVideos) != nil {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                self.fail(entry, attempt: attempt, message: "В этом чате запрещена отправка видео."); return
            }
            if let group = peer._asPeer() as? TelegramGroup, group.membership != .Member {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                self.fail(entry, attempt: attempt, message: "Ты больше не участник этой группы."); return
            }
            if let group = peer._asPeer() as? TelegramGroup, group.hasBannedPermission(.banSendVideos) {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                self.fail(entry, attempt: attempt, message: "В этом чате запрещена отправка видео."); return
            }
            guard case .message = entry.template, entry.state.claimHandoff(attempt: attempt, accountSession: self.session) else { if let temporary { try? FileManager.default.removeItem(at: temporary) }; return }
            self.removeParticipant(entry)
            entry.detail = "Передаю в очередь Telegram…"; self.notify()
            guard case let .message(text, attributes, inlineStickers, _, threadId, replyTo, replyToStory, grouping, correlation, bubbles) = entry.template else { return }
            let message = EnqueueMessage.message(text: text, attributes: attributes, inlineStickers: inlineStickers, mediaReference: reference, threadId: threadId, replyToMessageId: replyTo, replyToStoryId: replyToStory, localGroupingKey: grouping, correlationId: correlation, bubbleUpEmojiOrStickersets: bubbles)
            entry.disposable.set((enqueueMessages(account: self.context.account, peerId: entry.peerId, messages: [message]) |> deliverOnMainQueue).start(next: { [weak self, weak entry] ids in
                guard let self, let entry, !self.closed else { return }
                let accepted = ids.contains(where: { $0 != nil })
                guard entry.state.finishHandoff(attempt: attempt, accepted: accepted) else { return }
                if accepted {
                    entry.temporary = nil // Ownership transferred to the native media pipeline.
                    // From here normal Telegram pending-message progress/retry owns the upload.
                    if entry.peerId.namespace != Namespaces.Peer.SecretChat { self.learnCloudFile(entry, deadline: Date().addingTimeInterval(600)) }
                    self.entries.removeAll(where: { $0 === entry })
                } else {
                    if let temporary { try? FileManager.default.removeItem(at: temporary) }
                    entry.detail = "Telegram не принял видео. Нажми «Повторить»."; entry.diagnostic = entry.detail
                }
                self.notify()
            }))
        }))
    }
    private func learnCloudFile(_ entry: CodeGramSocialVideoSendEntry, deadline: Date) {
        guard !self.closed, Date() < deadline else { self.cloudLearning.removeValue(forKey: entry.state.id); return }
        if self.cloudLearning[entry.state.id] == nil && self.cloudLearning.count >= 20 {
            return // File cache remains available; bound observers for uploads waiting on the network.
        }
        let disposable = self.cloudLearning[entry.state.id]?.1 ?? MetaDisposable()
        if let id = self.context.engine.messages.synchronouslyLookupCorrelationId(correlationId: entry.correlationId) {
            self.cloudLearning[entry.state.id] = (nil, disposable)
            disposable.set((self.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: id)) |> deliverOnMainQueue).start(next: { [weak self] message in
                guard let self, !self.closed else { return }
                if let message, let file = message.media.compactMap({ $0 as? TelegramMediaFile }).first, file.resource is CloudDocumentMediaResource {
                    self.cloudFiles[entry.state.sourceURL.absoluteString] = CloudFile(reference: .message(message: MessageReference(message._asMessage()), media: file), stored: Date())
                    if self.cloudFiles.count > 20, let oldest = self.cloudFiles.min(by: { $0.value.stored < $1.value.stored })?.key { self.cloudFiles.removeValue(forKey: oldest) }
                    self.cloudLearning.removeValue(forKey: entry.state.id)
                } else { self.scheduleCloudLearning(entry, deadline: deadline, disposable: disposable) }
            }))
        } else { self.scheduleCloudLearning(entry, deadline: deadline, disposable: disposable) }
    }
    private func scheduleCloudLearning(_ entry: CodeGramSocialVideoSendEntry, deadline: Date, disposable: MetaDisposable) {
        let work = DispatchWorkItem { [weak self] in self?.learnCloudFile(entry, deadline: deadline) }
        self.cloudLearning[entry.state.id] = (work, disposable)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

final class CodeGramSocialVideoChatStatus {
    private let queue: CodeGramSocialVideoAccountQueue
    private weak var node: ChatControllerNode?
    private let view = CodeGramSocialVideoStatusView(frame: .zero)
    private var observer: UUID?
    private var width: CGFloat = 0
    private var top: CGFloat = 0
    private var maximumHeight: CGFloat = 0
    init(node: ChatControllerNode) {
        self.node = node; self.queue = CodeGramSocialVideoAccountQueue.get(node.context)
        node.view.addSubview(self.view)
        self.observer = self.queue.observe { [weak self] in self?.refresh() }
        self.view.layoutChanged = { [weak self] in self?.refresh() }
        self.refresh()
    }
    deinit { if let observer { self.queue.detach(observer) }; self.view.removeFromSuperview() }
    func layout(width: CGFloat, top: CGFloat, maximumHeight: CGFloat) {
        self.width = width; self.top = top; self.maximumHeight = max(0, maximumHeight); self.refresh()
    }
    func showQueueFullNotice() { self.view.showQueueFullNotice() }
    private func refresh() {
        guard let node = self.node, let peerId = node.chatLocation.peerId else { self.view.isHidden = true; return }
        let entries = self.queue.visible(peerId: peerId, threadId: node.chatLocation.threadId)
        guard let entry = entries.first, self.maximumHeight > 0, self.width > 68 else { self.view.isHidden = true; return }
        self.view.isHidden = false
        let mode: CodeGramSocialVideoStatusView.Mode
        switch entry.state.phase {
        case .preparing: mode = .preparing
        case .enqueueing, .enqueued: mode = .enqueueing
        case .failed: mode = .failed
        case .cancelled: mode = .cancelled
        }
        let theme = node.chatPresentationInterfaceState.theme
        self.view.update(.init(mode: mode, title: mode == .failed ? "Видео не отправлено" : "Видео вместо ссылки", detail: entry.detail, count: entries.count), background: theme.list.itemBlocksBackgroundColor, foreground: theme.list.itemPrimaryTextColor, secondary: theme.list.itemSecondaryTextColor, accent: theme.list.itemAccentColor)
        self.view.primaryAction = { [weak self, weak entry] in
            guard let self, let entry else { return }
            if entry.state.phase == .failed || entry.state.phase == .cancelled { self.queue.retry(entry) } else { self.queue.cancel(entry) }
        }
        self.view.copyAction = { [weak entry] in guard let entry else { return }; UIPasteboard.general.string = entry.state.phase == .cancelled ? entry.state.sourceURL.absoluteString : entry.diagnostic }
        self.view.copyLinkAction = { [weak entry] in UIPasteboard.general.string = entry?.state.sourceURL.absoluteString }
        self.view.dismissAction = { [weak self, weak entry] in if let self, let entry { self.queue.dismiss(entry) } }
        let availableWidth = max(0, self.width - 24)
        self.view.frame = CGRect(x: 12, y: self.top + 8, width: availableWidth, height: min(self.maximumHeight, self.view.preferredHeight(width: availableWidth)))
        node.view.bringSubviewToFront(self.view)
    }
}

extension ChatControllerNode {
    func codegramQueueLinkIfNeeded(text: String, controller: ChatControllerImpl?, silentPosting: Bool?, scheduleTime: Int32?, repeatPeriod: Int32?, postpone: Bool, messageEffect: ChatSendMessageEffect?, paidAuthorized: Bool, completion: @escaping () -> Void) -> Bool {
        guard NikitaSettingsStore.shared.sendsSocialLinksAsVideo,
            let url = CodeGramSocialVideoLink.url(in: text), let controller,
            let peerId = self.chatLocation.peerId,
            self.chatPresentationInterfaceState.interfaceState.postSuggestionState == nil else { return false }
        if case .customChatContents = self.chatLocation { return false }
        if case .customChatContents = self.chatPresentationInterfaceState.subject { return false }
        if case .scheduledMessages = self.chatPresentationInterfaceState.subject, scheduleTime == nil {
            let reply = self.chatPresentationInterfaceState.interfaceState.replyMessageSubject
            let threadId = self.chatLocation.threadId
            controller.presentScheduleTimePicker(style: .media, dismissByTapOutside: false, completion: { [weak self, weak controller] result in
                guard let self, let controller,
                    self.chatLocation.peerId == peerId, self.chatLocation.threadId == threadId,
                    self.chatPresentationInterfaceState.interfaceState.replyMessageSubject == reply,
                    (self.inputPanelNode as? ChatTextInputPanelNode)?.inputTextState.inputText.string == text else { return }
                _ = self.codegramQueueLinkIfNeeded(text: text, controller: controller, silentPosting: result.silentPosting, scheduleTime: result.time, repeatPeriod: result.repeatPeriod, postpone: postpone, messageEffect: messageEffect, paidAuthorized: paidAuthorized, completion: completion)
            })
            return true
        }
        if self.chatPresentationInterfaceState.sendPaidMessageStars != nil && !paidAuthorized {
            let reply = self.chatPresentationInterfaceState.interfaceState.replyMessageSubject
            let threadId = self.chatLocation.threadId
            controller.presentPaidMessageAlertIfNeeded(count: 1, completion: { [weak self, weak controller] authorizedPostpone in
                guard let self, let controller,
                    self.chatLocation.peerId == peerId, self.chatLocation.threadId == threadId,
                    self.chatPresentationInterfaceState.interfaceState.replyMessageSubject == reply,
                    (self.inputPanelNode as? ChatTextInputPanelNode)?.inputTextState.inputText.string == text else { return }
                _ = self.codegramQueueLinkIfNeeded(text: text, controller: controller, silentPosting: silentPosting, scheduleTime: scheduleTime, repeatPeriod: repeatPeriod, postpone: authorizedPostpone, messageEffect: messageEffect, paidAuthorized: true, completion: completion)
            })
            return true
        }
        let queue = CodeGramSocialVideoAccountQueue.get(self.context)
        guard queue.canAccept else { self.codegramVideoStatus?.showQueueFullNotice(); return true }
        let correlationId = Int64.random(in: Int64.min ... Int64.max)
        let template = EnqueueMessage.message(text: "", attributes: messageEffect.map { [EffectMessageAttribute(id: $0.id)] } ?? [], inlineStickers: [:], mediaReference: nil, threadId: self.chatLocation.threadId, replyToMessageId: self.chatPresentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: [])
        // This existing transform freezes paid stars, send-as, reply/thread, silence and schedule.
        guard let transformed = controller.transformEnqueueMessages([template], silentPosting: silentPosting ?? self.chatPresentationInterfaceState.interfaceState.silentPosting, scheduleTime: scheduleTime, repeatPeriod: repeatPeriod, postpone: postpone).first,
            case .message = transformed else { return true }
        guard self.codegramConsumeLinkDraft(text: text) else { return true }
        queue.submit(peerId: peerId, threadId: self.chatLocation.threadId, url: url, template: transformed, correlationId: correlationId)
        // Invoke only now. A future completion must never clear a newer draft.
        completion()
        return true
    }
}
