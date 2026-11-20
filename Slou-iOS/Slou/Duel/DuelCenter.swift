import SwiftUI
import UIKit

/// Вызов владельцу комнаты
struct AskRequest: Identifiable {
    let id: Int
    let name: String
    let face: URL?
    let deadline: Date
}

struct Toast: Identifiable {
    let id = UUID()
    var title: String
    var detail: String = ""
    var action: String?
    var run: (() -> Void)?
}

/// Всё про битву за корону в приложении: вызов, ответ, арена, финал, тренировка с ботом.
/// Страница сообщает события комнаты через мост, ответы уходят на сервер через её же roomWire.
final class DuelCenter: ObservableObject {
    static let demoOpponentName = "Бот Слоу"

    @Published var arena: Arena?
    @Published var ask: AskRequest?
    @Published var waiting: Date?
    @Published var toast: Toast?
    @Published var ceremony: Ceremony?
    @Published private(set) var demoRoomOpen = false
    @Published var myFace: URL?

    weak var web: WebController?
    weak var model: AppModel?

    private var done: [Int] = UserDefaults.standard.array(forKey: "slou.crown.done") as? [Int] ?? []
    private var lastOrphan = Date.distantPast
    private var toastWork: DispatchWorkItem?
    private var waitWork: DispatchWorkItem?

    // MARK: от страницы

    func handle(_ m: [String: Any]) {
        guard !demoRoomOpen else { return }
        switch m["a"] as? String ?? "" {
        case "offline":
            show(Toast(title: "Создателя сейчас нет в сети"))
            buzz("warning")
        case "challenge":
            challenge()
        case "event":
            event(m)
        case "sync":
            sync(m)
        default:
            break
        }
    }

