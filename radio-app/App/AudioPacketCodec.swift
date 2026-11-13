import Foundation

/// Wire audio is streamed PCM16 little-endian, mono, 16 kHz. A normal packet is
/// 20 ms (320 samples / 640 bytes), not a completed voice recording.
enum RadioPCM {
    static let sampleRate: Double = 16_000
    static let framesPerPacket = 320
    static let bytesPerPacket = framesPerPacket * 2
    static let maximumPacketBytes = bytesPerPacket * 5

    static func encode(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for (index, source) in samples.enumerated() {
                let value = source.isFinite ? min(1, max(-1, source)) : 0
                let scaled = (value * (value < 0 ? 32_768 : 32_767)).rounded()
                let bits = UInt16(bitPattern: Int16(scaled))
                bytes[index * 2] = UInt8(truncatingIfNeeded: bits)
                bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: 2),
              data.count <= maximumPacketBytes else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (0..<(bytes.count / 2)).map { index in
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                let value = Int16(bitPattern: bits)
                return Float(value) / (value < 0 ? 32_768 : 32_767)
            }
        }
    }
}
