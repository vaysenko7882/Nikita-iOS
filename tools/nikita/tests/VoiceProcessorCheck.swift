import Foundation

@main
struct VoiceProcessorCheck {
    static func render(_ input: [Int16], effect: NikitaVoiceEffect, chunks: [Int]) -> [Int16] {
        let processor = NikitaVoiceProcessor(effect: effect)
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
        print("VoiceChanger: all PCM checks passed")
    }
}
