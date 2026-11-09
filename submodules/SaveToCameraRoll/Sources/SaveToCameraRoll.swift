import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import Photos
import AVFoundation
import ImageIO
import Display
import UniformTypeIdentifiers
import DeviceAccess
import AccountContext
import LegacyComponents

public enum FetchMediaDataState {
    case progress(Float)
    case data(EngineMediaResource.ResourceData)
}

public func fetchMediaData(context: AccountContext, userLocation: MediaResourceUserLocation, customUserContentType: MediaResourceUserContentType? = nil, mediaReference: AnyMediaReference, forceVideo: Bool = false) -> Signal<(FetchMediaDataState, Bool), NoError> {
    var resource: TelegramMediaResource?
    var isImage = true
    var fileExtension: String?
    var userContentType: MediaResourceUserContentType = .other
    if let image = mediaReference.media as? TelegramMediaImage {
        userContentType = .image
        if let video = image.videoRepresentations.last, forceVideo {
            resource = video.resource
            isImage = false
        } else if let representation = largestImageRepresentation(image.representations) {
            resource = representation.resource
        }
    } else if let file = mediaReference.media as? TelegramMediaFile {
        userContentType = MediaResourceUserContentType(file: file)
        resource = file.resource
        if file.isVideo || file.mimeType.hasPrefix("video/") {
            isImage = false
        }
        let maybeExtension = ((file.fileName ?? "") as NSString).pathExtension
        if !maybeExtension.isEmpty {
            fileExtension = maybeExtension
        }
    } else if let webpage = mediaReference.media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
        if let file = content.file {
            resource = file.resource
            if file.isVideo {
                isImage = false
            }
        } else if let image = content.image {
            if let representation = largestImageRepresentation(image.representations) {
                resource = representation.resource
            }
        }
    }
    if let customUserContentType {
        userContentType = customUserContentType
    }

    if let resource = resource {
        let engineResource = EngineMediaResource(resource)
        let fetchedData: Signal<FetchMediaDataState, NoError> = Signal { subscriber in
            let fetched = context.engine.resources.fetch(
                reference: mediaReference.resourceReference(resource),
                userLocation: userLocation,
                userContentType: userContentType,
                reportResultStatus: true
            ).start(error: { _ in
                subscriber.putCompletion()
            })
            let status = context.engine.resources.status(resource: engineResource).start(next: { status in
                switch status {
                    case .Local:
                        subscriber.putNext(.progress(1.0))
                    case .Remote:
                        subscriber.putNext(.progress(0.0))
                    case let .Fetching(_, progress):
                        subscriber.putNext(.progress(progress))
                    case let .Paused(progress):
                        subscriber.putNext(.progress(progress))
                }
            })
            let data = context.engine.resources.data(
                resource: engineResource,
                pathExtension: fileExtension,
                waitUntilFetchStatus: true
            ).start(next: { next in
                subscriber.putNext(.data(next))
            }, completed: {
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetched.dispose()
                status.dispose()
                data.dispose()
            }
        }
        return fetchedData
        |> take(until: { state in
            if case let .data(data) = state, data.isComplete {
                return SignalTakeAction(passthrough: true, complete: true)
            }
            return SignalTakeAction(passthrough: true, complete: false)
        })
        |> map { data in
            return (data, isImage)
        }
    } else {
        return .complete()
    }
}

