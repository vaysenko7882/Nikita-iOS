import Foundation

/// Cache masters are never handed to the uploader: it owns and removes its input.
/// All filesystem work is serialized off the main thread.
public final class CodeGramSocialVideoFileCache {
    public struct Metadata: Codable, Equatable {
        public let sourceURL: String
        public let size: Int64
        public let duration: Double
        public let width: Int32
        public let height: Int32
        public init(sourceURL: String, size: Int64, duration: Double, width: Int32, height: Int32) {
            self.sourceURL = sourceURL; self.size = size; self.duration = duration; self.width = width; self.height = height
        }
        public var isValid: Bool {
            guard CodeGramSocialVideoLink.url(in: self.sourceURL)?.absoluteString == self.sourceURL else { return false }
            return self.size > 0 && self.size <= 250 * 1024 * 1024 && self.duration.isFinite && self.duration > 0 && self.duration <= 3600 && self.width > 0 && self.width <= 16384 && self.height > 0 && self.height <= 16384
        }
    }
    private struct Record: Codable { let metadata: Metadata; let filename: String; var accessedAt: Date }
    private let directory: URL
    private let ttl: TimeInterval
    private let maximumBytes: Int64
    private let now: () -> Date
    private let queue = DispatchQueue(label: "CodeGram.videoFileCache", qos: .utility)
    private var records: [String: Record]?
    private var closed = false
    public init(directory: URL, ttl: TimeInterval = 21600, maximumBytes: Int64 = 512 * 1024 * 1024, now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.ttl = ttl; self.maximumBytes = maximumBytes; self.now = now
    }
    private var index: URL { self.directory.appendingPathComponent("index.json") }
    private func load() {
        guard self.records == nil else { return }
        self.records = [:]
        if let data = try? Data(contentsOf: self.index), data.count <= 262144, let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            for (key, record) in decoded where key == record.metadata.sourceURL && record.metadata.isValid && record.filename.range(of: "^[A-Fa-f0-9-]{36}[.]mp4$", options: .regularExpression) != nil {
                self.records?[key] = record
            }
        }
        self.prune()
    }
    private func size(_ url: URL) -> Int64? {
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
    private func prune() {
        let date = self.now()
        var bytes: Int64 = 0
        var count = 0
        for (key, record) in (self.records ?? [:]).sorted(by: { $0.value.accessedAt > $1.value.accessedAt }) {
            let url = self.directory.appendingPathComponent(record.filename)
            if date.timeIntervalSince(record.accessedAt) >= self.ttl || date < record.accessedAt || self.size(url) != record.metadata.size || bytes + record.metadata.size > self.maximumBytes || count >= 20 {
                self.records?.removeValue(forKey: key)
                try? FileManager.default.removeItem(at: url)
            } else {
                bytes += record.metadata.size; count += 1
            }
        }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self.records ?? [:]) { try? data.write(to: self.index, options: .atomic) }
    }
    private func copy(_ source: URL, to destination: URL) -> Bool {
        do { try FileManager.default.linkItem(at: source, to: destination); return true } catch {
            do { try FileManager.default.copyItem(at: source, to: destination); return true } catch { return false }
        }
    }
    public func store(source: URL, metadata: Metadata, completion: @escaping (Bool) -> Void) {
        self.queue.async {
            guard !self.closed, metadata.isValid, self.size(source) == metadata.size else { DispatchQueue.main.async { completion(false) }; return }
            self.load()
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let filename = UUID().uuidString + ".mp4"
            let success = self.copy(source, to: self.directory.appendingPathComponent(filename))
            if success {
                if let previous = self.records?[metadata.sourceURL] { try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(previous.filename)) }
                self.records?[metadata.sourceURL] = Record(metadata: metadata, filename: filename, accessedAt: self.now())
                self.prune(); self.save()
            }
            DispatchQueue.main.async { completion(success) }
        }
    }
    /// A uniquely owned link/copy for exactly one native enqueue operation.
    public func copyForSend(sourceURL: URL, completion: @escaping ((Metadata, URL)?) -> Void) {
        self.queue.async {
            guard !self.closed else { DispatchQueue.main.async { completion(nil) }; return }
            self.load(); self.prune()
            guard var record = self.records?[sourceURL.absoluteString] else { DispatchQueue.main.async { completion(nil) }; return }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-send-\(UUID().uuidString).mp4")
            let success = self.copy(self.directory.appendingPathComponent(record.filename), to: destination)
            if success { record.accessedAt = self.now(); self.records?[sourceURL.absoluteString] = record; self.save() }
            DispatchQueue.main.async { completion(success ? (record.metadata, destination) : nil) }
        }
    }
    public func invalidate() {
        self.queue.async {
            self.closed = true; self.records = [:]
            try? FileManager.default.removeItem(at: self.directory)
        }
    }
}
