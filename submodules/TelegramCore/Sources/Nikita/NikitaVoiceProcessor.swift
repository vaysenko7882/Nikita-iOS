import Foundation

public enum NikitaVoiceEffect: String, CaseIterable {
    case off, squeaky, cartoon, deep, robot

    public var title: String {
        switch self {
        case .off: return "Обычный голос"
        case .squeaky: return "Писклявый"
        case .cartoon: return "Мультяшный"
        case .deep: return "Глубокий"
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

public struct NikitaVoiceConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var pitchSemitones: Double
    public var tone: Double
    public var robotAmount: Double
    public var robotFrequency: Double
    public var echoAmount: Double
    public var echoDelayMilliseconds: Double
    public var gainDecibels: Double
    public var mix: Double
    public var compression: Double
    public var gate: Double

    public init(enabled: Bool = true, pitchSemitones: Double = 0, tone: Double = 0,
        robotAmount: Double = 0, robotFrequency: Double = 70, echoAmount: Double = 0,
        echoDelayMilliseconds: Double = 160, gainDecibels: Double = 0, mix: Double = 1,
        compression: Double = 0, gate: Double = 0) {
        func bounded(_ value: Double, _ lower: Double, _ upper: Double, _ fallback: Double) -> Double {
            return value.isFinite ? min(upper, max(lower, value)) : fallback
        }
        self.enabled = enabled
        self.pitchSemitones = bounded(pitchSemitones, -12, 12, 0)
        self.tone = bounded(tone, -1, 1, 0)
        self.robotAmount = bounded(robotAmount, 0, 1, 0)
        self.robotFrequency = bounded(robotFrequency, 20, 160, 70)
        self.echoAmount = bounded(echoAmount, 0, 0.6, 0)
        self.echoDelayMilliseconds = bounded(echoDelayMilliseconds, 20, 400, 160)
        self.gainDecibels = bounded(gainDecibels, -12, 12, 0)
        self.mix = bounded(mix, 0, 1, 1)
        self.compression = bounded(compression, 0, 1, 0)
        self.gate = bounded(gate, 0, 0.08, 0)
    }

    public var normalized: NikitaVoiceConfiguration {
        return NikitaVoiceConfiguration(enabled: self.enabled, pitchSemitones: self.pitchSemitones,
            tone: self.tone, robotAmount: self.robotAmount, robotFrequency: self.robotFrequency,
            echoAmount: self.echoAmount, echoDelayMilliseconds: self.echoDelayMilliseconds,
            gainDecibels: self.gainDecibels, mix: self.mix, compression: self.compression, gate: self.gate)
    }

    public static func preset(_ effect: NikitaVoiceEffect) -> NikitaVoiceConfiguration {
        return NikitaVoiceConfiguration(enabled: effect != .off,
            pitchSemitones: 12 * log2(effect.pitchRatio), robotAmount: effect == .robot ? 1 : 0)
    }

    public static let naturalDeep = NikitaVoiceConfiguration(pitchSemitones: -4.5, tone: -0.35, gainDecibels: 1, compression: 0.18)
    public static let radio = NikitaVoiceConfiguration(pitchSemitones: -1.5, tone: -0.15, gainDecibels: 2, compression: 0.45)
    public static let clearHigh = NikitaVoiceConfiguration(pitchSemitones: 4, tone: 0.2, compression: 0.1)
    public static let spacious = NikitaVoiceConfiguration(echoAmount: 0.25, echoDelayMilliseconds: 180)
}

public struct CodeGramVoicePreset: Codable, Equatable {
    public var id: String
    public var title: String
    public var configuration: NikitaVoiceConfiguration

    public init(id: String = UUID().uuidString, title: String, configuration: NikitaVoiceConfiguration) {
        self.id = id
        self.title = String(title.prefix(40))
        self.configuration = configuration.normalized
    }
}

/// A recorder owns one immutable configuration and serial PCM state. Effects
/// preserve sample count, remain independent of callback sizes and use no network.
public final class NikitaVoiceProcessor {
    public let effect: NikitaVoiceEffect
    public let configuration: NikitaVoiceConfiguration
    private var ring = [Double](repeating: 0, count: 4096)
    private var echo = [Double](repeating: 0, count: 8192)
    private var writeIndex = 0
    private var echoIndex = 0
    private var phase = 0.0
    private var oscillatorPhase = 0.0
    private var low = 0.0
    private var high = 0.0
    private var gateGain = 1.0
    private let window = 1024.0
    private let ratio: Double
    private let gain: Double
    private let echoDelay: Int

    public convenience init(effect: NikitaVoiceEffect) {
        self.init(configuration: .preset(effect), legacyEffect: effect)
    }

    public init(configuration: NikitaVoiceConfiguration, legacyEffect: NikitaVoiceEffect = .off) {
        let configuration = configuration.normalized
        self.configuration = configuration
        self.effect = legacyEffect
        self.ratio = pow(2, configuration.pitchSemitones / 12)
        self.gain = pow(10, configuration.gainDecibels / 20)
        self.echoDelay = Int(configuration.echoDelayMilliseconds * 16)
    }

    private func delayed(_ delay: Double) -> Double {
        let position = Double(self.writeIndex) - delay
        let lower = Int(floor(position))
        let fraction = position - Double(lower)
        return self.ring[lower & 4095] + (self.ring[(lower + 1) & 4095] - self.ring[lower & 4095]) * fraction
    }

    public func process(_ samples: UnsafeMutablePointer<Int16>, count: Int) {
        let config = self.configuration
        guard config.enabled, config.mix > 0, count > 0 else { return }
        for index in 0 ..< count {
            let input = Double(samples[index])
            var output = input
            if abs(config.pitchSemitones) > 0.0001 {
                self.ring[self.writeIndex] = input
                let otherPhase = self.phase < 0.5 ? self.phase + 0.5 : self.phase - 0.5
                let weight = 0.5 - 0.5 * cos(2 * Double.pi * self.phase)
                output = self.delayed(16 + self.phase * self.window) * weight
                    + self.delayed(16 + otherPhase * self.window) * (1 - weight)
                self.writeIndex = (self.writeIndex + 1) & 4095
                self.phase += (1 - self.ratio) / self.window
                self.phase -= floor(self.phase)
            }
            if config.tone != 0 {
                self.low += 0.07 * (output - self.low)
                self.high += 0.5 * (output - self.high)
                if config.tone < 0 {
                    output += -config.tone * (0.8 * self.low - 0.5 * (output - self.high))
                } else {
                    output += config.tone * (0.8 * (output - self.high) - 0.3 * self.low)
                }
            }
            if config.robotAmount > 0 {
                output *= 1 - config.robotAmount + config.robotAmount * (0.35 + 0.65 * sin(self.oscillatorPhase))
                self.oscillatorPhase += 2 * Double.pi * config.robotFrequency / 16000
                if self.oscillatorPhase >= 2 * Double.pi { self.oscillatorPhase -= 2 * Double.pi }
            }
            if config.echoAmount > 0 {
                let previous = self.echo[(self.echoIndex - self.echoDelay) & 8191]
                self.echo[self.echoIndex] = output + previous * 0.15
                self.echoIndex = (self.echoIndex + 1) & 8191
                output = output * (1 - config.echoAmount * 0.25) + previous * config.echoAmount
            }
            if config.gate > 0 {
                let target = abs(input) < config.gate * 32768 ? 0.0 : 1.0
                self.gateGain += (target - self.gateGain) * (target > self.gateGain ? 0.05 : 0.002)
                output *= self.gateGain
            }
            output *= self.gain
            if config.compression > 0 {
                let drive = 1 + 3 * config.compression
                output = 32767 * tanh(output / 32767 * drive) / tanh(drive)
            }
            output = input * (1 - config.mix) + output * config.mix
            samples[index] = Int16(max(Double(Int16.min), min(Double(Int16.max), output.rounded())))
        }
    }
}
