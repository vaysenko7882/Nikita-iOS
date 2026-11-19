import UIKit
import CoreText
import CoreHaptics
import AVFoundation
import Photos
import SafariServices

/// Taptic Engine. Названия совпадают с тем, что присылает страница:
/// light, soft, rigid, medium, heavy, success, warning, error.
/// «heavy» — не просто щелчок, а удар с коротким гулом (бокс, взрывы, гол).
final class Haptics {
    static let shared = Haptics()

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let note = UINotificationFeedbackGenerator()
    private var engine: CHHapticEngine?
    private var lastHeavy = Date.distantPast

    func prepare() {
        [light, soft, rigid, medium, heavy].forEach { $0.prepare() }
        note.prepare()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = true
            e.playsHapticsOnly = true
            e.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine = e
        } catch {
            engine = nil
        }
    }

    func play(_ kind: String) {
        switch kind {
        case "soft": soft.impactOccurred()
        case "rigid": rigid.impactOccurred()
        case "medium": medium.impactOccurred()
        case "heavy": if !thud() { heavy.impactOccurred() }
        case "success": note.notificationOccurred(.success)
        case "warning": note.notificationOccurred(.warning)
        case "error": note.notificationOccurred(.error)
        default: light.impactOccurred()
        }
    }

    /// Удар: резкий щелчок и затухающий гул на 0.18 с
    private func thud() -> Bool {
        guard let engine, Date().timeIntervalSince(lastHeavy) > 0.08 else { return false }
        lastHeavy = Date()
        let hit = CHHapticEvent(eventType: .hapticTransient,
                                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                             CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.65)],
                                relativeTime: 0)
        let rumble = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
                                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)],
                                   relativeTime: 0.015, duration: 0.18)
        let fade = CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                          controlPoints: [CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1),
                                                          CHHapticParameterCurve.ControlPoint(relativeTime: 0.2, value: 0)],
                                          relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [hit, rumble], parameterCurves: [fade])
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }
}

/// Фирменный шрифт лежит в приложении — регистрируем его сами
enum FontLoader {
    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
}

/// Звук приложения.
/// Без голоса — режим «кино»: звук идёт даже при беззвучном переключателе и в фоне.
/// С голосом — «разговор»: микрофон и фильм вместе, звук в динамик, Bluetooth и AirPods работают.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private(set) var voiceOn = false

    func configure(voice on: Bool) {
        voiceOn = on
        let session = AVAudioSession.sharedInstance()
        do {
            if on {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            } else {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
            }
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("audio session:", error)
            #endif
        }
    }
}

/// Фото и видео из чата — прямо в приложение «Фото»
enum PhotoSaver {
    static func save(_ url: URL, done: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { done(ok) } }
        URLSession.shared.downloadTask(with: url) { temp, response, _ in
            guard let temp else { finish(false); return }
            let mime = (response?.mimeType ?? "").lowercased()
            let ext: String
            switch mime {
            case "image/png": ext = "png"
            case "image/gif": ext = "gif"
            case "image/webp": ext = "webp"
            case "video/mp4": ext = "mp4"
            case "video/quicktime": ext = "mov"
            case "video/webm": ext = "webm"
            default: ext = mime.hasPrefix("video/") ? "mp4" : "jpg"
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            do { try FileManager.default.moveItem(at: temp, to: file) } catch { finish(false); return }
            let video = mime.hasPrefix("video/")
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    try? FileManager.default.removeItem(at: file)
                    finish(false)
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: video ? .video : .photo, fileURL: file, options: nil)
                }, completionHandler: { ok, _ in
                    try? FileManager.default.removeItem(at: file)
                    finish(ok)
                })
            }
        }.resume()
    }
}

extension UIApplication {
    /// Верхний экран — от него показываем системные окна
    static var topController: UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    static func share(items: [Any]) {
        guard let top = topController else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }

    /// Внешняя страница (вход в Кинопаб, ссылки из чата) — во встроенном Safari поверх приложения
    static func openInSafari(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            shared.open(url)
            return
        }
        guard let top = topController else { shared.open(url); return }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = .white
        safari.preferredBarTintColor = .black
        safari.dismissButtonStyle = .close
        safari.overrideUserInterfaceStyle = .dark
        top.present(safari, animated: true)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
