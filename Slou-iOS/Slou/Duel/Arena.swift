import SwiftUI
import QuartzCore

/// Кто играет: берётся со страницы комнаты
struct RoomInfo {
    var code = ""
    var scope = "owner"
    var ownerKey = ""
    var guestKey = ""
    var name = ""
    var peerName = ""
    var meFace: URL?
    var peerFace: URL?
    var peerOnline = false
    var origin: URL?

    init() {}

    init?(json: [String: Any]) {
        guard let code = json["code"] as? String, !code.isEmpty else { return nil }
        self.code = code
        scope = json["scope"] as? String ?? "owner"
        ownerKey = json["ownerKey"] as? String ?? ""
        guestKey = json["guestKey"] as? String ?? ""
        name = json["name"] as? String ?? ""
        peerName = json["peerName"] as? String ?? ""
        meFace = URL(string: json["meFace"] as? String ?? "")
        peerFace = URL(string: json["peerFace"] as? String ?? "")
        peerOnline = json["peerOnline"] as? Bool ?? false
        origin = URL(string: json["origin"] as? String ?? "")
    }

    var seat: String { scope == "guest" ? "friend" : "host" }
}

/// Финал битвы: корона летит победителю, какашка — проигравшему
struct Ceremony: Identifiable {
    let id = UUID()
    var iWon: Bool
    var myScore: Int
    var theirScore: Int
    var swap: Bool
    var line: String
    var meName: String
    var opName: String
    var meFace: URL?
    var opFace: URL?
    var practice = false
}

/// Битва за корону на айфоне. Тот же порядок сообщений, что у сайта, поэтому соперник
/// может играть хоть в приложении, хоть в браузере: ведущий — создатель комнаты, он назначает
/// старт каждого раунда по часам сервера, и игра начинается у обоих в один и тот же миг.
final class Arena: ObservableObject, Identifiable {
    enum Card: Equatable {
        case hello(String)
        case intro(Int)
        case count(Int, Int, Int)
        case clear
        case waitOp(Int)
        case splash(Int, Int, Int)
        case sum(Int, Int, Int)
        case tally(Int, Int)
        case broken(String)
        case giving
    }
    enum Phase { case start, play, ending, ceremony, broken }

    let id = UUID()
    let duel: Int
    let me: String
    let op: String
    let bot: Bool
    let conductor: Bool
    /// Только одна игра (тренировка)
    let only: Int?

    @Published var card: Card = .hello("Подключаемся")
    @Published var host: GameHost?
    @Published var g = 0
    @Published var r = 0
    @Published var totalMe = 0
    @Published var totalOp = 0
    @Published var oppLive: Int?
    @Published var note = ""
    @Published var ceremony: Ceremony?
    @Published var info: RoomInfo
    @Published private(set) var phase = Phase.start

    var stageSize = CGSize(width: 390, height: 560)
    weak var center: DuelCenter?

    private let games = Arcade.games
    private var link: LiveLink?
    private var timers: [UUID: DispatchWorkItem] = [:]
    private var closed = false
    private var offset: Double = Date().timeIntervalSince1970 * 1000 - CACurrentMediaTime() * 1000
    private var rtt: Double = 1e9
    private var pongs = 0
    private var peer = false
    private var begun = false
    private var seed: UInt32 = 1
    private var mine: [Int: Int] = [:]
    private var theirs: [Int: Int] = [:]
    private var oppLiveMap: [Int: Int] = [:]
    private var playing = -1
    private var shown = -1
    private var lastGo: (g: Int, r: Int, at: Double)?
    private var retried = 0
    private var waitTimer: UUID?
    private var goneTimer: UUID?
    private var opTimer: UUID?
    private var pinger: UUID?
    private var liveSent: Double = 0
    private var liveTimer: UUID?
    private var liveNext: (g: Int, r: Int, s: Int)?
    private var from: Int

