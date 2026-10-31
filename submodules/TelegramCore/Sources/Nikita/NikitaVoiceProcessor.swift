import Foundation

public enum NikitaVoiceEffect: String, CaseIterable {
    case off
    case squeaky
    case cartoon
    case deep
    case robot

    public var title: String {
        switch self {
        case .off: return "Обычный голос"
        case .squeaky: return "Писклявый"
        case .cartoon: return "Мультяшный"
        case .deep: return "Низкий"
        case .robot: return "Робот"
        }
    }

    var pitchRatio: Double {
        switch self {
        case .squeaky: return 1.65
        case .cartoon: return 2.0
        case .deep: return 0.68
        case .off, .robot: return 1.0
        }
    }
}

/// Streaming, mono PCM16 at 16 kHz. Two cross-faded delay taps shift pitch
/// without changing the number of samples or the duration of a voice message.
/// All mutable state belongs to one recorder and stays on its serial queue.
public final class NikitaVoiceProcessor {
    public let effect: NikitaVoiceEffect
    private var ring = [Double](repeating: 0.0, count: 4096)
    private var writeIndex: Int = 0
    private var phase: Double = 0.0
    private var oscillatorPhase: Double = 0.0
    private let window: Double = 1024.0

    public init(effect: NikitaVoiceEffect) {
        self.effect = effect
    }

    private func delayed(_ delay: Double) -> Double {
        let position = Double(self.writeIndex) - delay
        let lower = Int(floor(position))
        let fraction = position - Double(lower)
        let a = self.ring[lower & 4095]
        let b = self.ring[(lower + 1) & 4095]
        return a + (b - a) * fraction
    }

    public func process(_ samples: UnsafeMutablePointer<Int16>, count: Int) {
        guard self.effect != .off, count > 0 else {
            return
        }
        for index in 0 ..< count {
            let input = Double(samples[index])
            let output: Double
            if self.effect == .robot {
                // Ring modulation: an effect, with no voice cloning or network request.
                output = input * (0.35 + 0.65 * sin(self.oscillatorPhase))
                self.oscillatorPhase += 2.0 * Double.pi * 70.0 / 16000.0
                if self.oscillatorPhase >= 2.0 * Double.pi {
                    self.oscillatorPhase -= 2.0 * Double.pi
                }
            } else {
                self.ring[self.writeIndex] = input
                let otherPhase = self.phase < 0.5 ? self.phase + 0.5 : self.phase - 0.5
                let weight = 0.5 - 0.5 * cos(2.0 * Double.pi * self.phase)
                output = self.delayed(16.0 + self.phase * self.window) * weight
                    + self.delayed(16.0 + otherPhase * self.window) * (1.0 - weight)
                self.writeIndex = (self.writeIndex + 1) & 4095
                self.phase += (1.0 - self.effect.pitchRatio) / self.window
                self.phase -= floor(self.phase)
            }
            samples[index] = Int16(max(Double(Int16.min), min(Double(Int16.max), output.rounded())))
        }
    }
}
