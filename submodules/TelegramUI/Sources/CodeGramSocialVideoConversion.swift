import AccountContext
import ChatTextInputPanelNode
import Foundation
import TelegramCore
import UIKit

final class CodeGramSocialVideoConversion {
    private let client: CodeGramVPSClient
    private var task: URLSessionTask?
    private var pending: DispatchWorkItem?
    private var cancelled = false
    private var handedOff = false
    private let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-video-\(UUID().uuidString).mp4")
    private let started = Date()
    private let progress: (String) -> Void
    private let completion: (Result<(TelegramMediaFile, URL),CodeGramVPSError>) -> Void
    init(context: AccountContext, progress: @escaping (String) -> Void, completion: @escaping (Result<(TelegramMediaFile, URL),CodeGramVPSError>) -> Void) {
        let account = String(context.account.peerId.id._internalGetInt64Value())
        self.client = CodeGramVPSClient(configuration: NikitaSettingsStore.shared.server(account: account),accountId: account)
        self.progress = progress; self.completion = completion
    }
    deinit { self.cancel() }
    func cancel() {
        self.cancelled = true; self.pending?.cancel(); self.task?.cancel(); self.client.close()
        if !self.handedOff { try? FileManager.default.removeItem(at: self.destination) }
    }
    func start(url: URL) {
        self.task = self.client.json(path: "video",method: "POST",body: ["url":url.absoluteString],completion: { [weak self] in self?.received($0) })
    }
    private func received(_ result: Result<[String: Any],CodeGramVPSError>) {
        guard !self.cancelled else { return }
        switch result {
        case let .failure(error): self.completion(.failure(error))
        case let .success(value):
            guard let id = value["job_id"] as? String, id.range(of: "^[a-f0-9]{32}$",options: .regularExpression) != nil else { self.completion(.failure(CodeGramVPSError("VPS вернул некорректное видео."))); return }
            switch value["state"] as? String ?? "" {
            case "ready":
                guard let size = (value["size"] as? NSNumber)?.int64Value, size>0, size<=250*1024*1024,
                    let width = value["width"] as? Int32, let height = value["height"] as? Int32,
                    width>0, height>0, width<=16384, height<=16384,
                    let duration = value["duration"] as? Double, duration.isFinite, duration>0, duration<=3600,
                    let epoch = value["server_id"] as? String else { self.completion(.failure(CodeGramVPSError("Видео имеет неподдерживаемые параметры."))); return }
                self.progress("Загружаю видео на iPhone…")
                self.task = self.client.download(path: "video/\(id)/file",epoch: epoch,size: size,destination: self.destination,completion: { [weak self] result in
                    guard let self else {
                        if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
                        return
                    }
                    guard !self.cancelled else { try? FileManager.default.removeItem(at: self.destination); return }
                    switch result {
                    case let .failure(error): self.completion(.failure(error))
                    case let .success(url):
                        let file = codegramSocialVideoMedia(path: url.path,size: size,duration: duration,width: width,height: height)
                        self.handedOff = true
                        self.completion(.success((file,url)))
                    }
                })
            case "queued", "downloading":
                // One bounded server worker can have two earlier jobs. Allow
                // their deadlines plus this job instead of timing out in queue.
                guard Date().timeIntervalSince(self.started)<600 else { self.completion(.failure(CodeGramVPSError("VPS не успел подготовить видео. Проверь очередь и журнал службы."))); return }
                self.progress(value["state"] as? String == "queued" ? "Видео в очереди VPS…" : "Получаю публичное видео через VPS…")
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.task = self.client.json(path: "video/\(id)",completion: { [weak self] in self?.received($0) })
                }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now()+1,execute: work)
            case "failed": self.completion(.failure(CodeGramVPSError.socialVideoFailure(code: value["error"] as? String)))
            default: self.completion(.failure(CodeGramVPSError("VPS вернул неизвестное состояние подготовки видео.")))
            }
        }
    }
}

extension ChatControllerNode {
    func codegramConvertLinkIfNeeded(text: String, controller: ChatControllerImpl?, resume: @escaping (TelegramMediaFile) -> Void) -> Bool {
        guard NikitaSettingsStore.shared.sendsSocialLinksAsVideo, let url = CodeGramSocialVideoLink.url(in: text), let controller else { return false }
        if self.codegramVideoConversion != nil { return true }
        let reply = self.chatPresentationInterfaceState.interfaceState.replyMessageSubject
        let alert = UIAlertController(title: "Видео вместо ссылки",message: "Получаю видео…",preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отменить",style: .cancel,handler: { [weak self] _ in
            self?.codegramVideoConversion?.cancel(); self?.codegramVideoConversion = nil
        }))
        let operation = CodeGramSocialVideoConversion(context: self.context,progress: { [weak alert] in alert?.message = $0 },completion: { [weak self,weak alert,weak controller] result in
            guard let self else {
                if case let .success((_,url)) = result { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.codegramVideoConversion = nil
            let finish = { [weak self,weak controller] in
                guard let self, let controller else {
                    if case let .success((_,url)) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                let current = (self.inputPanelNode as? ChatTextInputPanelNode)?.inputTextState.inputText.string
                guard current == text, self.chatPresentationInterfaceState.interfaceState.replyMessageSubject == reply else {
                    if case let .success((_,url)) = result { try? FileManager.default.removeItem(at: url) }
                    return  // A changed draft/reply never sends an earlier conversion.
                }
                switch result {
                case let .success((file,_)): resume(file)
                case let .failure(error):
                    let failure = UIAlertController(title: "Видео не отправлено",message: error.message + "\n\nСсылка сохранена в черновике.",preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "Оставить черновик",style: .cancel))
                    controller.present(failure,animated: true)
                }
            }
            if let alert, alert.presentingViewController != nil { alert.dismiss(animated: true,completion: finish) } else { finish() }
        })
        self.codegramVideoConversion = operation
        controller.present(alert,animated: true,completion: { operation.start(url: url) })
        return true
    }
}

