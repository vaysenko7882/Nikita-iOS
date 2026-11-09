import Foundation
import Postbox

/// UI export permission does not change the server's no-forwards flag. Keep this
/// check independent of `isCopyProtected()`, which deliberately applies that UI preference.
func codeGramHasServerCopyProtection(_ message: Message, cachedUserData: CachedUserData?) -> Bool {
    if message.flags.contains(.CopyProtected) { return true }
    if let group = message.peers[message.id.peerId] as? TelegramGroup {
        return group.flags.contains(.copyProtectionEnabled)
    }
    if let channel = message.peers[message.id.peerId] as? TelegramChannel {
        return channel.flags.contains(.copyProtectionEnabled)
    }
    if let cachedUserData {
        return cachedUserData.flags.contains(.copyProtectionEnabled) || cachedUserData.flags.contains(.myCopyProtectionEnabled)
    }
    return false
}

/// A received protected post saved to self is a new message. It must carry neither
/// a forward RPC/source attribute nor the channel's send-as or inline-bot identity.
func codeGramProtectedMessageCopy(source: Message, destination: PeerId, accountPeerId: PeerId,
    enabled: Bool, cachedUserData: CachedUserData?, threadId: Int64?, groupingKey: Int64?,
    forwardAttributes: [MessageAttribute], correlationId: Int64?) -> EnqueueMessage? {
    guard enabled, destination == accountPeerId, source.id.namespace == Namespaces.Message.Cloud,
        codeGramHasServerCopyProtection(source, cachedUserData: cachedUserData) else { return nil }
    let media = source.media.first
    let hidesCaption = (media is TelegramMediaImage || media is TelegramMediaFile)
        && forwardAttributes.contains(where: { ($0 as? ForwardOptionsMessageAttribute)?.hideCaptions == true })
    var attributes = forwardCopyRequestedAttributes(sourceAttributes: source.attributes,
        forwardAttributes: forwardAttributes, hidesCaption: hidesCaption)
    attributes.removeAll(where: { $0 is InlineBotMessageAttribute || $0 is OutgoingChatContextResultMessageAttribute
        || $0 is ReplyMarkupMessageAttribute || $0 is SendAsMessageAttribute || $0 is ForwardOptionsMessageAttribute
        || $0 is ForwardSourceInfoAttribute || $0 is SourceReferenceMessageAttribute })
    var hasRichMedia = false
    attributes = attributes.map { attribute in
        guard let rich = attribute as? RichTextMessageAttribute else { return attribute }
        func pageWithSourceReferences(_ page: InstantPage) -> InstantPage {
            return InstantPage(blocks: page.blocks, rawMedia: page.rawMedia.mapValues { media in
                return augmentMediaWithReference(.message(message: MessageReference(source), media: media))
            }, isComplete: page.isComplete, rtl: page.rtl, url: page.url, views: page.views)
        }
        hasRichMedia = hasRichMedia || !rich.instantPage.rawMedia.isEmpty
        return RichTextMessageAttribute(instantPage: pageWithSourceReferences(rich.instantPage),
            fullInstantPage: rich.fullInstantPage.map(pageWithSourceReferences))
    }
    if media is TelegramMediaImage || media is TelegramMediaFile || hasRichMedia {
        // This persistent bit survives retry/relaunch. Reusing the protected cloud
        // photo/document reference is still rejected even without a forward header.
        attributes.append(OutgoingMessageInfoAttribute(uniqueId: 0, flags: [.requiresMediaUpload], acknowledged: false,
            correlationId: nil, bubbleUpEmojiOrStickersets: [], partialReference: nil))
    }
    return .message(text: hidesCaption ? "" : source.text, attributes: attributes, inlineStickers: [:],
        mediaReference: media.map { .message(message: MessageReference(source), media: $0) }, threadId: threadId,
        replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: groupingKey, correlationId: correlationId,
        bubbleUpEmojiOrStickersets: [])
}

func codeGramRequiresMediaUpload(_ attributes: [MessageAttribute]) -> Bool {
    return attributes.contains(where: { ($0 as? OutgoingMessageInfoAttribute)?.flags.contains(.requiresMediaUpload) == true })
}

/// Audio-player and share-sheet sends already request a new message, rather than
/// a forward. Their source may be carried on the wrapper or on the stored medium.
func codeGramSourceMessageReference(_ reference: AnyMediaReference) -> MessageReference? {
    if case let .message(message, _) = reference { return message }
    let partialReference: PartialMediaReference?
    if let file = reference.media as? TelegramMediaFile {
        partialReference = file.partialReference
    } else if let image = reference.media as? TelegramMediaImage {
        partialReference = image.partialReference
    } else { partialReference = nil }
    if case let .message(message)? = partialReference { return message }
    return nil
}

func codeGramProtectedDirectMediaMessage(_ message: EnqueueMessage, source: Message, destination: PeerId,
    accountPeerId: PeerId, enabled: Bool, cachedUserData: CachedUserData?) -> EnqueueMessage? {
    guard enabled, destination == accountPeerId, source.id.namespace == Namespaces.Message.Cloud,
        codeGramHasServerCopyProtection(source, cachedUserData: cachedUserData),
        case let .message(text, attributes, inlineStickers, mediaReference, threadId, reply, story, groupingKey, correlationId, bubbleUp) = message,
        let mediaReference, mediaReference.media is TelegramMediaImage || mediaReference.media is TelegramMediaFile,
        codeGramSourceMessageReference(mediaReference)?.id == source.id else { return nil }
    var attributes = attributes
    if !codeGramRequiresMediaUpload(attributes) {
        attributes.append(OutgoingMessageInfoAttribute(uniqueId: 0, flags: [.requiresMediaUpload], acknowledged: false,
            correlationId: nil, bubbleUpEmojiOrStickersets: [], partialReference: nil))
    }
    let sourceReference = MessageReference(source)
    let partialReference = PartialMediaReference.message(message: sourceReference)
    let media: Media
    if let file = mediaReference.media as? TelegramMediaFile {
        media = file.withUpdatedPartialReference(partialReference)
    } else if let image = mediaReference.media as? TelegramMediaImage {
        media = TelegramMediaImage(imageId: image.imageId, representations: image.representations,
            videoRepresentations: image.videoRepresentations, immediateThumbnailData: image.immediateThumbnailData,
            emojiMarkup: image.emojiMarkup, reference: image.reference, partialReference: partialReference, flags: image.flags, video: image.video)
    } else { return nil }
    return .message(text: text, attributes: attributes, inlineStickers: inlineStickers,
        mediaReference: .message(message: sourceReference, media: media), threadId: threadId,
        replyToMessageId: reply, replyToStoryId: story, localGroupingKey: groupingKey,
        correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUp)
}

/// The paired document is part of its photo's message, although API photo parsing
/// does not attach that message reference to the nested file itself.
func codeGramPhotoVideoForUpload(_ video: TelegramMediaFile, photo: TelegramMediaImage) -> TelegramMediaFile {
    guard video.partialReference == nil, let partialReference = photo.partialReference else { return video }
    return video.withUpdatedPartialReference(partialReference)
}
