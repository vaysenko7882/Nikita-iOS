import Foundation

@main
struct VoiceProcessorCheck {
    static func render(_ input: [Int16], effect: NikitaVoiceEffect, chunks: [Int]) -> [Int16] {
        return render(input, configuration: .preset(effect), chunks: chunks)
    }

    static func render(_ input: [Int16], configuration: NikitaVoiceConfiguration, chunks: [Int]) -> [Int16] {
        let processor = NikitaVoiceProcessor(configuration: configuration)
        var result = input
        var offset = 0
        var index = 0
        result.withUnsafeMutableBufferPointer { buffer in
            while offset < buffer.count {
                let count = min(chunks[index % chunks.count], buffer.count - offset)
                processor.process(buffer.baseAddress!.advanced(by: offset), count: count)
                index += 1
                offset += count
            }
        }
        return result
    }

    static func dominantFrequency(_ input: [Int16]) -> Int {
        let samples = Array(input.suffix(8000)).map(Double.init)
        var strongest = (frequency: 0, power: 0.0)
        for frequency in 100 ... 800 {
            let angle = 2.0 * Double.pi * Double(frequency) / 16000.0
            let coefficient = 2.0 * cos(angle)
            var a = 0.0
            var b = 0.0
            for sample in samples {
                let current = sample + coefficient * a - b
                b = a
                a = current
            }
            let power = a * a + b * b - coefficient * a * b
            if power > strongest.power { strongest = (frequency, power) }
        }
        return strongest.frequency
    }

    static func main() {
        let input = (0 ..< 32000).map { Int16(12000.0 * sin(2.0 * Double.pi * 300.0 * Double($0) / 16000.0)) }
        precondition(render(input, effect: .off, chunks: [960]) == input, "Off must preserve the original PCM")
        for effect in NikitaVoiceEffect.allCases {
            let whole = render(input, effect: effect, chunks: [input.count])
            let chunked = render(input, effect: effect, chunks: [1, 137, 960, 511])
            precondition(whole == chunked, "Audio callbacks must not alter the effect: \(effect)")
            precondition(whole.count == input.count, "Duration changed")
            if effect != .off { precondition(whole != input, "Effect is not applied") }
            if effect == .squeaky || effect == .cartoon || effect == .deep {
                let frequency = dominantFrequency(whole)
                let expected = 300.0 * effect.pitchRatio
                precondition(abs(Double(frequency) - expected) < expected * 0.07, "Pitch mismatch: \(effect), \(frequency)Hz")
                print("\(effect.rawValue): 300 Hz → \(frequency) Hz; chunk invariance and duration passed")
            }
        }
        var dry = NikitaVoiceConfiguration.naturalDeep
        dry.mix = 0
        precondition(render(input, configuration: dry, chunks: [137]) == input, "Dry mix must be bit-identical")
        let presets: [NikitaVoiceConfiguration] = [.naturalDeep, .radio, .clearHigh, .spacious,
            NikitaVoiceConfiguration(pitchSemitones: 12, tone: 1, robotAmount: 1, robotFrequency: 160, echoAmount: 0.6, echoDelayMilliseconds: 400, gainDecibels: 12, mix: 0.73, compression: 1, gate: 0.08)]
        for configuration in presets {
            let whole = render(input, configuration: configuration, chunks: [input.count])
            precondition(whole == render(input, configuration: configuration, chunks: [1, 137, 960, 511]), "Advanced effect changed with callback boundaries")
            precondition(whole.count == input.count && whole != input, "Advanced effect must retain duration and alter audio")
            precondition(render([Int16](repeating: 0, count: 16000), configuration: configuration, chunks: [960]).allSatisfy { $0 == 0 }, "Silence produced nonzero PCM")
            let encoded = try! JSONEncoder().encode(configuration)
            precondition((try! JSONDecoder().decode(NikitaVoiceConfiguration.self, from: encoded)).normalized == configuration, "Preset persistence changed settings")
        }
        let bounded = NikitaVoiceConfiguration(pitchSemitones: .infinity, tone: -.infinity, robotAmount: .nan, robotFrequency: -500, echoAmount: 5, echoDelayMilliseconds: 10000, gainDecibels: .nan, mix: .nan, compression: 10, gate: 2)
        precondition(bounded.pitchSemitones == 0 && bounded.tone == 0 && bounded.robotAmount == 0 && bounded.robotFrequency == 20 && bounded.echoAmount == 0.6 && bounded.echoDelayMilliseconds == 400 && bounded.gainDecibels == 0 && bounded.mix == 1 && bounded.compression == 1 && bounded.gate == 0.08, "Untrusted/nonfinite settings escaped normalization")
        _ = render([Int16.min, Int16.max, 0], configuration: bounded, chunks: [1])
        print("VoiceChanger: legacy pitch, advanced DSP, silence, bounds, persistence, dry mix and chunk invariance passed")
    }
}
