#if SLOU_ARCADE_REVIEW && targetEnvironment(simulator)
import SwiftUI
import Combine

/// Simulator fixture. Runs the shipping input and rendering paths at the actual device size.
struct ArcadeReviewPane: View {
    @State private var host: GameHost?
    @State private var pilot: ArcadePilot?
    @State private var signalled = false
    private let tick = Timer.publish(every: 0.035, on: .main, in: .common).autoconnect()

    private var files: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("arcade-review")
    }

    var body: some View {
        let args = ProcessInfo.processInfo.arguments
        let id = args.firstIndex(of: "-arcade-review").flatMap { $0+1 < args.count ? args[$0+1] : nil } ?? "race"
        let info = Arcade.games.first(where: { $0.id == id }) ?? Arcade.games[0]
        VStack(spacing: 0) {
            HStack {
                Text(info.edition).font(ArcadeType.title(info.id, 21))
                Spacer()
                Text("Раунд 1/3").font(.caption.weight(.semibold))
            }.padding(.horizontal, 16).frame(height: 47)
            GeometryReader { geo in
                if let host {
                    GameStageView(host: host)
                } else {
                    Color.black.onAppear {
                        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                        if args.contains("-review-checks") {
                            let results = ArcadeChecks.run()
                            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                                try? data.write(to: files.appendingPathComponent("checks.json"), options: .atomic)
                            }
                        }
                        let ctx = GameContext(round: 0, size: geo.size, seed: 740, duration: info.practiceDuration)
                        let stage = GameHost(info: info, ctx: ctx)
                        let driver = ArcadePilot(game: stage.game, skill: 0.72, seed: 740)
                        stage.start()
                        pilot = driver
                        host = stage
                    }
                }
            }.clipped()
            HStack {
                Image(systemName: "cpu").foregroundStyle(info.color)
                Text("Бот Слоу").font(.subheadline)
                Spacer()
                Text("В комнату").font(.subheadline.weight(.semibold))
            }.padding(.horizontal, 16).frame(height: 44)
        }
        .foregroundStyle(.white)
        .background(Color(hex: 0x0c100f).ignoresSafeArea())
        .statusBarHidden()
        .onReceive(tick) { _ in
            guard let host, let pilot else { return }
            if info.id == "duel", let game = host.game as? ShowdownGame, game.state == .liveSignal {
                // Keep the seal visible long enough to sample its trajectory on a video frame.
                if game.elapsed.truncatingRemainder(dividingBy: 2.6) < 0.25 { pilot.think() }
            } else { pilot.think() }
            if !signalled, host.game.elapsed > 0.24 {
                try? Data(id.utf8).write(to: files.appendingPathComponent(id+".ready"), options: .atomic)
                signalled = true
            }
        }
        .onDisappear { if let host { _ = host.game.stop()
                host.halt() } }
    }
}

