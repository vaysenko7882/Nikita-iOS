import SwiftUI
import UIKit
import WebKit
import AVFoundation

/// Весь «слоу» — это страница с твоего сервера: главная с живым логотипом, комнаты, чат, голос, игры.
/// Поэтому в приложении и в браузере один и тот же код, а друг без приложения играет с тобой на равных.
/// Приложение добавляет то, чего нет в Safari: Taptic Engine в играх, микрофон без лишних вопросов,
/// звук в динамик, экран не гаснет, «Сохранить» кладёт фото прямо в Фото, системное «Поделиться».
struct WebView: UIViewRepresentable {
    let controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Обработчик сообщений без удержания контроллера, иначе WebKit не отпустит его никогда
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class WebController: NSObject, ObservableObject {
    @Published var ready = false
    @Published var failure: String?

    let webView: WKWebView
    private weak var model: AppModel?
    private var server: URL?
    private var loadedOnce = false
    private var observers: [NSObjectProtocol] = []

    /// Выполняется до любого кода страницы: страница узнаёт, что она в приложении
    private static let boot = """
    (function () {
      try {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.slou;
        if (!h) return;
        window.slouApp = { platform: 'ios', version: '2.0' };
        document.documentElement.classList.add('is-app');
        if (!navigator.share) {
          navigator.share = function (d) {
            d = d || {};
            h.postMessage({ t: 'share', url: d.url || '', text: d.text || d.title || '' });
            return Promise.resolve();
          };
          navigator.canShare = function () { return true; };
        }
      } catch (e) {}
    })();
    """

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        // Представляемся мобильным Safari: VK Видео и Кинопаб отдают обычный плеер, а не заглушку
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1 SlouApp/2"
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: WebController.boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = scripts

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = Theme.paperUI
        view.underPageBackgroundColor = Theme.paperUI
        view.scrollView.backgroundColor = Theme.paperUI
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.scrollView.alwaysBounceVertical = false
        view.scrollView.keyboardDismissMode = .interactive
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        #if DEBUG
        view.isInspectable = true // Safari → Разработка → айфон: консоль страницы
        #endif
        webView = view
        super.init()
        scripts.add(WeakScriptHandler(self), name: "slou")
        view.navigationDelegate = self
        view.uiDelegate = self
        observeAudio()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(_ model: AppModel) { self.model = model }

    func open(server: URL) {
        self.server = server
        failure = nil
        webView.load(URLRequest(url: server))
    }

    func open(path: String) {
        guard let server, let url = URL(string: path, relativeTo: server)?.absoluteURL else { return }
        failure = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        failure = nil
        if webView.url == nil || !loadedOnce, let server { webView.load(URLRequest(url: server)) }
        else { webView.reload() }
    }

    /// Вернулись из фона, после звонка или смены наушников — оживить звук, видео и связь
    func resume() {
        webView.evaluateJavaScript("window.slouResume && window.slouResume(); 0", completionHandler: nil)
    }

    /// Короткое сообщение внизу страницы — тем же способом, что и у сайта
    func notice(_ text: String) {
        let safe = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.roomWire && window.roomWire.notice && window.roomWire.notice('\(safe)'); 0", completionHandler: nil)
    }

    private func observeAudio() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            AudioSessionManager.shared.configure(voice: AudioSessionManager.shared.voiceOn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.resume() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.resume() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            AudioSessionManager.shared.configure(voice: AudioSessionManager.shared.voiceOn)
            self?.resume()
        })
    }

    private func isOurs(_ url: URL) -> Bool {
        guard let host = server?.host?.lowercased(), let other = url.host?.lowercased() else { return false }
        return host == other
    }
}

// MARK: - Сообщения от страницы

extension WebController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        switch type {
        case "haptic":
            Haptics.shared.play(body["s"] as? String ?? "light")

        case "room":
            model?.inRoom = true

        case "home":
            model?.inRoom = false
            model?.duel = false

        case "voice":
            let on = body["on"] as? Bool ?? false
            AudioSessionManager.shared.configure(voice: on)
            if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resume() } }

        case "duel":
            model?.duel = body["on"] as? Bool ?? false

        case "immersive":
            model?.immersive = body["on"] as? Bool ?? false

        case "share":
            var items: [Any] = []
            if let text = body["text"] as? String, !text.isEmpty { items.append(text) }
            if let link = body["url"] as? String, let url = URL(string: link) { items.append(url) }
            if !items.isEmpty { UIApplication.share(items: items) }

        case "save":
            guard let link = body["url"] as? String, let url = URL(string: link) else { return }
            Haptics.shared.play("soft")
            PhotoSaver.save(url) { [weak self] ok in
                Haptics.shared.play(ok ? "success" : "error")
                self?.notice(ok ? "Сохранено в Фото" : "Не получилось сохранить. Разреши доступ к Фото в настройках.")
            }

        case "settings":
            model?.showSettings = true

        default:
            break
        }
    }
}

// MARK: - Навигация

extension WebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if ["about", "blob", "data", "javascript"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if scheme == "slou" {
            model?.handle(url: url)
            decisionHandler(.cancel)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            // ссылки на приложения (vk://, tg://, tel:) — только если человек сам нажал
            if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        if mainFrame && !isOurs(url) {
            UIApplication.openInSafari(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedOnce = true
        failure = nil
        // даём странице секунду нарисовать логотип, потом убираем заставку
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.ready = true }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS выгрузил страницу из памяти — тихо открываем её заново
        reload()
    }

    private func fail(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        guard !loadedOnce else { return }
        switch e.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            failure = "Нет интернета. Проверь связь и попробуй ещё раз."
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            failure = "Сервер не отвечает. Проверь адрес сервера."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            failure = "Не получилось проверить сертификат сервера. Подожди минуту и попробуй снова."
        default:
            failure = e.localizedDescription
        }
    }
}

// MARK: - Окна, микрофон, диалоги

extension WebController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { UIApplication.openInSafari(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // микрофон — только своей странице и без повторного вопроса при каждом входе
        let ours = origin.host.lowercased() == (server?.host ?? "").lowercased()
        decisionHandler(ours && type == .microphone ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let top = UIApplication.topController else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let top = UIApplication.topController else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        top.present(alert, animated: true)
    }
}