    private func challenge() {
        guard arena == nil, waiting == nil else { return }
        buzz("medium")
        sfx("horn", 0.7)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { waiting = Date() }
        waitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation { self?.waiting = nil } }
        waitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
        send("crown", ["act": "challenge"]) { [weak self] ok, _, error in
            guard let self, !ok else { return }
            withAnimation { self.waiting = nil }
            self.show(Toast(title: error ?? "Вызов не отправился"))
            buzz("error")
        }
    }

    private func event(_ m: [String: Any]) {
        let act = m["act"] as? String ?? ""
        let age = jsonNumber(m["age"]) ?? 0
        let mine = m["mine"] as? String ?? "host"
        switch act {
        case "challenge":
            guard mine == "host", (m["seat"] as? String) == "friend", age < 80000, (m["state"] as? String) == "asked",
                  let id = jsonInt(m["id"]), arena == nil, ask == nil else { return }
            let left = max(5, (85000 - age) / 1000)
            let face = URL(string: m["actorFace"] as? String ?? "")
            let name = (m["actorName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Гость"
            refreshFace()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                ask = AskRequest(id: id, name: name, face: face, deadline: Date().addingTimeInterval(left))
            }
            sfx("horn")
            buzz("heavy")
            DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self] in
                guard let self, self.ask?.id == id else { return }
                withAnimation { self.ask = nil }
            }
        case "answer":
            guard age <= 60000, let duel = jsonInt(m["duel"]) else { return }
            if m["accept"] as? Bool == true {
                startArena(duel: duel, me: mine)
            } else if mine == "friend" {
                withAnimation { waiting = nil }
                show(Toast(title: "Король отказался", detail: "Попробуй через минуту"))
                buzz("warning")
            }
        case "final":
            guard age <= 180000 else { return }
            let duel = jsonInt(m["duel"]) ?? 0
            markDone(duel)
            let iWon = (m["scope"] as? String) == "owner"
            let crownScore = jsonInt(m["crown"]) ?? 0
            let poopScore = jsonInt(m["poop"]) ?? 0
            let swap = m["swap"] as? Bool ?? false
            let forfeit = m["forfeit"] as? Bool ?? false
            let winner = (m["actorName"] as? String) ?? ""
            let line: String
            if forfeit {
                line = iWon ? "Соперник сдался. Корона твоя." : "Ты сдался. Корона уходит."
            } else if iWon {
                line = swap ? "Корона твоя! Теперь ты управляешь комнатой." : "Корона осталась на твоей голове. Претенденту — 💩."
            } else {
                let who = winner.isEmpty ? (swap ? "соперник" : "создатель") : winner
                line = swap ? "Корону забирает \(who). Тебе — 💩 и место гостя." : "Не вышло: \(who) сохраняет корону, а тебе — 💩."
            }
            let c = Ceremony(iWon: iWon, myScore: iWon ? crownScore : poopScore, theirScore: iWon ? poopScore : crownScore,
                             swap: swap, line: line, meName: "", opName: "", meFace: nil, opFace: nil)
            if let a = arena {
                a.conclude(c)
            } else if age < 60000 {
                info { [weak self] room in
                    guard let self, !self.demoRoomOpen else { return }
                    var solo = c
                    solo.meName = "Ты"
                    if let peer = room?.peerName, !peer.isEmpty { solo.opName = peer } else { solo.opName = "Соперник" }
                    solo.meFace = room?.meFace
                    solo.opFace = room?.peerFace
                    withAnimation(.easeInOut(duration: 0.35)) { self.ceremony = solo }
                    self.model?.duel = true
                }
            }
        default:
            break
        }
    }

    private func sync(_ m: [String: Any]) {
        let duel = m["duel"] as? [String: Any]
        if waiting != nil && duel == nil { withAnimation { waiting = nil } }
        // битва идёт, а арены нет (приложение перезапустили) — предложить сдаться
        guard let d = duel, (d["state"] as? String) == "playing", arena == nil,
              let id = jsonInt(d["id"]), !done.contains(id),
              let now = jsonNumber(m["now"]), let at = jsonNumber(d["at"]), now - at > 12000,
              Date().timeIntervalSince(lastOrphan) > 60 else { return }
        lastOrphan = Date()
        show(Toast(title: "Битва за корону прервалась", detail: "Вернуться в неё нельзя", action: "Сдаться", run: { [weak self] in
            self?.markDone(id)
            self?.send("crown", ["act": "forfeit", "duel": id]) { _, _, _ in }
        }), seconds: 15)
    }

    // MARK: действия

    func answer(_ accept: Bool) {
        guard let req = ask else { return }
        buzz(accept ? "heavy" : "light")
        send("crown", ["act": "answer", "duel": req.id, "accept": accept]) { [weak self] ok, _, error in
            guard let self else { return }
            withAnimation { self.ask = nil }
            if !ok {
                self.show(Toast(title: error ?? "Не получилось ответить"))
            } else if accept {
                self.startArena(duel: req.id, me: "host")
            }
        }
    }

    private func startArena(duel: Int, me: String) {
        guard arena == nil, !done.contains(duel) else { return }
        markDone(duel)
        withAnimation { waiting = nil; toast = nil; ask = nil }
        web?.js("window.__slouNative.closeDialogs(); return 'ok'", [:]) { _ in }
        web?.js("return String(window.__slouNative.busy(true))", [:]) { _ in }
        info { [weak self] room in
            guard let self, self.arena == nil, !self.demoRoomOpen else { return }
            guard let room else {
                self.show(Toast(title: "Нет комнаты"))
                return
            }
            self.open(Arena(duel: duel, me: me, info: room, bot: false))
        }
    }

    func enterDemoRoom() {
        guard arena == nil, ceremony == nil, ask == nil, waiting == nil, model?.duel != true else { return }
        model?.showSettings = false
        guard !demoRoomOpen else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        buzz("light")
        withAnimation(.easeOut(duration: 0.2)) {
            toast = nil
            demoRoomOpen = true
        }
    }

    func leaveDemoRoom() {
        guard demoRoomOpen else { return }
        if let arena, arena.bot { arena.close() }
        withAnimation(.easeOut(duration: 0.2)) { demoRoomOpen = false }
    }

    func practice(_ game: Int? = nil) {
        guard demoRoomOpen, arena == nil else { return }
        if let game, !Arcade.games.indices.contains(game) { return }
        var room = RoomInfo()
        room.name = "Ты"
        room.peerName = Self.demoOpponentName
        open(Arena(duel: 0, me: "host", info: room, bot: true, only: game))
    }

    private func open(_ a: Arena) {
        a.center = self
        Orientation.lockPortrait(true)
        UIApplication.shared.isIdleTimerDisabled = true
        withAnimation(.easeOut(duration: 0.3)) { arena = a }
        if !a.bot { model?.duel = true }
    }

    func arenaClosed(_ a: Arena) {
        guard arena === a else { return }
        withAnimation(.easeIn(duration: 0.25)) { arena = nil }
        if !a.bot {
            model?.duel = false
            web?.js("return String(window.__slouNative.busy(false))", [:]) { _ in }
        }
        Orientation.lockPortrait(false)
        UIApplication.shared.isIdleTimerDisabled = model?.inRoom ?? false
        Sound.shared.stopAllLoops()
    }

    func closeCeremony() {
        withAnimation(.easeIn(duration: 0.25)) { ceremony = nil }
        model?.duel = false
    }

    // MARK: связь со страницей

    /// Отправить событие в комнату тем же путём, что и сайт
    func send(_ kind: String, _ data: [String: Any], done: @escaping (Bool, [String: Any]?, String?) -> Void) {
        guard let web else { done(false, nil, "Нет соединения с комнатой."); return }
        web.js("return await window.__slouNative.send(kind, data)", ["kind": kind, "data": data]) { text in
            guard let text, let raw = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                done(false, nil, "Нет соединения с комнатой.")
                return
            }
            if obj["ok"] as? Bool == true { done(true, obj["res"] as? [String: Any], nil) }
            else { done(false, nil, obj["error"] as? String) }
        }
    }

    func info(_ done: @escaping (RoomInfo?) -> Void) {
        guard let web else { done(nil); return }
        web.js("return window.__slouNative.info()", [:]) { [weak self] text in
            guard let text, let raw = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let room = RoomInfo(json: obj) else { done(nil); return }
            self?.myFace = room.meFace
            done(room)
        }
    }

    func refreshFace() { info { _ in } }

    func show(_ t: Toast, seconds: Double = 3.6) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = t }
        let id = t.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toast?.id == id else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func markDone(_ id: Int) {
        guard id > 0, !done.contains(id) else { return }
        done.append(id)
        if done.count > 20 { done.removeFirst(done.count - 20) }
        UserDefaults.standard.set(done, forKey: "slou.crown.done")
    }
}

/// На время битвы экран держится вертикально
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.mask
    }
}

enum Orientation {
    static func lockPortrait(_ on: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.mask = on ? .portrait : .allButUpsideDown
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if on { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
            for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }
}

extension Notification.Name {
    static let slouShake = Notification.Name("slou.shake")
}

/// Встряхнул телефон — открылась Аркада
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .slouShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
