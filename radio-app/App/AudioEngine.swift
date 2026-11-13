import AVFoundation
import Combine
import Foundation

@MainActor
final class RadioAudio: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published var error: String?

    var onPacket: ((Data) -> Void)?

    private let worker = RadioAudioWorker()
    private var wantsToTalk = false
    private var pressGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        worker.onPacket = { [weak self] data, generation, amplitude in
            Task { @MainActor [weak self] in
                guard let self, self.wantsToTalk, self.pressGeneration == generation else { return }
                self.level = amplitude
                self.onPacket?(data)
            }
        }
        worker.onStarted = { [weak self] generation in
            Task { @MainActor [weak self] in
                guard let self, self.wantsToTalk, self.pressGeneration == generation else { return }
                self.isRecording = true
            }
        }
        worker.onError = { [weak self] message, generation in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let generation, self.pressGeneration != generation { return }
                self.wantsToTalk = false
                self.isRecording = false
                self.level = 0
                self.error = message
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.stopAll() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.stopAll()
                self?.error = "Аудиоустройство отключено. Нажмите аватар ещё раз."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopAll() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// With activate:false, PushToTalk must activate the session before capture
    /// or playback. Ordinary foreground/nearby mode uses the default true.
    func prepareSession(activate: Bool = true) {
        error = nil
        worker.configure(activate: activate)
    }

    func startTalking() {
        guard !wantsToTalk else { return }
        wantsToTalk = true
        pressGeneration &+= 1
        let generation = pressGeneration
        error = nil
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            worker.startCapture(generation: generation)
        case .denied:
            wantsToTalk = false
            error = "Разрешите доступ к микрофону в настройках iPhone."
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsToTalk, self.pressGeneration == generation else { return }
                    if granted { self.worker.startCapture(generation: generation) }
                    else {
                        self.wantsToTalk = false
                        self.error = "Без доступа к микрофону передавать голос нельзя."
                    }
                }
            }
        @unknown default:
            wantsToTalk = false
            error = "Не удалось проверить доступ к микрофону."
        }
    }

    func stopTalking() {
        wantsToTalk = false
        pressGeneration &+= 1
        isRecording = false
        level = 0
        worker.stopCapture()
    }

    func receive(_ data: Data) {
        worker.receive(data)
    }

    func stopAll() {
        stopTalking()
        worker.stopAll()
    }
}

/// Owns audio nodes and converter on one queue. The tap only copies a bounded
/// number of input buffers; resampling and network packet creation happen here.
private final class RadioAudioWorker: @unchecked Sendable {
    var onPacket: ((Data, UInt64, Float) -> Void)?
    var onStarted: ((UInt64) -> Void)?
    var onError: ((String, UInt64?) -> Void)?

