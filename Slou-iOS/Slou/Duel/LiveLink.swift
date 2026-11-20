import Foundation

/// Быстрый канал битвы: тот же /api/live, что у сайта. Сервер только узнаёт, кто есть кто,
/// и пересылает короткие сообщения второму месту комнаты.
final class LiveLink: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closedOnce = false

    func connect(_ url: URL) {
        closedOnce = false
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session = s
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let t = s.webSocketTask(with: request)
        t.maximumMessageSize = 64 * 1024
        task = t
        t.resume()
        listen()
    }

    func send(_ object: [String: Any]) {
        guard let task, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func close() {
        onOpen = nil
        onMessage = nil
        onClose = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func listen() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    var text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onMessage?(obj)
                    }
                    self.listen()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        guard !closedOnce else { return }
        closedOnce = true
        let done = onClose
        task = nil
        session?.invalidateAndCancel()
        session = nil
        done?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish() }
    }
}

/// Числа из JSON приходят как NSNumber — достаём их одинаково, целые они или дробные
func jsonNumber(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func jsonInt(_ v: Any?) -> Int? {
    guard let d = jsonNumber(v), d.isFinite else { return nil }
    return Int(d.rounded())
}
