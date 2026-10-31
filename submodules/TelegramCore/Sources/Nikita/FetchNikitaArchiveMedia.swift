import Foundation
import CryptoKit
import Postbox
import SwiftSignalKit

private final class NikitaMediaDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "NikitaArchiveMedia")
    private let resource: NikitaArchiveMediaResource
    private let configuration: NikitaServerConfiguration
    private let onNext: (MediaResourceDataFetchResult) -> Void
    private let onError: (MediaResourceDataFetchError) -> Void
    private let onComplete: () -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var subscription: Disposable?
    private var wanted: [(Range<Int64>, MediaBoxFetchPriority)] = []
    private var received: [Range<Int64>] = []
    private var active: Range<Int64> = 0 ..< 0
    private var buffer = Data()
    private var digest = ""
    private var retryDelay: Double?
    private var rejected = false
    private var failures = 0
    private var stopped = false
    private var retry: DispatchWorkItem?

    init(resource: NikitaArchiveMediaResource, configuration: NikitaServerConfiguration,
        onNext: @escaping (MediaResourceDataFetchResult) -> Void,
        onError: @escaping (MediaResourceDataFetchError) -> Void, onComplete: @escaping () -> Void) {
        self.resource = resource
        self.configuration = configuration
        self.onNext = onNext
        self.onError = onError
        self.onComplete = onComplete
        super.init()
    }

    func start(_ intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError>) {
        self.queue.async { [self] in
            guard !self.stopped else { return }
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 1
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = self.queue
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
            self.onNext(.resourceSizeUpdated(self.resource.size ?? 0))
            self.subscription = intervals.start(next: { [weak self] values in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    self.wanted = values.sorted { $0.1.rawValue > $1.1.rawValue }
                    self.advance()
                }
            })
        }
    }

    func cancel() {
        self.queue.async { self.stop() }
    }

    private func stop() {
        guard !self.stopped else { return }
        self.stopped = true
        self.retry?.cancel()
        self.retry = nil
        self.subscription?.dispose()
        self.subscription = nil
        self.task?.cancel()
        self.task = nil
        self.session?.invalidateAndCancel()
        self.session = nil
    }

    private func fail() {
        guard !self.stopped else { return }
        self.onError(.generic)
        self.stop()
    }

    private func advance() {
        guard !self.stopped, self.task == nil, self.retry == nil,
            let total = self.resource.size, let base = self.configuration.baseURL else { return }
        var next: Range<Int64>?
        for (range, _) in self.wanted {
            var lower = max(0, range.lowerBound)
            let upper = min(total, range.upperBound)
            guard lower < upper else { continue }
            for existing in self.received {
                if existing.upperBound <= lower { continue }
                if existing.lowerBound > lower { break }
                lower = existing.upperBound
            }
            if lower < upper {
                let gapEnd = self.received.first(where: { $0.lowerBound > lower })?.lowerBound ?? total
                next = lower ..< min(upper, min(gapEnd, lower + 512 * 1024))
                break
            }
        }
        guard let next, !next.isEmpty else { return }
        self.active = next
        self.buffer = Data()
        self.digest = ""
        self.rejected = false
        self.retryDelay = nil
        var request = URLRequest(url: base.appendingPathComponent("v1/media").appendingPathComponent(self.resource.blobId),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(self.configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue(self.resource.serverId, forHTTPHeaderField: "X-Nikita-Archive-Epoch")
        request.setValue("bytes=\(next.lowerBound)-\(next.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        self.task = self.session?.dataTask(with: request)
        self.task?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !self.stopped, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if response.statusCode == 503 {
            self.retryDelay = min(30, max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "3") ?? 3))
            completionHandler(.cancel)
            return
        }
        let expected = "bytes \(self.active.lowerBound)-\(self.active.upperBound - 1)/\(self.resource.size ?? 0)"
        guard response.statusCode == 206,
            response.value(forHTTPHeaderField: "Content-Range") == expected,
            Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") == Int64(self.active.count),
            response.value(forHTTPHeaderField: "X-Nikita-Archive-Epoch") == self.resource.serverId,
            let digest = response.value(forHTTPHeaderField: "X-Nikita-Range-SHA256"),
            digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            self.rejected = true
            completionHandler(.cancel)
            return
        }
        self.digest = digest
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !self.stopped else { return }
        guard self.buffer.count + data.count <= self.active.count else {
            self.rejected = true
            dataTask.cancel()
            return
        }
        self.buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !self.stopped else { return }
        self.task = nil
        if self.rejected { self.fail(); return }
        if self.retryDelay != nil || error != nil {
            if self.retryDelay == nil { self.failures += 1 }
            guard self.failures <= 5 else { self.fail(); return }
            let delay = self.retryDelay ?? min(30, pow(2, Double(self.failures)))
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.retry = nil
                self.advance()
            }
            self.retry = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        let hash = SHA256.hash(data: self.buffer).map { String(format: "%02x", $0) }.joined()
        guard self.buffer.count == self.active.count, hash == self.digest,
            self.active.lowerBound != 0 || self.active.upperBound != self.resource.size || self.resource.sha256.isEmpty || hash == self.resource.sha256 else {
            self.fail(); return
        }
        self.failures = 0
        self.onNext(.dataPart(resourceOffset: self.active.lowerBound, data: self.buffer,
            range: 0 ..< Int64(self.buffer.count), complete: self.active.upperBound == self.resource.size))
        var merged: [Range<Int64>] = []
        for range in (self.received + [self.active]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        self.received = merged
        self.buffer = Data()
        if merged.count == 1, merged[0].lowerBound == 0, merged[0].upperBound == self.resource.size {
            self.onComplete()
            self.stop()
        } else { self.advance() }
    }
}

func fetchNikitaArchiveMedia(accountId: Int64, resource: NikitaArchiveMediaResource,
    intervals: Signal<[(Range<Int64>, MediaBoxFetchPriority)], NoError>) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> {
    return Signal { subscriber in
        let configuration = NikitaSettingsStore.shared.server(account: String(accountId))
        guard accountId == resource.accountId, resource.isValid, configuration.enabled,
            configuration.baseURL != nil, configuration.hasValidToken else {
            subscriber.putError(.generic)
            return EmptyDisposable
        }
        let download = NikitaMediaDownload(resource: resource, configuration: configuration,
            onNext: subscriber.putNext, onError: subscriber.putError, onComplete: subscriber.putCompletion)
        download.start(intervals)
        return ActionDisposable { download.cancel() }
    }
}
