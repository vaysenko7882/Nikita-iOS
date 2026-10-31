import Foundation
import Postbox

struct NikitaArchiveAsset: Decodable {
    let blobId: String
    let size: Int64
    let sha256: String?
    let width: Int32?
    let height: Int32?
    let startTimestamp: Double?

    enum CodingKeys: String, CodingKey {
        case blobId = "blob_id", startTimestamp = "start_timestamp"
        case size, sha256, width, height
    }

    func resource(accountId: Int64, serverId: String) -> NikitaArchiveMediaResource? {
        let resource = NikitaArchiveMediaResource(accountId: accountId, serverId: serverId, blobId: self.blobId, size: self.size, sha256: self.sha256 ?? "")
        return resource.isValid ? resource : nil
    }

    var dimensions: PixelDimensions {
        return PixelDimensions(width: max(1, min(100000, self.width ?? 1)), height: max(1, min(100000, self.height ?? 1)))
    }

    func representation(accountId: Int64, serverId: String) -> TelegramMediaImageRepresentation? {
        guard let resource = self.resource(accountId: accountId, serverId: serverId) else { return nil }
        return TelegramMediaImageRepresentation(dimensions: self.dimensions, resource: resource,
            progressiveSizes: [], immediateThumbnailData: nil)
    }
}

/// JSON-only descriptor; it is never stored in Postbox preferences. Native
/// image/file objects below use the regular Telegram persistence and players.
final class NikitaArchiveMedia: Decodable {
    let kind: String
    let id: Int64
    let asset: NikitaArchiveAsset
    let preview: NikitaArchiveAsset?
    let videos: [NikitaArchiveAsset]?
    let immediateThumbnail: String?
    let mimeType: String?
    let fileName: String?
    let width: Int32?
    let height: Int32?
    let duration: Double?
    let voice: Bool?
    let audio: Bool?
    let video: Bool?
    let silent: Bool?
    let videoThumbnails: [NikitaArchiveAsset]?
    let roundVideo: Bool?
    let streaming: Bool?
    let animated: Bool?
    let sticker: Bool?
    let customEmoji: Bool?
    let alt: String?
    let premium: Bool?
    let singleColor: Bool?
    let title: String?
    let performer: String?
    let waveform: String?
    let videoCodec: String?
    let cover: NikitaArchiveMedia?
    let alternatives: [NikitaArchiveMedia]?
    let liveVideo: NikitaArchiveMedia?

    enum CodingKeys: String, CodingKey {
        case kind, id, asset, preview, videos, width, height, duration, voice, audio, video, streaming, silent
        case animated, sticker, alt, premium, title, performer, waveform, cover, alternatives
        case immediateThumbnail = "immediate_thumbnail", mimeType = "mime_type", fileName = "file_name"
        case roundVideo = "round_video", customEmoji = "custom_emoji", singleColor = "single_color"
        case videoCodec = "video_codec"
        case videoThumbnails = "video_thumbnails"
        case liveVideo = "live_video"
    }

    private func bytes(_ value: String?) -> Data? {
        guard let value, value.utf8.count <= 16384, let data = Data(base64Encoded: value), !data.isEmpty, data.count <= 8192 else { return nil }
        return data
    }

    func nativeMedia(accountId: Int64, serverId: String, depth: Int = 0) -> Media? {
        guard depth <= 2, let resource = self.asset.resource(accountId: accountId, serverId: serverId) else { return nil }
        var previews: [TelegramMediaImageRepresentation] = []
        if let preview = self.preview?.representation(accountId: accountId, serverId: serverId) { previews.append(preview) }
        if self.kind == "photo" {
            guard let full = self.asset.representation(accountId: accountId, serverId: serverId) else { return nil }
            if !previews.contains(where: { $0.resource.id == full.resource.id }) { previews.append(full) }
            let videos: [TelegramMediaImage.VideoRepresentation] = (self.videos ?? []).prefix(8).compactMap { asset in
                guard let resource = asset.resource(accountId: accountId, serverId: serverId) else { return nil }
                return TelegramMediaImage.VideoRepresentation(dimensions: asset.dimensions, resource: resource, startTimestamp: asset.startTimestamp)
            }
            return TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: self.id),
                representations: previews, videoRepresentations: videos, immediateThumbnailData: self.bytes(self.immediateThumbnail),
                reference: nil, partialReference: nil, flags: [],
                video: self.liveVideo?.nativeMedia(accountId: accountId, serverId: serverId, depth: depth + 1) as? TelegramMediaFile)
        }
        guard self.kind == "document" else { return nil }
        let dimensions = PixelDimensions(width: max(1, min(100000, self.width ?? 1)), height: max(1, min(100000, self.height ?? 1)))
        let duration = self.duration.flatMap { $0.isFinite && $0 >= 0 && $0 <= Double(Int32.max) ? $0 : nil } ?? 0
        var attributes: [TelegramMediaFileAttribute] = []
        attributes.append(.FileName(fileName: String((self.fileName ?? "file").prefix(255))))
        if (self.width ?? 0) > 0 && (self.height ?? 0) > 0 { attributes.append(.ImageSize(size: dimensions)) }
        if self.animated == true { attributes.append(.Animated) }
        if self.sticker == true { attributes.append(.Sticker(displayText: self.alt ?? "", packReference: nil, maskData: nil)) }
        if self.customEmoji == true {
            attributes.append(.CustomEmoji(isPremium: self.premium ?? true, isSingleColor: self.singleColor ?? false, alt: self.alt ?? "", packReference: nil))
        }
        if self.audio == true || self.voice == true {
            attributes.append(.Audio(isVoice: self.voice ?? false, duration: Int(duration), title: self.title, performer: self.performer, waveform: self.bytes(self.waveform)))
        }
        if self.video == true || self.roundVideo == true {
            var flags: TelegramMediaVideoFlags = []
            if self.roundVideo == true { flags.insert(.instantRoundVideo) }
            if self.streaming == true { flags.insert(.supportsStreaming) }
            if self.silent == true { flags.insert(.isSilent) }
            attributes.append(.Video(duration: duration, size: dimensions, flags: flags, preloadSize: nil, coverTime: nil, videoCodec: self.videoCodec))
        }
        let cover = self.cover?.nativeMedia(accountId: accountId, serverId: serverId, depth: depth + 1) as? TelegramMediaImage
        let alternatives: [TelegramMediaFile] = (self.alternatives ?? []).prefix(8).compactMap {
            $0.nativeMedia(accountId: accountId, serverId: serverId, depth: depth + 1) as? TelegramMediaFile
        }
        let videoThumbnails: [TelegramMediaFile.VideoThumbnail] = (self.videoThumbnails ?? []).prefix(8).compactMap { asset in
            guard let resource = asset.resource(accountId: accountId, serverId: serverId) else { return nil }
            return TelegramMediaFile.VideoThumbnail(dimensions: asset.dimensions, resource: resource)
        }
        return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: self.id), partialReference: nil,
            resource: resource, previewRepresentations: previews, videoThumbnails: videoThumbnails, videoCover: cover,
            immediateThumbnailData: self.bytes(self.immediateThumbnail), mimeType: self.mimeType ?? "application/octet-stream",
            size: resource.size, attributes: attributes, alternativeRepresentations: alternatives)
    }
}
