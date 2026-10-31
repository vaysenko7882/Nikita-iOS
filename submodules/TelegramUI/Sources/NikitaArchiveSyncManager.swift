import Foundation
import SwiftSignalKit
import TelegramCore

/// One bounded page request at a time. iOS suspension is not used as a polling clock.
final class NikitaArchiveSyncManager {
    private let engine: TelegramEngine
    private let request = MetaDisposable()
    private var foregroundDisposable: Disposable?
    private var settingsObserver: NSObjectProtocol?
    private var timer: SwiftSignalKit.Timer?
    private var inForeground = false
    private var running = false

    init(engine: TelegramEngine, inForeground: Signal<Bool, NoError>) {
        self.engine = engine
        self.settingsObserver = NotificationCenter.default.addObserver(forName: NikitaSettingsStore.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.request.set(nil)
            self.running = false
            self.poll(remaining: 20)
        }
        self.foregroundDisposable = (inForeground |> distinctUntilChanged |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            self.inForeground = value
            self.timer?.invalidate()
            self.timer = nil
            if value {
                let timer = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: { [weak self] in
                    self?.poll(remaining: 20)
                }, queue: .mainQueue())
                self.timer = timer
                timer.start()
                self.poll(remaining: 20)
            } else {
                self.request.set(nil)
                self.running = false
            }
        })
    }

    private func poll(remaining: Int) {
        guard self.inForeground, !self.running else { return }
        self.running = true
        self.request.set((self.engine.messages.synchronizeNikitaArchive() |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else { return }
            self.running = false
            if result.success && result.hasMore && remaining > 1 {
                Queue.mainQueue().async { [weak self] in self?.poll(remaining: remaining - 1) }
            }
        }))
    }

    deinit {
        self.foregroundDisposable?.dispose()
        self.request.dispose()
        self.timer?.invalidate()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }
}
