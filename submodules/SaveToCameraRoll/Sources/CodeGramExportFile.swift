import Foundation

/// Owns only an export copy, never the MediaBox resource. Copying runs on the
/// caller's worker queue; unlinking always runs on a utility queue.
public final class CodeGramExportFile {
    public let url: URL
    private let lock = NSLock()
    private var directory: URL?

    public init?(sourcePath: String, fileName: String) {
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
            (fileName as NSString).lastPathComponent == fileName,
            !fileName.contains("\0"), fileName.utf8.count <= 200 else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codegram-media-export-" + UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        self.directory = directory
        self.url = url
    }

    public func dispose() {
        self.lock.lock()
        let directory = self.directory
        self.directory = nil
        self.lock.unlock()
        guard let directory else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit { self.dispose() }
}