private enum ArcadeChecks {
    static func run() -> [String: Bool] {
        var result: [String: Bool] = [:]
        func make(_ info: GameInfo, round: Int = 0) -> StudioGame {
            let game = info.make(GameContext(round: round, size: CGSize(width: 390, height: 665), seed: 740,
                                             duration: info.practiceDuration, effectsEnabled: false))
            game.start()
            return game
        }
        func advance(_ g: StudioGame, _ seconds: Double) {
            for _ in 0..<Int((seconds*60).rounded()) { g.step(1.0/60) }
        }
        for info in Arcade.games {
            for round in 0...2 {
                let game = make(info, round: round)
                let driver = ArcadePilot(game: game, skill: 0.72, seed: 740)
                while game.elapsed < info.practiceDuration, game.c.finished == nil {
                    game.step(1.0/30)
                    driver.think()
                }
                result["bot."+info.id+".round"+String(round+1)] = game.stop() > 0
            }
        }
        for info in Arcade.games {
            let game = make(info)
            let hands = ArcadePilot(game: game, skill: 0.72, seed: 740)
            let w = game.width, h = game.height
            switch game {
            case let race as RaceGame:
                advance(race, 0.65)
                result["race.stationary"] = race.velocity == 0 && race.distance == 0
                let wheel = P(w*0.225, h-58)
                hands.down(1, at: wheel)
                hands.down(2, at: P(w*0.84, h-58))
                hands.move(1, to: P(wheel.x+39, wheel.y))
                advance(race, 1.4)
                let speed = race.velocity
                result["race.two-finger-steering"] = speed > 45 && race.lateral > 0.14
                hands.up(1)
                advance(race, 0.35)
                result["race.independent-throttle"] = race.velocity > speed
                hands.up(2)
                hands.down(3, at: P(w*0.60, h-58))
                advance(race, 1.2)
                result["race.braking"] = race.velocity < 2
                hands.move(3, to: P(w*0.85, h-58))
                advance(race, 0.8)
                let accelerating = race.velocity
                hands.down(4, at: P(w*0.88, h-59))
                advance(race, 0.22)
                result["race.same-pedal-second-finger"] = race.velocity > accelerating
                hands.up(4)
                hands.move(3, to: P(w*0.60, h-58))
                advance(race, 0.8)
                result["race.slide-between-pedals"] = accelerating > 15 && race.velocity < 1
            case let box as BoxGame:
                advance(box, 0.55)
                hands.tap(P(w/2, h/2))
                result["box.jab"] = box.opponentHealth < 100 && box.stamina < 1
                let afterJab = box.opponentHealth
                advance(box, 0.3)
                hands.tap(P(0, 0))
                result["box.distance-matters"] = box.opponentHealth == afterJab
                hands.down(1, at: P(w/2, h/2))
                advance(box, 1.9)
                result["box.guard"] = box.stamina < 0.85
            case let mine as MinesGame:
                let cell = min((w-40)/6, (h-195)/7)
                let y = max(82, (h-cell*7)*0.48)
                hands.tap(P(w/2+cell/2, y+cell*5.5))
                result["mines.safe-neighbour"] = mine.position == 33 && mine.score() > 0
            case let duel as ShowdownGame:
                let pad = P(w/2, h-65)
                hands.down(1, at: pad)
                hands.up(1)
                result["duel.false-start"] = duel.state == .feedback && duel.score() == 0
                advance(duel, 0.85)
                hands.down(1, at: pad)
                advance(duel, 1.8)
                result["duel.bell"] = duel.state == .liveSignal
            case let range as RangeGame:
                hands.tap(P(w*0.22, h*0.34))
                result["range.tin-target"] = range.ammo == 4 && range.score() > 0
                for _ in 0..<4 { hands.tap(P(12, 200)) }
                let empty = range.ammo == 0
                hands.tap(P(w-75, h-49))
                advance(range, 0.9)
                result["range.reload"] = empty && range.ammo == 5 && !range.reloading
            case let arm as ArmGame:
                hands.down(1, at: P(w/2, h-60))
                advance(arm, 0.9)
                let energy = arm.stamina
                hands.up(1)
                advance(arm, 0.35)
                result["arm.press-recover"] = arm.leverage > 0 && energy < 0.80 && arm.stamina > energy
            case let hoop as HoopGame:
                hands.swipe(from: P(w/2, h*0.8), to: P(w/2, h*0.56))
                advance(hoop, 2.5)
                result["hoop.clean-basket"] = hoop.points == 15 && hoop.streak == 1
                let start = P(w*0.37, h*0.8)
                hands.swipe(from: start, to: P(start.x + (w/2-start.x+29)/2.4, start.y-h*0.30))
                advance(hoop, 2.5)
                result["hoop.bank-shot"] = hoop.points == 28 && hoop.streak == 2
            case let beat as BeatGame:
                let period = 60.0/(110*0.95)
                advance(beat, 3*period)
                hands.tap(P(w/8, h*0.86))
                let first = beat.score()
                advance(beat, 4*period)
                hands.down(1, at: P(w/8, h*0.86))
                let touched = beat.score()
                advance(beat, 1.3*period)
                hands.up(1)
                result["beat.timing-and-hold"] = first > 0 && touched > first && beat.score() > touched
            default: break
            }
            _ = game.stop()
        }
        return result
    }
}
#endif
