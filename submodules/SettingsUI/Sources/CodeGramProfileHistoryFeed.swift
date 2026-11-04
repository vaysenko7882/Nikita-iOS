import Foundation
import UIKit

/// A live, account-bound history reader. Polling is independent of table geometry
/// and pagination; the controller decides when it can safely render the snapshot.
final class CodeGramProfileHistoryFeed {
    typealias Page = [String: Any]
    typealias Fetch = (Int, @escaping (Result<Page, Error>) -> Void) -> (() -> Void)?

    private enum RequestKind: Equatable {
        case reset
        case older
        case latest
        case gap
        var automatic: Bool { self == .latest || self == .gap }
    }

    private let fetch: Fetch
    private let interval: TimeInterval
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var visible = false
    private var generation = 0
    private var cancelRequest: (() -> Void)?
    private var requestKind: RequestKind?
    private var hasLoadedOlderPages = false
    private var reachedHistoryEnd = false
    private var gapCursors: [Int] = []
    private var status: Page = [:]

    private(set) var events: [Page] = []
    private(set) var before = 0
    private(set) var hasMore = false
    private(set) var isLoading = false
    var isUserLoading: Bool { self.isLoading && self.requestKind?.automatic == false }
    var serverId: String? { self.status["server_id"] as? String }
    var snapshot: CodeGramProfileHistorySnapshot { CodeGramProfileHistorySnapshot(events: self.events,serverId: self.serverId) }
    var updated: ((Page, Bool) -> Void)?
    var failed: ((Error, Bool) -> Void)?

    init(interval: TimeInterval = 2, fetch: @escaping Fetch) {
        self.interval = max(0.1, interval)
        self.fetch = fetch
    }

    deinit { self.stop() }

    func setVisible(_ value: Bool) {
        guard self.visible != value else { return }
        self.visible = value
        if value {
            let center = NotificationCenter.default
            self.observers = [
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.resume() },
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.pause() }
            ]
            self.resume()
        } else {
            self.stop()
        }
    }

    func refresh() {
        self.cancel()
        self.request(.reset, before: 0)
    }

    func loadOlder() {
        guard self.hasMore, self.before > 0 else { return }
        if self.isLoading {
            guard self.requestKind?.automatic == true else { return }
            self.cancel()
        }
        self.request(.older, before: self.before)
    }

    func cancel() {
        self.generation += 1
        self.cancelRequest?()
        self.cancelRequest = nil
        self.isLoading = false
        self.requestKind = nil
    }

    private func stop() {
        self.pause()
        self.observers.forEach(NotificationCenter.default.removeObserver)
        self.observers.removeAll()
    }

    private func pause() {
        self.timer?.invalidate()
        self.timer = nil
        self.cancel()
    }

    private func resume() {
        guard self.visible, UIApplication.shared.applicationState == .active else { return }
        self.timer?.invalidate()
        let timer = Timer(timeInterval: self.interval, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        // A table drag uses a tracking run-loop mode. It must not suspend the
        // network reader; rendering can wait until the gesture has settled.
        RunLoop.main.add(timer, forMode: .common)
        self.poll()
    }

    private func poll() {
        guard self.visible, UIApplication.shared.applicationState == .active, !self.isLoading else { return }
        // Always read the head first. Backfilling a large gap must never delay
        // newly published stories behind minutes of older history pages.
        self.request(.latest, before: 0)
    }

    private func request(_ kind: RequestKind, before: Int) {
        guard !self.isLoading else { return }
        self.isLoading = true
        self.requestKind = kind
        self.generation += 1
        let generation = self.generation
        self.cancelRequest = self.fetch(before) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.cancelRequest = nil
                self.isLoading = false
                self.requestKind = nil
                switch result {
                case let .failure(error): self.failed?(error, kind.automatic)
                case let .success(page): self.received(page, kind: kind, before: before)
                }
            }
        }
    }

    private static func sequence(_ event: Page) -> Int64? { (event["seq"] as? NSNumber)?.int64Value }

    private func received(_ page: Page, kind: RequestKind, before requestBefore: Int) {
        let oldEvents = self.events
        let oldStatus = self.status
        let oldBefore = self.before
        let oldMore = self.hasMore
        let values = page["events"] as? [Page] ?? []
        let cursor = (page["next_before"] as? NSNumber)?.intValue ?? 0
        let more = page["has_more"] as? Bool ?? false
        self.status = page.filter { !["events", "next_before", "has_more"].contains($0.key) }
        let oldEpoch = oldStatus["server_id"] as? String
        let epoch = self.status["server_id"] as? String
        let archiveChanged = oldEpoch != nil && epoch != nil && oldEpoch != epoch
        if kind == .reset || archiveChanged || oldEvents.isEmpty {
            self.events = values
            self.before = cursor
            self.hasMore = more
            self.hasLoadedOlderPages = false
            self.reachedHistoryEnd = !more
            self.gapCursors.removeAll()
        } else {
            var merged = Dictionary(uniqueKeysWithValues: self.events.compactMap { event -> (Int64, Page)? in
                guard let seq = Self.sequence(event) else { return nil }
                return (seq, event)
            })
            let existing = Set(merged.keys)
            for event in values { if let seq = Self.sequence(event) { merged[seq] = event } }
            self.events = merged.sorted { $0.key > $1.key }.map(\.value)
            if kind == .older {
                self.before = cursor
                self.hasMore = more
                self.hasLoadedOlderPages = true
                self.reachedHistoryEnd = !more
            } else if !self.hasLoadedOlderPages && kind == .latest {
                self.before = Self.sequence(self.events.last ?? [:]).map(Int.init) ?? cursor
                self.hasMore = more
            }
            let incoming = Set(values.compactMap(Self.sequence))
            let overlaps = !existing.isDisjoint(with: incoming)
            if kind == .latest, !oldEvents.isEmpty, !overlaps, more, cursor > 0 {
                if !self.gapCursors.contains(cursor) { self.gapCursors.append(cursor) }
            } else if kind == .gap {
                self.gapCursors.removeAll { $0 == requestBefore }
                if !overlaps && more && cursor > 0 && cursor < requestBefore, !self.gapCursors.contains(cursor) {
                    self.gapCursors.append(cursor)
                }
            }
            if kind.automatic && !self.hasLoadedOlderPages {
                // Apply the live bound to backfill as well as head responses.
                // Once an old gap is beyond that retained window, ordinary
                // pagination can retrieve it if the reader asks for it.
                if !more { self.reachedHistoryEnd = true }
                if self.events.count > 300 { self.reachedHistoryEnd = false }
                self.events = Array(self.events.prefix(300))
                self.before = Self.sequence(self.events.last ?? [:]).map(Int.init) ?? cursor
                self.hasMore = !self.reachedHistoryEnd
                if self.events.count == 300 { self.gapCursors.removeAll { $0 <= self.before } }
            }
        }
        let changed = !(oldEvents as NSArray).isEqual(self.events as NSArray) ||
            !(oldStatus as NSDictionary).isEqual(self.status as NSDictionary) || oldBefore != self.before || oldMore != self.hasMore
        if changed || !kind.automatic { self.updated?(page, kind.automatic) }
        // One extra page per live cycle, after the fresh head has been applied.
        // The transport remains bounded to one in-flight request.
        if kind == .latest, self.visible, UIApplication.shared.applicationState == .active, !self.isLoading,
            let cursor = self.gapCursors.first {
            self.request(.gap, before: cursor)
        }
    }
}

