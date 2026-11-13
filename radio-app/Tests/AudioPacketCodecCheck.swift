import Foundation

@main
private enum AudioPacketCodecCheck {
    static func main() {
        let samples: [Float] = [-1, -0.5, 0, 0.5, 1, .nan, .infinity, -2, 2]
        let encoded = RadioPCM.encode(samples)
        precondition(encoded.count == samples.count * 2)
        precondition(Array(encoded.prefix(2)) == [0, 128], "negative full-scale little endian")
        precondition(Array(encoded[8..<10]) == [255, 127], "positive full-scale little endian")
        let decoded = RadioPCM.decode(encoded)!
        precondition(decoded[0] == -1 && decoded[4] == 1)
        precondition(abs(decoded[1] + 0.5) < 0.0001 && abs(decoded[3] - 0.5) < 0.0001)
        precondition(decoded[5] == 0 && decoded[6] == 0)
        precondition(decoded[7] == -1 && decoded[8] == 1)
        precondition(RadioPCM.decode(Data()) == nil)
        precondition(RadioPCM.decode(Data([1])) == nil)
        precondition(RadioPCM.decode(Data(count: RadioPCM.maximumPacketBytes + 2)) == nil)
        let frame = RadioPCM.encode([Float](repeating: 0.2, count: RadioPCM.framesPerPacket))
        precondition(frame.count == 640)
        precondition(RadioPCM.decode(frame)?.count == 320)
        let shifted = Data(([99] + Array(frame)).dropFirst())
        precondition(RadioPCM.decode(shifted)?.count == 320, "unaligned data safe")
        print("PCM16 live packet codec checks passed")
    }
}
