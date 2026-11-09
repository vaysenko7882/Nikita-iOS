import Foundation
import Postbox
@testable import TelegramCore
import XCTest

final class CodeGramArchiveContentTests: XCTestCase {
    private func photoResource(_ id: Int64, reference: UInt8) -> CloudPhotoSizeMediaResource {
        return CloudPhotoSizeMediaResource(datacenterId: 1, photoId: id, accessHash: 100,
            sizeSpec: "m", size: 100, fileReference: Data([reference]))
    }

    private func image(_ id: Int64 = 20, reference: UInt8 = 1,
        emojiMarkup: TelegramMediaImage.EmojiMarkup? = nil,
        videoRepresentations: [TelegramMediaImage.VideoRepresentation] = [],
        video: TelegramMediaFile? = nil) -> TelegramMediaImage {
        let representation = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 64, height: 64),
            resource: self.photoResource(id, reference: reference), progressiveSizes: [], immediateThumbnailData: nil)
        return TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: id),
            representations: [representation], videoRepresentations: videoRepresentations,
            immediateThumbnailData: nil, emojiMarkup: emojiMarkup,
            reference: .cloud(imageId: id, accessHash: 100, fileReference: Data([reference])),
            partialReference: nil, flags: [], video: video)
    }

    private func document(_ id: Int64 = 10, reference: UInt8 = 1, fileName: String = "video.mp4",
        preview: TelegramMediaImageRepresentation? = nil,
        videoThumbnails: [TelegramMediaFile.VideoThumbnail] = [],
        videoCover: TelegramMediaImage? = nil,
        alternatives: [TelegramMediaFile] = []) -> TelegramMediaFile {
        return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id),
            partialReference: nil,
            resource: CloudDocumentMediaResource(datacenterId: 1, fileId: id, accessHash: 100, size: 100,
                fileReference: Data([reference]), fileName: fileName),
            previewRepresentations: preview.map { [$0] } ?? [], videoThumbnails: videoThumbnails,
            videoCover: videoCover, immediateThumbnailData: nil, mimeType: "video/mp4", size: 100,
            attributes: [.FileName(fileName: fileName)], alternativeRepresentations: alternatives)
    }

    private func contentsAreEqual(_ lhs: Media, _ rhs: Media) -> Bool {
        return deletedMessageArchiveContentsAreEqual(lhsText: "same", lhsAttributes: [], lhsMedia: [lhs],
            rhsText: "same", rhsAttributes: [], rhsMedia: [rhs])
    }

    private func webpage(reference: UInt8 = 1, title: String = "Preview", imageId: Int64 = 20,
        attributes: [TelegramMediaWebpageAttribute] = [], instantPage: InstantPage? = nil) -> TelegramMediaWebpage {
        let content = TelegramMediaWebpageLoadedContent(url: "https://example.com", displayUrl: "example.com",
            hash: 1, type: "article", websiteName: "Example", title: title, text: "Description",
            embedUrl: nil, embedType: nil, embedSize: nil, duration: nil, author: nil,
            isMediaLargeByDefault: false, imageIsVideoCover: false, image: self.image(imageId, reference: reference),
            file: self.document(reference: reference), story: nil, attributes: attributes, instantPage: instantPage)
        return TelegramMediaWebpage(webpageId: MediaId(namespace: Namespaces.Media.CloudWebpage, id: 60), content: .Loaded(content))
    }

    func testDocumentReferenceRefreshDoesNotCreateRevision() {
        func file(reference: UInt8) -> TelegramMediaFile {
            return self.document(reference: reference,
                preview: self.image(reference: reference).representations[0],
                videoThumbnails: [TelegramMediaFile.VideoThumbnail(dimensions: PixelDimensions(width: 32, height: 32),
                    resource: self.photoResource(30, reference: reference))],
                videoCover: self.image(40, reference: reference),
                alternatives: [self.document(50, reference: reference)])
        }
        let previous = file(reference: 1), refreshed = file(reference: 2)
        XCTAssertFalse(previous.isEqual(to: refreshed), "The fixture must exercise a strict credential change")
        XCTAssertTrue(self.contentsAreEqual(previous, refreshed))
    }

    func testImageReferenceRefreshDoesNotCreateRevision() {
        func photo(reference: UInt8) -> TelegramMediaImage {
            return self.image(reference: reference, videoRepresentations: [
                TelegramMediaImage.VideoRepresentation(dimensions: PixelDimensions(width: 64, height: 64),
                    resource: self.photoResource(30, reference: reference), startTimestamp: 0.5)
            ], video: self.document(reference: reference))
        }
        let previous = photo(reference: 1), refreshed = photo(reference: 2)
        XCTAssertFalse(previous.isEqual(to: refreshed), "The fixture must exercise a strict credential change")
        XCTAssertTrue(self.contentsAreEqual(previous, refreshed))
    }

    func testMediaReplacementCreatesRevision() {
        XCTAssertFalse(self.contentsAreEqual(self.document(10), self.document(11)))
        XCTAssertFalse(self.contentsAreEqual(self.image(20), self.image(21)))
    }

    func testLinkPreviewReferenceRefreshDoesNotCreateRevision() {
        let previous = self.webpage(reference: 1), refreshed = self.webpage(reference: 2)
        XCTAssertFalse(previous.isEqual(to: refreshed), "The fixture must refresh embedded media credentials")
        XCTAssertTrue(self.contentsAreEqual(previous, refreshed))
    }

    func testLinkPreviewContentChangeCreatesRevision() {
        XCTAssertFalse(self.contentsAreEqual(self.webpage(), self.webpage(title: "Changed")))
        XCTAssertFalse(self.contentsAreEqual(self.webpage(), self.webpage(imageId: 21)))
    }

    private func instantPage(reference: UInt8 = 1, text: String = "Article", imageId: Int64 = 20, views: Int32 = 1) -> InstantPage {
        let image = self.image(imageId, reference: reference)
        let file = self.document(reference: reference)
        return InstantPage(blocks: [.paragraph(.plain(text))], rawMedia: [image.imageId: image, file.fileId: file],
            isComplete: true, rtl: false, url: "https://example.com", views: views)
    }

    func testInstantPageReferenceAndViewRefreshDoNotCreateRevision() {
        let previous = self.webpage(instantPage: self.instantPage())
        let refreshed = self.webpage(instantPage: self.instantPage(reference: 2, views: 2))
        XCTAssertFalse(previous.isEqual(to: refreshed))
        XCTAssertTrue(self.contentsAreEqual(previous, refreshed))
        XCTAssertTrue(self.contentsAreEqual(previous, self.webpage(instantPage: self.instantPage(views: 3))))
    }

    func testPersistedInstantPageReferenceRefreshDoesNotCreateRevision() throws {
        initializeAccountManagement()
        func persisted(_ media: TelegramMediaWebpage) throws -> TelegramMediaWebpage {
            let encoder = PostboxEncoder()
            encoder.encodeRootObject(media)
            let decoder = PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData()))
            return try XCTUnwrap(decoder.decodeRootObject() as? TelegramMediaWebpage)
        }
        let previous = try persisted(self.webpage(instantPage: self.instantPage()))
        let refreshed = try persisted(self.webpage(instantPage: self.instantPage(reference: 2, views: 2)))
        XCTAssertFalse(previous.isEqual(to: refreshed), "Actual persisted InstantPage bytes must differ")
        XCTAssertTrue(self.contentsAreEqual(previous, refreshed))
    }

    func testInstantPageContentChangesCreateRevisions() {
        let previous = self.webpage(instantPage: self.instantPage())
        XCTAssertFalse(self.contentsAreEqual(previous, self.webpage(instantPage: self.instantPage(text: "Changed"))))
        XCTAssertFalse(self.contentsAreEqual(previous, self.webpage(instantPage: self.instantPage(imageId: 21))))
        XCTAssertFalse(self.contentsAreEqual(previous, self.webpage()))
    }

    private func webpageAttributes(reference: UInt8 = 1, fileId: Int64 = 10,
        settings: TelegramThemeSettings? = nil,
        flags: TelegramMediaWebpageStickerPackAttribute.Flags = []) -> [TelegramMediaWebpageAttribute] {
        let file = self.document(fileId, reference: reference)
        return [.theme(TelegraMediaWebpageThemeAttribute(files: [file], settings: settings)),
            .stickerPack(TelegramMediaWebpageStickerPackAttribute(flags: flags, files: [file])),
            .giftCollection(TelegramMediaWebpageGiftCollectionAttribute(files: [file]))]
    }

    func testWebpageAttributeReferenceRefreshDoesNotCreateRevision() {
        let previous = self.webpage(attributes: self.webpageAttributes())
        let refreshed = self.webpage(attributes: self.webpageAttributes(reference: 2))
        XCTAssertFalse(previous.isEqual(to: refreshed))
        XCTAssertTrue(self.contentsAreEqual(previous, refreshed))
    }

    func testWebpageAttributeContentChangesCreateRevisions() {
        let attributes = self.webpageAttributes()
        let previous = self.webpage(attributes: attributes)
        let replacements = self.webpageAttributes(fileId: 11)
        for i in attributes.indices {
            var changed = attributes
            changed[i] = replacements[i]
            XCTAssertFalse(self.contentsAreEqual(previous, self.webpage(attributes: changed)))
        }
        XCTAssertFalse(self.contentsAreEqual(previous, self.webpage(attributes: self.webpageAttributes(flags: .isEmoji))))
        let settings = TelegramThemeSettings(baseTheme: .night, accentColor: 100, outgoingAccentColor: nil,
            messageColors: [], animateMessageColors: false, wallpaper: nil)
        XCTAssertFalse(self.contentsAreEqual(previous, self.webpage(attributes: self.webpageAttributes(settings: settings))))
    }

    func testPaidMediaRefreshPreservesActualContentChanges() {
        func paid(reference: UInt8 = 1, amount: Int64 = 100, imageId: Int64 = 20) -> TelegramMediaPaidContent {
            return TelegramMediaPaidContent(amount: amount, extendedMedia: [
                .full(media: self.image(imageId, reference: reference)),
                .full(media: self.document(reference: reference))
            ])
        }
        XCTAssertFalse(paid(reference: 1).isEqual(to: paid(reference: 2)))
        XCTAssertTrue(self.contentsAreEqual(paid(reference: 1), paid(reference: 2)))
        XCTAssertFalse(self.contentsAreEqual(paid(), paid(amount: 200)))
        XCTAssertFalse(self.contentsAreEqual(paid(), paid(imageId: 21)))
    }

    func testFileNameChangeCreatesRevision() {
        XCTAssertFalse(self.contentsAreEqual(self.document(fileName: "before.mp4"), self.document(fileName: "after.mp4")))
    }

    func testVideoCoverChangeCreatesRevision() {
        XCTAssertFalse(self.contentsAreEqual(self.document(videoCover: self.image(20)), self.document(videoCover: self.image(21))))
        XCTAssertFalse(self.contentsAreEqual(self.document(), self.document(videoCover: self.image())))
    }

    func testImageEmojiMarkupChangeCreatesRevision() {
        let before = TelegramMediaImage.EmojiMarkup(content: .emoji(fileId: 1), backgroundColors: [0])
        let after = TelegramMediaImage.EmojiMarkup(content: .emoji(fileId: 2), backgroundColors: [0])
        XCTAssertFalse(self.contentsAreEqual(self.image(emojiMarkup: before), self.image(emojiMarkup: after)))
    }

    func testImageVideoRepresentationChangeCreatesRevision() {
        func photo(resourceId: Int64 = 30, startTimestamp: Double = 0.5) -> TelegramMediaImage {
            return self.image(videoRepresentations: [TelegramMediaImage.VideoRepresentation(
                dimensions: PixelDimensions(width: 64, height: 64),
                resource: self.photoResource(resourceId, reference: 1), startTimestamp: startTimestamp)])
        }
        XCTAssertFalse(self.contentsAreEqual(photo(), photo(resourceId: 31)))
        XCTAssertFalse(self.contentsAreEqual(photo(), photo(startTimestamp: 1.0)))
    }

    func testFileVideoThumbnailChangeCreatesRevision() {
        func file(resourceId: Int64) -> TelegramMediaFile {
            return self.document(videoThumbnails: [TelegramMediaFile.VideoThumbnail(
                dimensions: PixelDimensions(width: 32, height: 32),
                resource: self.photoResource(resourceId, reference: 1))])
        }
        XCTAssertFalse(self.contentsAreEqual(file(resourceId: 30), file(resourceId: 31)))
    }

    func testLivePhotoVideoReplacementCreatesRevision() {
        XCTAssertFalse(self.contentsAreEqual(self.image(video: self.document(10)), self.image(video: self.document(11))))
        XCTAssertFalse(self.contentsAreEqual(self.image(), self.image(video: self.document())))
    }

    func testListeningMentionAndCommentStateDoNotCreateRevisions() {
        let peer = PeerId(123)
        let previous: [MessageAttribute] = [ConsumableContentMessageAttribute(consumed: false),
            ConsumablePersonalMentionMessageAttribute(consumed: false, pending: true),
            ReplyThreadMessageAttribute(count: 1, latestUsers: [], commentsPeerId: peer, maxMessageId: 1, maxReadMessageId: nil)]
        let refreshed: [MessageAttribute] = [ConsumableContentMessageAttribute(consumed: true),
            ConsumablePersonalMentionMessageAttribute(consumed: true, pending: false),
            ReplyThreadMessageAttribute(count: 2, latestUsers: [peer], commentsPeerId: peer, maxMessageId: 2, maxReadMessageId: 2)]
        XCTAssertTrue(deletedMessageArchiveContentsAreEqual(lhsText: "same", lhsAttributes: previous, lhsMedia: [],
            rhsText: "same", rhsAttributes: refreshed, rhsMedia: []))
        XCTAssertTrue(deletedMessageArchiveContentsAreEqual(lhsText: "same", lhsAttributes: [], lhsMedia: [],
            rhsText: "same", rhsAttributes: refreshed, rhsMedia: []))
    }

    func testContentAttributesStillCreateRevision() {
        XCTAssertFalse(deletedMessageArchiveContentsAreEqual(lhsText: "same", lhsAttributes: [], lhsMedia: [],
            rhsText: "same", rhsAttributes: [MediaSpoilerMessageAttribute()], rhsMedia: []))
        XCTAssertFalse(deletedMessageArchiveContentsAreEqual(lhsText: "same", lhsAttributes: [], lhsMedia: [],
            rhsText: "same", rhsAttributes: [TextEntitiesMessageAttribute(entities: [
                MessageTextEntity(range: 0 ..< 4, type: .Bold)
            ])], rhsMedia: []))
    }
}
