import Foundation

/// The regular media uploader owns the temporary file after enqueueing it.
public func codegramSocialVideoMedia(path: String, size: Int64, duration: Double, width: Int32, height: Int32) -> TelegramMediaFile {
    let identifier = Int64.random(in: 1 ... Int64.max)
    return TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.LocalFile, id: identifier), partialReference: nil,
        resource: LocalFileReferenceMediaResource(localFilePath: path, randomId: identifier, isUniquelyReferencedTemporaryFile: true, size: size),
        previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: size,
        attributes: [.FileName(fileName: "video.mp4"), .Video(duration: duration, size: .init(width: width,height: height), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: "h264")],
        alternativeRepresentations: [])
}
