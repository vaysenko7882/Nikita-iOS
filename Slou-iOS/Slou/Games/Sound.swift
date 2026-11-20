import AVFoundation

/// Звуки игр: 70 коротких эффектов, синтезированных специально для «слоу» и лежащих в приложении.
/// Каждый звук держит до четырёх плееров, чтобы частые удары не обрывали друг друга.
final class Sound {
    static let shared = Sound()

    private var data: [String: Data] = [:]
    private var pools: [String: [AVAudioPlayer]] = [:]
    private var loops: [String: AVAudioPlayer] = [:]
    private var warmed = false
    var master: Float = 0.85

    init() {
        for dir in [nil, "Sounds"] as [String?] {
            for url in Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: dir) ?? [] {
                let name = url.deletingPathExtension().lastPathComponent
                if data[name] == nil, let bytes = try? Data(contentsOf: url) { data[name] = bytes }
            }
        }
    }

    /// Готовим по одному плееру на звук заранее, пока на экране «Подключаемся»
    func warm() {
        guard !warmed else { return }
        warmed = true
        for name in data.keys where pools[name] == nil {
            if let p = make(name) { pools[name] = [p] }
        }
    }

    private func make(_ name: String) -> AVAudioPlayer? {
        guard let bytes = data[name], let p = try? AVAudioPlayer(data: bytes) else { return nil }
        p.enableRate = true
        p.prepareToPlay()
        return p
    }

    func play(_ name: String, volume: Float = 1, rate: Float = 1) {
        var pool = pools[name] ?? []
        var player = pool.first { !$0.isPlaying }
        if player == nil {
            if pool.count < 4, let p = make(name) {
                pool.append(p)
                pools[name] = pool
                player = p
            } else if let oldest = pool.first {
                oldest.stop()
                pool.removeFirst()
                pool.append(oldest)
                pools[name] = pool
                player = oldest
            }
        }
        guard let p = player else { return }
        p.currentTime = 0
        p.volume = max(0, min(1, volume * master))
        p.rate = max(0.5, min(2, rate))
        p.play()
    }

    /// Бесконечный звук (мотор в гонке). Скорость меняет высоту
    func loop(_ name: String, volume: Float = 0.5) {
        let p = loops[name] ?? make(name)
        guard let p else { return }
        loops[name] = p
        p.numberOfLoops = -1
        p.volume = volume * master
        if !p.isPlaying { p.currentTime = 0; p.play() }
    }

    func tune(_ name: String, rate: Float, volume: Float? = nil) {
        guard let p = loops[name] else { return }
        p.rate = max(0.5, min(2, rate))
        if let volume { p.volume = volume * master }
    }

    func stopLoop(_ name: String) {
        loops[name]?.stop()
    }

    func stopAllLoops() {
        for p in loops.values { p.stop() }
    }
}

/// Короткие имена для игр
@inline(__always) func sfx(_ name: String, _ volume: Float = 1, rate: Float = 1) {
    Sound.shared.play(name, volume: volume, rate: rate)
}

@inline(__always) func buzz(_ kind: String) {
    Haptics.shared.play(kind)
}