    private let queue = DispatchQueue(label: "app.radio.audio", qos: .userInteractive)
    private let captureLock = NSLock()
    private var captureGeneration: UInt64?
    private var pendingCaptureBuffers = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var systemOwnsSession = false
    private var sessionActive = false
    private var pendingSamples: [Float] = []
    private var scheduledBuffers = 0
    private var playbackGeneration: UInt64 = 0
    private var idleGeneration: UInt64 = 0
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: RadioPCM.sampleRate,
                                           channels: 1, interleaved: false)!

    deinit {
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        engine?.stop()
    }

    func configure(activate: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.systemOwnsSession = !activate
            do {
                try self.configureSession(activate: activate)
                self.scheduleIdleStop()
            }
            catch { self.onError?("Не удалось подготовить звук: \(error.localizedDescription)", nil) }
        }
    }

    private func configureSession(activate: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        if activate && !sessionActive {
            try session.setActive(true)
            sessionActive = true
        }
    }

    private func ensureEngine() throws -> AVAudioEngine {
        if !systemOwnsSession { try configureSession(activate: true) }
        if let engine {
            if !engine.isRunning { try engine.start() }
            return engine
        }
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: wireFormat)
        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
        player = newPlayer
        return newEngine
    }

    func startCapture(generation: UInt64) {
        captureLock.lock()
        captureGeneration = generation
        captureLock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrentCapture(generation) else { return }
            do {
                let engine = try self.ensureEngine()
                if self.tapInstalled { engine.inputNode.removeTap(onBus: 0); self.tapInstalled = false }
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0,
                      let converter = AVAudioConverter(from: format, to: self.wireFormat) else {
                    throw NSError(domain: "RadioAudio", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Микрофон сейчас недоступен."])
                }
                converter.primeMethod = .none
                self.converter = converter
                self.pendingSamples.removeAll(keepingCapacity: true)
                let size = AVAudioFrameCount(max(256, format.sampleRate * 0.02))
                input.installTap(onBus: 0, bufferSize: size, format: format) { [weak self] buffer, _ in
                    self?.capture(buffer, generation: generation)
                }
                self.tapInstalled = true
                guard self.isCurrentCapture(generation) else { self.endCapture(); return }
                self.idleGeneration &+= 1
                self.onStarted?(generation)
            } catch {
                self.endCapture()
                self.clearCaptureRequest(generation)
                self.scheduleIdleStop()
                self.onError?("Не удалось включить микрофон: \(error.localizedDescription)", generation)
            }
        }
    }

    private func isCurrentCapture(_ generation: UInt64) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        return captureGeneration == generation
    }

    private func capture(_ input: AVAudioPCMBuffer, generation: UInt64) {
        guard input.frameLength > 0 else { return }
        captureLock.lock()
        guard captureGeneration == generation, pendingCaptureBuffers < 4 else {
            captureLock.unlock(); return
        }
        pendingCaptureBuffers += 1
        captureLock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            captureLock.lock(); pendingCaptureBuffers -= 1; captureLock.unlock(); return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            if let from = source[index].mData, let to = destination[index].mData {
                memcpy(to, from, min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize)))
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.captureLock.lock()
                self.pendingCaptureBuffers -= 1
                self.captureLock.unlock()
            }
            guard self.isCurrentCapture(generation), let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * RadioPCM.sampleRate / copy.format.sampleRate) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.wireFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var failure: NSError?
            let status = converter.convert(to: converted, error: &failure) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return copy
            }
            if status == .error {
                self.endCapture()
                self.clearCaptureRequest(generation)
                self.scheduleIdleStop()
                self.onError?("Ошибка обработки микрофона: \(failure?.localizedDescription ?? "повторите передачу")", generation)
                return
            }
            guard let samples = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            self.pendingSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
            while self.pendingSamples.count >= RadioPCM.framesPerPacket {
                let frame = Array(self.pendingSamples.prefix(RadioPCM.framesPerPacket))
                self.pendingSamples.removeFirst(RadioPCM.framesPerPacket)
                let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
                self.onPacket?(RadioPCM.encode(frame), generation, min(1, rms * 5))
            }
        }
    }

    func stopCapture() {
        captureLock.lock(); captureGeneration = nil; captureLock.unlock()
        queue.async { [weak self] in
            self?.endCapture()
            self?.scheduleIdleStop()
        }
    }

    private func clearCaptureRequest(_ generation: UInt64) {
        captureLock.lock()
        if captureGeneration == generation { captureGeneration = nil }
        captureLock.unlock()
    }

    private func endCapture() {
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        converter = nil
        pendingSamples.removeAll(keepingCapacity: true)
    }

    func receive(_ data: Data) {
        guard let samples = RadioPCM.decode(data) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.captureLock.lock()
            let transmitting = self.captureGeneration != nil
            self.captureLock.unlock()
            guard !transmitting else { return } // Half-duplex, matching the radio UI.
            do {
                _ = try self.ensureEngine()
                guard let player = self.player,
                      let buffer = AVAudioPCMBuffer(pcmFormat: self.wireFormat,
                                                   frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { return }
                if self.scheduledBuffers >= 10 {
                    player.stop()
                    self.playbackGeneration &+= 1
                    self.scheduledBuffers = 0 // Drop stale audio rather than grow delay.
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                for index in samples.indices { channel[index] = samples[index] }
                self.scheduledBuffers += 1
                let generation = self.playbackGeneration
                player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.playbackGeneration == generation else { return }
                        self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                    }
                }
                if !player.isPlaying {
                    if self.scheduledBuffers >= 3 { player.play() }
                    else {
                        self.queue.asyncAfter(deadline: .now() + 0.055) { [weak self] in
                            guard let self, self.playbackGeneration == generation,
                                  self.scheduledBuffers > 0, self.engine?.isRunning == true,
                                  let player = self.player, !player.isPlaying else { return }
                            player.play()
                        }
                    }
                }
                self.scheduleIdleStop()
            } catch {
                self.scheduleIdleStop()
                self.onError?("Не удалось воспроизвести голос: \(error.localizedDescription)", nil)
            }
        }
    }

    private func scheduleIdleStop() {
        idleGeneration &+= 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.idleGeneration == generation, self.scheduledBuffers == 0 else { return }
            self.captureLock.lock()
            let capturing = self.captureGeneration != nil
            self.captureLock.unlock()
            guard !capturing else { return }
            self.player?.stop()
            self.engine?.stop()
            if self.sessionActive && !self.systemOwnsSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.sessionActive = false
            }
        }
    }

    func stopAll() {
        captureLock.lock(); captureGeneration = nil; captureLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.endCapture()
            self.idleGeneration &+= 1
            self.playbackGeneration &+= 1
            self.scheduledBuffers = 0
            self.player?.stop()
            self.engine?.stop()
            self.engine = nil
            self.player = nil
            if self.sessionActive && !self.systemOwnsSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            self.sessionActive = false
        }
    }
}