    init(duel: Int, me: String, info: RoomInfo, bot: Bool, from: Int = 0, only: Int? = nil) {
        self.duel = duel
        self.me = me
        self.op = me == "host" ? "friend" : "host"
        self.bot = bot
        self.conductor = bot || me == "host"
        self.info = info
        self.only = only
        self.from = only ?? from
        g = self.from
        Sound.shared.warm()
        sfx("horn", 0.8)
        if bot { botStart() } else { connect() }
    }

    var maxGame: Int { only ?? (games.count - 1) }
    var game: GameInfo { games[min(games.count - 1, max(0, g))] }
    var isOver: Bool { phase == .ending || phase == .ceremony }

    // MARK: время и таймеры

    private func local() -> Double { CACurrentMediaTime() * 1000 }
    func now() -> Double { local() + offset }

    @discardableResult
    private func later(_ ms: Double, _ fn: @escaping () -> Void) -> UUID {
        let key = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timers[key] = nil
            if !self.closed { fn() }
        }
        timers[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000, execute: item)
        return key
    }

    @discardableResult
    private func at(_ serverTime: Double, _ fn: @escaping () -> Void) -> UUID { later(serverTime - now(), fn) }

    private func cancel(_ key: UUID?) {
        guard let key, let item = timers.removeValue(forKey: key) else { return }
        item.cancel()
    }

    private func cancelAll() {
        for item in timers.values { item.cancel() }
        timers.removeAll()
    }

    // MARK: связь

    private var liveURL: URL? {
        guard let origin = info.origin, var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/api/live"
        parts.queryItems = [URLQueryItem(name: "code", value: info.code)]
        return parts.url
    }

    private func connect() {
        guard let url = liveURL, !info.code.isEmpty else { broken("Нет комнаты."); return }
        let l = LiveLink()
        l.onOpen = { [weak self] in self?.hello() }
        l.onMessage = { [weak self] m in self?.wire(m) }
        l.onClose = { [weak self] in self?.dropped() }
        link = l
        l.connect(url)
        if waitTimer == nil {
            waitTimer = later(25000) { [weak self] in
                guard let self, !self.begun else { return }
                self.broken("Соперник не подключился к битве.")
            }
        }
    }

    private func hello() {
        if info.scope == "guest" { link?.send(["t": "hello", "guest": info.guestKey]) }
        else { link?.send(["t": "hello", "owner": info.ownerKey]) }
    }

    private func wire(_ m: [String: Any]) {
        switch m["t"] as? String ?? "" {
        case "ready":
            peer = m["peer"] as? Bool ?? false
            ping()
            maybeBegin()
        case "peer":
            peer = m["on"] as? Bool ?? false
            if peer { back(); maybeBegin() } else { gone() }
        case "pong":
            guard let c = jsonNumber(m["c"]), let s = jsonNumber(m["s"]) else { return }
            let trip = local() - c
            if trip < rtt * 1.3 {
                offset = s + trip / 2 - local()
                rtt = min(rtt, trip)
            }
            pongs += 1
            maybeBegin()
        case "g":
            receive(m)
        default:
            break
        }
    }

    private func ping() {
        cancel(pinger)
        for i in 0..<6 {
            later(Double(i) * 110) { [weak self] in self?.pingOnce() }
        }
        repeatPing()
    }

    private func pingOnce() {
        link?.send(["t": "ping", "c": local()])
    }

    private func repeatPing() {
        pinger = later(3000) { [weak self] in
            self?.pingOnce()
            self?.repeatPing()
        }
    }

    private func send(_ m: [String: Any]) {
        if bot { botHear(m); return }
        var out = m
        out["t"] = "g"
        link?.send(out)
    }

    private func maybeBegin() {
        guard !begun, peer, pongs >= 4 else { return }
        send(["k": "hi"])
        guard conductor else { return }
        begun = true
        seed = UInt32.random(in: 1...UInt32.max)
        send(["k": "plan", "seed": Int(seed)])
        schedule(from, 0, now() + 1400)
    }

    private func receive(_ m: [String: Any]) {
        let k = m["k"] as? String ?? ""
        switch k {
        case "hi":
            if !conductor { note = "" }
        case "plan":
            begun = true
            if let s = jsonNumber(m["seed"]) { seed = UInt32(truncatingIfNeeded: Int64(s)) }
        case "go":
            if !conductor, let gg = jsonInt(m["g"]), let rr = jsonInt(m["r"]), let a = jsonNumber(m["at"]) { play(gg, rr, a) }
        case "p":
            if let gg = jsonInt(m["g"]), let rr = jsonInt(m["r"]), let s = jsonInt(m["s"]) { liveScore(gg, rr, s) }
        case "done":
            if let gg = jsonInt(m["g"]), let rr = jsonInt(m["r"]) { opDone(gg, rr, clamp(jsonInt(m["pts"]) ?? 0, 0, 100), timeout: false) }
        case "bye":
            note = "Соперник сдался"
        default:
            break
        }
    }

    private func gone() {
        if isOver { return }
        note = "Соперник пропал. Ждём 20 секунд…"
        cancel(goneTimer)
        goneTimer = later(20000) { [weak self] in
            guard let self, !self.peer else { return }
            self.endEarly()
        }
    }

    private func back() {
        cancel(goneTimer)
        note = ""
        if conductor, let go = lastGo, go.at > now() { send(["k": "go", "g": go.g, "r": go.r, "at": Int64(go.at)]) }
    }

    private func dropped() {
        guard !closed, !isOver else { return }
        if retried > 2 { endEarly(); return }
        retried += 1
        note = "Связь оборвалась, переподключаемся…"
        cancel(pinger)
        link = nil
        later(1500) { [weak self] in self?.connect() }
    }

    private func broken(_ text: String) {
        phase = .broken
        stopGame()
        card = .broken(text)
        sfx("lose", 0.6)
        buzz("warning")
    }

    // MARK: ход игры

    private func lead(_ g: Int, _ r: Int) -> Double { 1700 + (r == 0 ? 2700 : 0) }

    private func schedule(_ g: Int, _ r: Int, _ after: Double) {
        let start = (after + lead(g, r)).rounded()
        lastGo = (g: g, r: r, at: start)
        send(["k": "go", "g": g, "r": r, "at": Int64(start)])
        play(g, r, start)
    }

    private func play(_ gg: Int, _ rr: Int, _ start: Double) {
        guard !closed, phase != .ending, phase != .ceremony, gg >= 0, gg < games.count, rr >= 0, rr < 3 else { return }
        let key = gg * 3 + rr
        if playing == key { return }
        playing = key
        phase = .play
        cancel(waitTimer)
        let info = games[gg]
        at(start - lead(gg, rr)) { [weak self] in
            guard let self else { return }
            self.g = gg
            self.r = rr
            self.oppLive = nil
            if rr == 0 {
                self.stopGame()
                self.host = nil
                self.card = .intro(gg)
                sfx("slam")
                buzz("heavy")
            }
        }
        at(start - 1600) { [weak self] in
            guard let self else { return }
            self.mount(gg, rr)
            for (i, v) in [3, 2, 1].enumerated() {
                self.later(Double(i) * 500) { [weak self] in
                    self?.card = .count(gg, rr, v)
                    sfx("count", 0.8)
                    buzz("rigid")
                }
            }
        }
        at(start) { [weak self] in
            guard let self else { return }
            self.card = .clear
            sfx("go", 0.8)
            buzz("heavy")
            self.host?.start()
            let t0 = self.local()
            self.runCheck(gg, rr, t0, info.duration * 1000)
        }
    }

    private func mount(_ gg: Int, _ rr: Int) {
        stopGame()
        var size = stageSize
        if size.width < 50 || size.height < 50 { size = CGSize(width: 390, height: 560) }
        let mixed = SeededRandom.mix([Int(seed), gg + 1, rr + 1])
        let ctx = GameContext(round: rr, size: size, seed: mixed)
        let key = gg * 3 + rr
        ctx.report = { [weak self] n in self?.reportLive(gg, rr, n) }
        ctx.opponent = { [weak self] in self?.oppLiveMap[key] }
        host = GameHost(info: games[gg], ctx: ctx)
    }

    private func stopGame() {
        if let h = host, h.running { _ = h.game.stop(); h.halt() }
        Sound.shared.stopAllLoops()
    }

    private func runCheck(_ gg: Int, _ rr: Int, _ t0: Double, _ dur: Double) {
        guard !closed, playing == gg * 3 + rr, let h = host, h.running else { return }
        if let f = h.ctx.finished, gameNow() >= f.at {
            _ = h.game.stop()
            h.halt()
            Sound.shared.stopAllLoops()
            myDone(gg, rr, clamp(f.pts, 0, 100))
        } else if local() - t0 >= dur {
            let pts = h.game.stop()
            h.halt()
            Sound.shared.stopAllLoops()
            myDone(gg, rr, clamp(pts, 0, 100))
        } else {
            later(50) { [weak self] in self?.runCheck(gg, rr, t0, dur) }
        }
    }

    private func reportLive(_ gg: Int, _ rr: Int, _ n: Int) {
        let s = clamp(n, 0, 100)
        liveNext = (g: gg, r: rr, s: s)
        let t = local()
        if t - liveSent > 180 {
            liveSent = t
            send(["k": "p", "g": gg, "r": rr, "s": s])
        } else if liveTimer == nil {
            liveTimer = later(200) { [weak self] in
                guard let self, let next = self.liveNext else { return }
                self.liveTimer = nil
                self.liveSent = self.local()
                self.send(["k": "p", "g": next.g, "r": next.r, "s": next.s])
            }
        }
    }

    private func liveScore(_ gg: Int, _ rr: Int, _ s: Int) {
        let key = gg * 3 + rr
        oppLiveMap[key] = s
        if playing == key && oppLive != s { oppLive = s }
    }

    private func myDone(_ gg: Int, _ rr: Int, _ pts: Int) {
        let i = gg * 3 + rr
        mine[i] = pts
        send(["k": "done", "g": gg, "r": rr, "pts": pts])
        if theirs[i] == nil {
            card = .waitOp(pts)
            opTimer = later(9000) { [weak self] in
                guard let self, self.theirs[i] == nil else { return }
                self.opDone(gg, rr, 0, timeout: true)
            }
        } else {
            roundOver(gg, rr)
        }
    }

    private func opDone(_ gg: Int, _ rr: Int, _ pts: Int, timeout: Bool) {
        let i = gg * 3 + rr
        if theirs[i] != nil { return }
        theirs[i] = pts
        if timeout { note = "Соперник не ответил — 0 за раунд" }
        if mine[i] != nil {
            cancel(opTimer)
            roundOver(gg, rr)
        }
    }

    private func roundOver(_ gg: Int, _ rr: Int) {
        let i = gg * 3 + rr
        guard shown != i, let a = mine[i], let b = theirs[i] else { return }
        shown = i
        card = .splash(rr, a, b)
        sfx(a >= b ? "win" : "lose", 0.8)
        buzz(a > b ? "success" : a < b ? "warning" : "medium")
        var wait: Double = 1500
        if rr == 2 {
            later(1500) { [weak self] in
                guard let self else { return }
                var ga = 0, gb = 0
                for k in 0..<3 { ga += self.mine[gg * 3 + k] ?? 0; gb += self.theirs[gg * 3 + k] ?? 0 }
                self.card = .sum(gg, ga, gb)
                self.setTotals()
                sfx("sparkle", 0.8)
            }
            wait += 2000
        }
        if gg >= maxGame && rr == 2 {
            later(wait) { [weak self] in self?.finishAll() }
            return
        }
        if conductor {
            let ng = rr == 2 ? gg + 1 : gg
            let nr = rr == 2 ? 0 : rr + 1
            later(wait - 200) { [weak self] in
                guard let self else { return }
                self.schedule(ng, nr, self.now() + 200)
            }
        }
    }

    private func setTotals() {
        let a = mine.values.reduce(0, +)
        let b = theirs.values.reduce(0, +)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            totalMe = a
            totalOp = b
        }
    }

    // MARK: конец

    private func totals() -> (host: Int, friend: Int) {
        let cap = games.count * 3 * 100
        let a = min(cap, mine.values.reduce(0, +))
        let b = min(cap, theirs.values.reduce(0, +))
        return me == "host" ? (host: a, friend: b) : (host: b, friend: a)
    }

    private func finishAll() {
        if isOver { return }
        phase = .ending
        stopGame()
        let t = totals()
        let my = me == "host" ? t.host : t.friend
        let their = me == "host" ? t.friend : t.host
        setTotals()
        card = .tally(my, their)
        if bot {
            later(1600) { [weak self] in
                guard let self else { return }
                let won = my >= their
                let line = won ? "Бот повержен. Корона — твоя (в тренировке)." : "Бот оказался сильнее. Реванш?"
                self.conclude(Ceremony(iWon: won, myScore: my, theirScore: their, swap: false, line: line,
                                    meName: "Ты", opName: "Бот", meFace: self.info.meFace, opFace: nil, practice: true))
            }
        } else {
            report(t, claim: false)
        }
    }

    private func report(_ t: (host: Int, friend: Int), claim: Bool) {
        var data: [String: Any] = ["act": "result", "duel": duel, "host": t.host, "friend": t.friend]
        if claim { data["claim"] = true }
        center?.send("crown", data) { [weak self] ok, res, _ in
            guard let self, !self.closed, self.phase == .ending else { return }
            if ok {
                if (res?["waiting"] as? Bool) == true {
                    self.later(claim ? 8000 : 42000) { [weak self] in self?.report(t, claim: true) }
                }
            } else {
                self.later(5000) { [weak self] in self?.report(t, claim: claim) }
            }
        }
    }

    func endEarly() {
        if isOver || closed { return }
        finishAll()
    }

    func forfeit() {
        if isOver { return }
        if bot { close(); return }
        send(["k": "bye"])
        phase = .ending
        stopGame()
        card = .giving
        buzz("warning")
        center?.send("crown", ["act": "forfeit", "duel": duel]) { [weak self] ok, _, _ in
            if !ok { self?.close() }
        }
    }

    /// Закрыть после ошибки: сдаёмся, чтобы комната не зависла в «битве»
    func dismissBroken() {
        if !bot { center?.send("crown", ["act": "forfeit", "duel": duel]) { _, _, _ in } }
        close()
    }

    func conclude(_ c: Ceremony) {
        if phase == .ceremony { return }
        phase = .ceremony
        stopGame()
        cancelAll()
        var cer = c
        if cer.meName.isEmpty { cer.meName = "Ты" }
        if cer.opName.isEmpty { cer.opName = info.peerName.isEmpty ? "Соперник" : info.peerName }
        if cer.meFace == nil { cer.meFace = info.meFace }
        if cer.opFace == nil && !bot { cer.opFace = info.peerFace }
        withAnimation(.easeInOut(duration: 0.35)) { ceremony = cer }
    }

    func close() {
        if closed { return }
        closed = true
        cancelAll()
        stopGame()
        link?.close()
        link = nil
        center?.arenaClosed(self)
    }

    // MARK: тренировка: соперник-бот

    private func botStart() {
        peer = true
        pongs = 9
        later(1600) { [weak self] in self?.maybeBegin() }
    }

    private func botHear(_ m: [String: Any]) {
        guard (m["k"] as? String) == "go", let gg = jsonInt(m["g"]), let rr = jsonInt(m["r"]), let start = jsonNumber(m["at"]) else { return }
        let info = games[gg]
        let skill = 0.5 + Double.random(in: 0...0.35)
        let target = clamp(Int((skill * 100 - Double(rr) * 6 + Double.random(in: -20...20)).rounded()), 4, 98)
        let startIn = start - now()
        let length = info.duration * 1000 * Double.random(in: 0.55...0.95)
        for k in 1...5 {
            later(startIn + length * Double(k) / 6) { [weak self] in
                self?.liveScore(gg, rr, Int((Double(target) * Double(k) / 6).rounded()))
            }
        }
        later(startIn + length + 300) { [weak self] in self?.opDone(gg, rr, target, timeout: false) }
    }
}
