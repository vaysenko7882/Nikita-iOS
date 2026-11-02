import Foundation
import UIKit
import UniformTypeIdentifiers
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display

/// Export the received bytes through the system sheet (Photos or Files), with
/// no playback/consumption side effect and no re-encoding on the main thread.
public func exportCodeGramDisappearingMedia(context: AccountContext, message: EngineMessage,
    sourceView: UIView, failed: @escaping () -> Void) {
    guard let media = message.media.first(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile }) else {
        failed(); return
    }
    let name: String
    if let file = media as? TelegramMediaFile {
        let fallback = "media." + (UTType(mimeType: file.mimeType)?.preferredFilenameExtension ?? "bin")
        let candidate = ((file.fileName ?? fallback) as NSString).lastPathComponent
        name = candidate.isEmpty || candidate == "." || candidate == ".." || candidate.utf8.count > 200 || candidate.contains("\0") ? fallback : candidate
    } else {
        name = "photo.jpg"
    }
    let reference = AnyMediaReference.message(message: MessageReference(message._asMessage()), media: media)
    var exported = false
    let _ = (fetchMediaData(context: context, userLocation: .peer(message.id.peerId), mediaReference: reference)
    |> filter { state, _ in
        if case let .data(data) = state { return data.isComplete }
        return false
    }
    |> take(1)
    |> deliverOn(Queue.concurrentDefaultQueue())
    |> map { state, _ -> TempBoxFile? in
        guard case let .data(data) = state else { return nil }
        let file = TempBox.shared.file(path: data.path, fileName: name)
        guard FileManager.default.isReadableFile(atPath: file.path) else { TempBox.shared.dispose(file); return nil }
        return file
    }
    |> deliverOnMainQueue
    |> timeout(60.0, queue: .mainQueue(), alternate: .complete())).startStandalone(next: { file in
        guard let file else { return }
        exported = true
        let controller = UIActivityViewController(activityItems: [URL(fileURLWithPath: file.path)], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = sourceView
        controller.popoverPresentationController?.sourceRect = CGRect(x: sourceView.bounds.midX,
            y: sourceView.bounds.maxY - 1, width: 1, height: 1)
        controller.completionWithItemsHandler = { _, _, _, _ in TempBox.shared.dispose(file) }
        context.sharedContext.applicationBindings.presentNativeController(controller)
    }, completed: {
        if !exported { failed() }
    })
}