public func saveToCameraRoll(context: AccountContext, userLocation: MediaResourceUserLocation, customUserContentType: MediaResourceUserContentType? = nil, mediaReference: AnyMediaReference, video: AnyMediaReference? = nil) -> Signal<Float, NoError> {
    let mediaData: Signal<(FetchMediaDataState, Bool), NoError> = fetchMediaData(context: context, userLocation: userLocation, customUserContentType: customUserContentType, mediaReference: mediaReference)
    let videoData: Signal<FetchMediaDataState?, NoError>
    if let video {
        videoData = fetchMediaData(context: context, userLocation: userLocation, customUserContentType: customUserContentType, mediaReference: video)
        |> map { state, _ in
            return state
        }
        |> map(Optional.init)
    } else {
        videoData = .single(nil)
    }

    return combineLatest(
        queue: Queue.mainQueue(),
        mediaData,
        videoData
    )
    // Stop observing MediaBox before the Photos operation starts. Status/data
    // updates for either resource must not cancel or repeat an in-flight save.
    |> take(until: { main, video in
        let mainComplete: Bool
        if case let .data(data) = main.0 { mainComplete = data.isComplete } else { mainComplete = false }
        let videoComplete: Bool
        if let video {
            if case let .data(data) = video { videoComplete = data.isComplete } else { videoComplete = false }
        } else { videoComplete = true }
        return SignalTakeAction(passthrough: true, complete: mainComplete && videoComplete)
    })
    |> mapToSignal { stateAndIsImage, videoState -> Signal<Float, NoError> in
        let isImage = stateAndIsImage.1
        guard case let .data(mainData) = stateAndIsImage.0, mainData.isComplete else {
            if case let .progress(value) = stateAndIsImage.0 { return .single(min(0.99, value)) }
            return .complete()
        }
        let pairedData: EngineMediaResource.ResourceData?
        if let videoState {
            guard case let .data(data) = videoState, data.isComplete else {
                if case let .progress(value) = videoState { return .single(min(0.99, value)) }
                return .complete()
            }
            pairedData = data
        } else { pairedData = nil }

        return Signal<Float, NoError> { subscriber in
            let cancelled = Atomic(value: false)
            DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: context.sharedContext.currentPresentationData.with { $0 }, present: { c, a in
                context.sharedContext.presentGlobalController(c, a)
            }, openSettings: context.sharedContext.applicationBindings.openSettings, { authorized in
                guard authorized, !cancelled.with({ $0 }) else { subscriber.putCompletion(); return }
                // File copying, JPEG metadata and large data reads must not block
                // the UI. Photos owns reading the prepared file until completion.
                Queue.concurrentDefaultQueue().async {
                    guard !cancelled.with({ $0 }) else { return }
                    let fileExtension: String
                    if let file = mediaReference.media as? TelegramMediaFile {
                        fileExtension = UTType(mimeType: file.mimeType)?.preferredFilenameExtension ?? (isImage ? "jpg" : "mp4")
                    } else { fileExtension = isImage ? "jpg" : "mp4" }
                    guard let mainFile = CodeGramExportFile(sourcePath: mainData.path, fileName: "media." + fileExtension) else {
                        subscriber.putCompletion(); return
                    }
                    let finish: (Bool) -> Void = { success in
                        mainFile.dispose()
                        if success { subscriber.putNext(1.0) }
                        subscriber.putCompletion()
                    }
                    if isImage, let pairedData {
                        guard let videoFile = CodeGramExportFile(sourcePath: pairedData.path, fileName: "paired.mp4"),
                            let imageData = try? Data(contentsOf: mainFile.url, options: .mappedIfSafe) else {
                            finish(false); return
                        }
                        let id = UUID().uuidString
                        guard let jpegWithID = addAssetIdentifierToJPEG(imageData, assetIdentifier: id) else {
                            videoFile.dispose(); finish(false); return
                        }
                        let outputVideoURL = mainFile.url.deletingLastPathComponent().appendingPathComponent("paired.mov")
                        addAssetIdentifierToVideo(inputURL: videoFile.url, outputURL: outputVideoURL, assetIdentifier: id) { success in
                            guard success, !cancelled.with({ $0 }) else { videoFile.dispose(); finish(false); return }
                            PHPhotoLibrary.shared().performChanges({
                                let request = PHAssetCreationRequest.forAsset()
                                request.addResource(with: .photo, data: jpegWithID, options: nil)
                                request.addResource(with: .pairedVideo, fileURL: outputVideoURL, options: nil)
                            }, completionHandler: { success, _ in
                                videoFile.dispose()
                                finish(success)
                            })
                        }
                    } else {
                        guard !cancelled.with({ $0 }) else { finish(false); return }
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetCreationRequest.forAsset().addResource(with: isImage ? .photo : .video, fileURL: mainFile.url, options: nil)
                        }, completionHandler: { success, _ in finish(success) })
                    }
                }
            })
            return ActionDisposable { let _ = cancelled.swap(true) }
        }
    }
}

public func copyToPasteboard(context: AccountContext, userLocation: MediaResourceUserLocation, mediaReference: AnyMediaReference) -> Signal<Void, NoError> {
    return fetchMediaData(context: context, userLocation: userLocation, mediaReference: mediaReference)
    |> mapToSignal { state, isImage -> Signal<Void, NoError> in
        if case let .data(data) = state, data.isComplete {
            return Signal<Void, NoError> { subscriber in
                let pasteboard = UIPasteboard.general

                if mediaReference.media is TelegramMediaImage {
                    if let fileData = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: .mappedIfSafe) {
                        pasteboard.setData(fileData, forPasteboardType: UTType.jpeg.identifier)
                    }
                }
                subscriber.putNext(Void())
                subscriber.putCompletion()

                return EmptyDisposable
            }
        } else {
            return .complete()
        }
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in return .complete() }
}

private func addAssetIdentifierToJPEG(_ imageData: Data, assetIdentifier: String) -> Data? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), let uti = CGImageSourceGetType(source), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }

    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else {
        return nil
    }

    var metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

    var maker = metadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
    maker["17"] = assetIdentifier
    metadata[kCGImagePropertyMakerAppleDictionary as String] = maker

    CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }

    return mutableData as Data
}

private func addAssetIdentifierToVideo(inputURL: URL, outputURL: URL, assetIdentifier: String, completion: @escaping (Bool) -> Void) {
    let asset = AVAsset(url: inputURL)

    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        completion(false)
        return
    }

    let identifierItem = AVMutableMetadataItem()
    identifierItem.keySpace = .quickTimeMetadata
    identifierItem.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
    identifierItem.value = assetIdentifier as NSString

    let stillImageTimeItem = AVMutableMetadataItem()
    let keyStillImageTime = "com.apple.quicktime.still-image-time"
    let keySpaceQuickTimeMetadata = "mdta"
    stillImageTimeItem.key = keyStillImageTime as (NSCopying & NSObjectProtocol)?
    stillImageTimeItem.keySpace = AVMetadataKeySpace(rawValue: keySpaceQuickTimeMetadata)
    stillImageTimeItem.value = 0 as (NSCopying & NSObjectProtocol)?
    stillImageTimeItem.dataType = "com.apple.metadata.datatype.int8"

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mov
    exportSession.metadata = [identifierItem, stillImageTimeItem]
    exportSession.shouldOptimizeForNetworkUse = true

    exportSession.exportAsynchronously {
        completion(exportSession.status == .completed)
    }
}
