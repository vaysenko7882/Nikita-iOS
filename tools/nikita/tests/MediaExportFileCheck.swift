import Foundation

@main enum MediaExportFileCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let bytes = Data((0 ..< 262_144).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        for invalid in ["", ".", "..", "../outside", "/outside", "nul\0name", String(repeating: "x", count: 201)] {
            precondition(CodeGramExportFile(sourcePath: source.path, fileName: invalid) == nil)
        }
        precondition(CodeGramExportFile(sourcePath: root.appendingPathComponent("missing").path, fileName: "missing.ogg") == nil)
        var exported: CodeGramExportFile? = CodeGramExportFile(sourcePath: source.path, fileName: "voice.ogg")
        let url = exported!.url
        precondition(url != source && url.lastPathComponent == "voice.ogg")
        let copied = try Data(contentsOf: url)
        precondition(copied == bytes)
        exported!.dispose(); exported!.dispose(); exported = nil
        waitForRemoval(url.deletingLastPathComponent())
        var automatic: CodeGramExportFile? = CodeGramExportFile(sourcePath: source.path, fileName: "round.mp4")
        let automaticURL = automatic!.url
        automatic = nil
        waitForRemoval(automaticURL.deletingLastPathComponent())
        let original = try Data(contentsOf: source)
        precondition(original == bytes, "Cleanup touched the original received media")
        print("Media export: byte-exact copy, original preservation, safe filename boundaries, missing resource, explicit/idempotent cleanup and cancellation/deinit cleanup passed.")
    }

    static func waitForRemoval(_ url: URL) {
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(!FileManager.default.fileExists(atPath: url.path), "Temporary export was not removed")
    }
}
