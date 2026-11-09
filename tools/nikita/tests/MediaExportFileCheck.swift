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
        // Live Photo export owns both a primary copy and a generated paired
        // MOV; disposing it must remove the output while the input copy remains
        // available until Photos has completed its read.
        let mainFile = CodeGramExportFile(sourcePath: source.path, fileName: "photo.jpg")!
        let pairedInput = CodeGramExportFile(sourcePath: source.path, fileName: "paired.mp4")!
        let pairedOutput = mainFile.url.deletingLastPathComponent().appendingPathComponent("paired.mov")
        try bytes.write(to: pairedOutput)
        mainFile.dispose()
        waitForRemoval(mainFile.url.deletingLastPathComponent())
        precondition(!fm.fileExists(atPath: pairedOutput.path), "Generated paired MOV leaked")
        precondition(fm.fileExists(atPath: pairedInput.url.path), "Primary cleanup removed the paired input before Photos finished")
        let pairedBytes = try Data(contentsOf: pairedInput.url)
        precondition(pairedBytes == bytes)
        pairedInput.dispose()
        waitForRemoval(pairedInput.url.deletingLastPathComponent())
        let original = try Data(contentsOf: source)
        precondition(original == bytes, "Cleanup touched the original received media")
        print("Media export: byte-exact copy, original preservation, safe filename boundaries, missing resource, explicit/idempotent cleanup and cancellation/deinit cleanup and paired-output lifetime passed.")
    }

    static func waitForRemoval(_ url: URL) {
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: url.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(!FileManager.default.fileExists(atPath: url.path), "Temporary export was not removed")
    }
}
