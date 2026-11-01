import Foundation
import SwiftSignalKit
import TelegramCore

/// One request at a time, no disabled/background polling, bounded catch-up and
/// increasing idle/error delays. Optional sync yields to the system's pressure.
final class NikitaArchiveSyncManager {
    private let engine: TelegramEngine
    private let account: String
    private let request = MetaDisposable()
    private var foregroundDisposable: Disposable?
    private var observers: [NSObjectProtocol] = []
    private var timer: SwiftSignalKit.Timer?
    private var inForeground = false
    private var running = false
    private var generation = 0
    private var idleCount = 0
    private var failureCount = 0

    init(engine: TelegramEngine, account: String, inForeground: Signal<Bool, NoError>) {
        self.engine = engine
        self.account = account
        _ = ProcessInfo.processInfo.thermalState
        self.observers.append(NotificationCenter.default.addObserver(forName: NikitaSettingsStore.serverChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.account else { return }
            self.restart()
        })
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.restart() })
        }
        self.foregroundDisposable = (inForeground |> distinctUntilChanged |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else { return }
            self.inForeground = value
            self.restart()
        })
    }

    private var canPoll: Bool {
        return self.inForeground && NikitaSettingsStore.shared.isServerEnabled(account: self.account) && CodeGramEnergyPolicy.current.allowsAutomaticSync
    }
    private func restart() {
        self.generation += 1
        self.timer?.invalidate(); self.timer = nil
        self.request.set(nil); self.running = false
        self.idleCount = 0; self.failureCount = 0
        if self.canPoll { self.poll(remaining: CodeGramEnergyPolicy.current.pageBudget) }
    }
    private func schedule(delay: Double) {
        self.timer?.invalidate(); self.timer = nil
        guard self.canPoll else { return }
        let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.poll(remaining: CodeGramEnergyPolicy.current.pageBudget)
        }, queue: .mainQueue())
        self.timer = timer; timer.start()
    }
    private func poll(remaining: Int) {
        guard self.canPoll, !self.running else { return }
        self.running = true
        let generation = self.generation
        self.request.set((self.engine.messages.synchronizeNikitaArchive() |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.generation == generation else { return }
            self.running = false
            self.failureCount = result.success ? 0 : self.failureCount + 1
            self.idleCount = result.importedCount == 0 && !result.hasMore ? self.idleCount + 1 : 0
            let policy = CodeGramEnergyPolicy.current
            if result.success && result.hasMore && remaining > 1 && self.canPoll {
                Queue.mainQueue().async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.poll(remaining: remaining - 1)
                }
            } else {
                let delay = result.success && result.hasMore ? (policy.usesReducedEffects ? 60.0 : 10.0) : policy.syncDelay(idleCount: self.idleCount, failureCount: self.failureCount)
                self.schedule(delay: delay)
            }
        }, completed: { [weak self] in
            guard let self, self.generation == generation, self.running else { return }
            self.running = false; self.failureCount += 1
            self.schedule(delay: CodeGramEnergyPolicy.current.syncDelay(idleCount: self.idleCount, failureCount: self.failureCount))
        }))
    }
    deinit {
        self.foregroundDisposable?.dispose(); self.request.dispose(); self.timer?.invalidate()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }
}
