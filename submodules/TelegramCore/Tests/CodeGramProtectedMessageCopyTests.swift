import XCTest
import Postbox
@testable import TelegramCore

final class CodeGramProtectedMessageCopyTests: XCTestCase {
    private let accountId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1))
    private let channelId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1234))

    private func source(protected: Bool = true, attributes: [MessageAttribute] = [], media: [Media] = []) -> Message {
        let channel = TelegramChannel(id: self.channelId, accessHash: .personal(42), title: "Source", username: nil,
            photo: [], creationDate: 0, version: 0, participationStatus: .member,
            info: .broadcast(TelegramChannelBroadcastInfo(flags: [])), flags: [], restrictionInfo: nil,
            adminRights: nil, bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil,
            approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
            sendPaidMessageStars: nil, linkedMonoforumId: nil)
        var peers = SimpleDictionary<PeerId, Peer>()
        peers[channel.id] = channel
        return Message(stableId: 1, stableVersion: 0,
            id: MessageId(peerId: channel.id, namespace: Namespaces.Message.Cloud, id: 10), globallyUniqueId: nil,
            groupingKey: 100, groupInfo: nil, threadId: nil, timestamp: 100,
            flags: protected ? [.Incoming, .CopyProtected] : [.Incoming], tags: [], globalTags: [], localTags: [],
            customTags: [], forwardInfo: nil, author: channel, text: "Caption", attributes: attributes, media: media,
            peers: peers, associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:],
            associatedThreadInfo: nil, associatedStories: [:])
    }

    private func copy(_ source: Message, enabled: Bool = true, destination: PeerId? = nil,
        attributes: [MessageAttribute] = []) -> EnqueueMessage? {
        return codeGramProtectedMessageCopy(source: source, destination: destination ?? self.accountId,
            accountPeerId: self.accountId, enabled: enabled, cachedUserData: nil, threadId: 7, groupingKey: 200,
            forwardAttributes: attributes, correlationId: 300)
    }

    func testOptInAndSavedMessagesScope() {
        XCTAssertNil(self.copy(self.source(), enabled: false))
        XCTAssertNil(self.copy(self.source(), destination: self.channelId))
        XCTAssertNil(self.copy(self.source(protected: false)))
        XCTAssertNotNil(self.copy(self.source()))
    }

    func testCopyIsANewSelfAuthoredMessageWithContentAndGrouping() {
        let entities = TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0 ..< 7, type: .Bold)])
        let source = self.source(attributes: [entities, InlineBotMessageAttribute(peerId: self.channelId, title: nil)])
        guard case let .message(text, attributes, _, media, threadId, reply, story, grouping, correlation, _)? = self.copy(source,
            attributes: [SendAsMessageAttribute(peerId: self.channelId)]) else { return XCTFail("Not a new message") }
        XCTAssertEqual(text, "Caption")
        XCTAssertEqual(threadId, 7)
        XCTAssertEqual(grouping, 200)
        XCTAssertEqual(correlation, 300)
        XCTAssertNil(media)
        XCTAssertNil(reply)
        XCTAssertNil(story)
        XCTAssertTrue(attributes.contains(where: { $0 is TextEntitiesMessageAttribute }))
        XCTAssertFalse(attributes.contains(where: { $0 is ForwardSourceInfoAttribute || $0 is SourceReferenceMessageAttribute
            || $0 is SendAsMessageAttribute || $0 is InlineBotMessageAttribute }))
    }

    func testPhotoCopyRetainsFetchSourceAndRequestsBytes() {
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 5), representations: [],
            immediateThumbnailData: nil, reference: .cloud(imageId: 5, accessHash: 6, fileReference: Data([7])), partialReference: nil, flags: [])
        let source = self.source(media: [image])
        guard case let .message(_, attributes, _, media, _, _, _, _, _, _)? = self.copy(source),
            case let .message(reference, _)? = media else { return XCTFail("Source reference lost") }
        XCTAssertEqual(reference.id, source.id)
        XCTAssertTrue(codeGramRequiresMediaUpload(attributes))
        let info = attributes.compactMap { $0 as? OutgoingMessageInfoAttribute }.first!
        let encoder = PostboxEncoder()
        info.encode(encoder)
        let restored = OutgoingMessageInfoAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertTrue(restored.flags.contains(.requiresMediaUpload), "A relaunch must not reuse the protected cloud reference")
        XCTAssertFalse(restored.flags.contains(.transformedMedia))
    }

    func testHiddenCaptionDropsItsEntities() {
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 5), representations: [],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let source = self.source(attributes: [TextEntitiesMessageAttribute(entities: [])], media: [image])
        guard case let .message(text, attributes, _, _, _, _, _, _, _, _)? = self.copy(source,
            attributes: [ForwardOptionsMessageAttribute(hideNames: false, hideCaptions: true)]) else { return XCTFail("Not copied") }
        XCTAssertEqual(text, "")
        XCTAssertFalse(attributes.contains(where: { $0 is TextEntitiesMessageAttribute }))
    }

    func testRichEmbeddedMediaAlsoUploadsBytesAndRetainsFetchSource() {
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 5), representations: [],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
        let page = InstantPage(blocks: [], rawMedia: [image.imageId: image], isComplete: true, rtl: false, url: "", views: nil)
        let source = self.source(attributes: [RichTextMessageAttribute(instantPage: page, fullInstantPage: nil)])
        guard case let .message(_, attributes, _, _, _, _, _, _, _, _)? = self.copy(source),
            let rich = attributes.compactMap({ $0 as? RichTextMessageAttribute }).first,
            let copiedImage = rich.instantPage.rawMedia[image.imageId] as? TelegramMediaImage,
            case let .message(reference)? = copiedImage.partialReference else { return XCTFail("Rich fetch source lost") }
        XCTAssertTrue(codeGramRequiresMediaUpload(attributes))
        XCTAssertEqual(reference.id, source.id)
        XCTAssertNil(image.partialReference, "The source post must remain unchanged")
    }

    func testFileCopyRetainsVoiceTypeAndDownloadReference() {
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 8), partialReference: nil,
            resource: LocalFileMediaResource(fileId: 9), previewRepresentations: [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: "audio/ogg", size: 100,
            attributes: [.Audio(isVoice: true, duration: 2, title: nil, performer: nil, waveform: nil)], alternativeRepresentations: [])
        let source = self.source(media: [file])
        guard case let .message(_, attributes, _, reference, _, _, _, _, _, _)? = self.copy(source),
            let reference, let copied = augmentMediaWithReference(reference) as? TelegramMediaFile,
            case let .message(message)? = copied.partialReference else { return XCTFail("File fetch source lost") }
        XCTAssertTrue(copied.isVoice)
        XCTAssertEqual(message.id, source.id)
        XCTAssertTrue(codeGramRequiresMediaUpload(attributes))
        XCTAssertNil(file.partialReference)
    }

    func testPairedVideoInheritsItsPhotosFetchReference() {
        let video = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 8), partialReference: nil,
            resource: LocalFileMediaResource(fileId: 9), previewRepresentations: [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: "video/mp4", size: 100, attributes: [], alternativeRepresentations: [])
        let sourceReference = PartialMediaReference.message(message: MessageReference(self.source()))
        let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 5), representations: [],
            immediateThumbnailData: nil, reference: nil, partialReference: sourceReference, flags: [], video: video)
        XCTAssertEqual(codeGramPhotoVideoForUpload(video, photo: image).partialReference, sourceReference)
        XCTAssertNil(video.partialReference)
        let ownReference = PartialMediaReference.message(message: MessageReference(self.source(protected: false)))
        let referencedVideo = video.withUpdatedPartialReference(ownReference)
        XCTAssertTrue(codeGramPhotoVideoForUpload(referencedVideo, photo: image) === referencedVideo)
    }
}