/// The rows on screen and their archive identity are one immutable value.
/// A new HTTP page can arrive while rendering is deferred for a drag gesture;
/// selecting an old row must not attach the new archive's identity to it.
struct CodeGramProfileHistorySnapshot {
    let events: [[String: Any]]
    let serverId: String?

    init(events: [[String: Any]] = [], serverId: String? = nil) {
        self.events = events; self.serverId = serverId
    }

    func event(at row: Int, currentServerId: String?) -> [String: Any]? {
        guard let serverId, !serverId.isEmpty, serverId == currentServerId,
            self.events.indices.contains(row) else { return nil }
        return self.events[row]
    }
}

/// Keep an older record at the same screen position when new records are
/// inserted above it. At the newest record keep the offset instead, so the new
/// first row becomes visible rather than being hidden by anchor compensation.
struct CodeGramProfileHistoryScrollAnchor {
    private let offset: CGPoint
    private let sequence: Int64?
    private let relativeY: CGFloat?
    private let section: Int

    init(table: UITableView, events: [[String: Any]], section: Int = 1) {
        self.offset = table.contentOffset
        self.section = section
        let path = table.indexPathsForVisibleRows?.sorted().first(where: { $0.section == section && $0.row < events.count })
        if let path, path.row > 0, let sequence = events[path.row]["seq"] as? NSNumber {
            self.sequence = sequence.int64Value
            self.relativeY = table.rectForRow(at: path).minY - table.contentOffset.y
        } else {
            self.sequence = nil
            self.relativeY = nil
        }
    }

    func restore(table: UITableView, events: [[String: Any]], resetToTop: Bool = false) {
        if resetToTop {
            table.setContentOffset(CGPoint(x: 0,y: -table.contentInset.top),animated: false)
        } else if let sequence, let relativeY, let row = events.firstIndex(where: { ($0["seq"] as? NSNumber)?.int64Value == sequence }) {
            // Resolve the target's real self-sizing height before using its
            // rectangle; a newly inserted prefix may still be estimated.
            table.scrollToRow(at: IndexPath(row: row,section: self.section),at: .top,animated: false)
            table.layoutIfNeeded()
            let y = table.rectForRow(at: IndexPath(row: row,section: self.section)).minY - relativeY
            table.setContentOffset(CGPoint(x: self.offset.x,y: y),animated: false)
            table.layoutIfNeeded()
        } else {
            table.setContentOffset(self.offset,animated: false)
        }
    }
}
