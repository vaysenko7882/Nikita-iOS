import Foundation
import AVFoundation
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import OverlayStatusController
import LegacyMediaPickerUI
import SaveToCameraRoll
import PresentationDataUtils

private func sanitizedFileNameComponent(_ value: String) -> String? {
    let result = (value as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
    if result.isEmpty || result == "." || result == ".." || result.contains("\0") || result.utf8.count > 200 {
        return nil
    }
    return result
}

func saveMediaToFiles(context: AccountContext, fileReference: FileMediaReference, present: @escaping (ViewController, Any?) -> Void) -> Disposable {
    var title: String?
    var performer: String?
    for attribute in fileReference.media.attributes {
        if case let .Audio(_, _, titleValue, performerValue, _) = attribute {
            if let titleValue, !titleValue.isEmpty {
                title = titleValue
            }
            if let performerValue, !performerValue.isEmpty {
                performer = performerValue
            }
        }
    }
    
    let signal = fetchMediaData(context: context, userLocation: .other, mediaReference: fileReference.abstract)
    |> filter { state, _ in
        if case let .data(data) = state { return data.isComplete }
        return false
    }
    |> take(1)
    |> deliverOn(Queue.concurrentDefaultQueue())
    |> map { state, _ -> CodeGramExportFile? in
        guard case let .data(data) = state else { return nil }
        let file = fileReference.media
        let originalName = file.fileName.flatMap(sanitizedFileNameComponent)
        let fileExtension = originalName.flatMap { sanitizedFileNameComponent(($0 as NSString).pathExtension) }
            ?? UTType(mimeType: file.mimeType)?.preferredFilenameExtension ?? (file.isMusic ? "mp3" : "bin")
        var fileName = originalName ?? "media.\(fileExtension)"
        if file.isMusic {
            // Preserve the audio player's artist/title naming, but keep metadata
            // reads and the final export copy off the UI thread.
            var nameComponents: [String] = []
            if let title {
                if let performer, let value = sanitizedFileNameComponent(performer) { nameComponents.append(value) }
                if let value = sanitizedFileNameComponent(title) { nameComponents.append(value) }
            } else {
                let audioAsset = AVURLAsset(url: URL(fileURLWithPath: data.path))
                let metadata = audioAsset.commonMetadata
                if let artist = metadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue,
                    let value = sanitizedFileNameComponent(artist) { nameComponents.append(value) }
                if let title = metadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue,
                    let value = sanitizedFileNameComponent(title) { nameComponents.append(value) }
            }
            if !nameComponents.isEmpty,
                let named = sanitizedFileNameComponent(nameComponents.joined(separator: " – ") + "." + fileExtension) {
                fileName = named
            }
        }
        return CodeGramExportFile(sourcePath: data.path, fileName: fileName)
    }
    
    var cancelImpl: (() -> Void)?
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let progressSignal = Signal<Never, NoError> { subscriber in
        let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
            cancelImpl?()
        }))
        present(controller, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        return ActionDisposable { [weak controller] in
            Queue.mainQueue().async() {
                controller?.dismiss()
            }
        }
    }
    |> runOn(Queue.mainQueue())
    |> delay(0.15, queue: Queue.mainQueue())
    
    let progressDisposable = progressSignal.startStrict()
    
    let disposable = MetaDisposable()
    let exportSignal = signal |> afterDisposed {
        Queue.mainQueue().async {
            progressDisposable.dispose()
        }
    }
    cancelImpl = { [weak disposable] in
        disposable?.set(nil)
    }
    disposable.set((exportSignal
    |> deliverOnMainQueue).startStrict(next: { file in
        guard let file else { return }
        // The picker owns the copy until its file provider has finished reading
        // it. Both completion and cancellation can call dispose safely.
        let controller = legacyICloudFilePicker(theme: presentationData.theme, mode: .export, url: file.url,
            documentTypes: [], forceDarkTheme: false, dismissed: { file.dispose() }, completion: { _ in file.dispose() })
        present(controller, nil)
    }))
    
    return disposable
}
