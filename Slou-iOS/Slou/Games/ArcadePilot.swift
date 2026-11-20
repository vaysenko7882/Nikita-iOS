import SwiftUI

/// Local opponent. Its inputs pass through the same touch handler as a player's fingers.
final class ArcadePilot {
    let game: StudioGame
    let skill: Double
    var random: SeededRandom
    private(set) var hands: [Int: CGPoint] = [:]
    var attemptedNotes: Set<Int> = []
    private var nextThought = 0.16

    init(game: StudioGame, skill: Double, seed: UInt32) {
        self.game = game
        self.skill = clamp(skill, 0.15, 0.93)
        self.random = SeededRandom(seed: seed)
    }

    func think() {
        guard game.live, game.elapsed >= nextThought else { return }
        wait(0.06)
        game.playTurn(self)
    }

    func wait(_ seconds: Double) { nextThought = game.elapsed + seconds }

    func down(_ id: Int, at point: CGPoint) {
        guard hands[id] == nil else { return }
        hands[id] = point
        send(.began, id, point)
    }

    func move(_ id: Int, to point: CGPoint) {
        guard hands[id] != nil else { return }
        hands[id] = point
        send(.moved, id, point)
    }

    func up(_ id: Int, at point: CGPoint? = nil) {
        guard let last = hands.removeValue(forKey: id) else { return }
        send(.ended, id, point ?? last)
    }

    func tap(_ point: CGPoint, id: Int = 1) {
        down(id, at: point)
        up(id)
    }

    func swipe(from a: CGPoint, through middle: CGPoint? = nil, to b: CGPoint) {
        down(1, at: a)
        move(1, to: middle ?? P((a.x+b.x)/2, (a.y+b.y)/2))
        up(1, at: b)
    }

    private func send(_ phase: TouchEvent.Phase, _ id: Int, _ point: CGPoint) {
        game.touch(TouchEvent(phase: phase, id: id, point: P(point.x*game.unit, point.y*game.unit), time: game.elapsed))
    }
}
