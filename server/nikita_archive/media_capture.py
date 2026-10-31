"""Capture sanitized media metadata and private download references immediately."""
import base64
import math
from pathlib import PurePosixPath


def encoded(data):
    return base64.b64encode(data).decode("ascii") if data else ""


def bounded(value, maximum=100000):
    return max(0, min(maximum, int(value or 0)))


def duration(value):
    value = float(value or 0)
    return min(value, 2147483647) if math.isfinite(value) and value > 0 else 0


class MediaCapture:
    def __init__(self, store):
        self.store = store
        self.source = None

    def asset(self, identity, location, size, mime, priority, dc_id, inline=None):
        request = {"inline": encoded(inline)} if inline is not None else {
            "location": encoded(bytes(location)), "dc_id": dc_id}
        if self.source is not None:
            request["source"] = self.source
        return self.store.register(identity, request, int(size), mime, priority)

    def representation(self, owner, size, document, priority):
        from telethon import types
        name = type(size).__name__
        if name not in ("PhotoSize", "PhotoCachedSize", "PhotoSizeProgressive", "VideoSize"):
            return None
        inline = getattr(size, "bytes", None)
        length = len(inline) if inline is not None else max(getattr(size, "sizes", []) or [getattr(size, "size", 0)])
        if not length:
            return None
        variant = str(size.type)
        kind = "document" if document else "photo"
        cls = types.InputDocumentFileLocation if document else types.InputPhotoFileLocation
        location = cls(id=owner.id, access_hash=owner.access_hash, file_reference=owner.file_reference,
            thumb_size=variant)
        result = self.asset(f"{kind}:{owner.id}:{variant}", location, length,
            "video/mp4" if name == "VideoSize" else "image/jpeg", priority, owner.dc_id, inline)
        if result is not None:
            result.update(width=max(1, bounded(getattr(size,"w",1))), height=max(1,bounded(getattr(size,"h",1))))
            if name == "VideoSize":
                result["start_timestamp"] = duration(getattr(size,"video_start_ts",0))
        return result

    def photo(self, photo, priority):
        sizes = getattr(photo, "sizes", [])
        candidates = [size for size in sizes if type(size).__name__ in ("PhotoSize", "PhotoCachedSize", "PhotoSizeProgressive")]
        candidates.sort(key=lambda size: int(getattr(size,"w",0))*int(getattr(size,"h",0)))
        if not candidates:
            return None
        full = self.representation(photo, candidates[-1], False, priority)
        if full is None:
            return None
        preview = self.representation(photo, candidates[0], False, priority+20) if len(candidates)>1 else None
        stripped = next((getattr(size,"bytes",b"") for size in sizes if type(size).__name__=="PhotoStrippedSize"), b"")
        result = dict(kind="photo", id=photo.id, asset=full, preview=preview,
            immediate_thumbnail=encoded(stripped[:8192]), videos=[])
        for size in getattr(photo,"video_sizes",[]) or []:
            video = self.representation(photo,size,False,priority)
            if video:
                result["videos"].append(video)
        self.store.catalog(result)
        return result

    def document(self, document, priority):
        from telethon import types
        if not isinstance(document, types.Document):
            return None
        full = self.asset(f"document:{document.id}:full", types.InputDocumentFileLocation(
            id=document.id,access_hash=document.access_hash,file_reference=document.file_reference,thumb_size=""),
            document.size,document.mime_type,priority+(10 if document.size<=16*1024**2 else 0),document.dc_id)
        if full is None:
            return None
        result = dict(kind="document",id=document.id,asset=full,mime_type=document.mime_type,
            file_name="file",width=0,height=0,duration=0,voice=False,round_video=False,streaming=False,
            animated=False,sticker=False,custom_emoji=False,alt="",premium=False,single_color=False,
            title="",performer="",waveform="",video_codec="",preview=None,immediate_thumbnail="")
        for attribute in document.attributes:
            name = type(attribute).__name__
            if name == "DocumentAttributeFilename":
                filename = str(attribute.file_name).replace("\\","/").replace("\0","")
                result["file_name"] = PurePosixPath(filename).name[:255] or "file"
            elif name == "DocumentAttributeImageSize":
                result.update(width=bounded(attribute.w),height=bounded(attribute.h))
            elif name == "DocumentAttributeAudio":
                result.update(voice=bool(attribute.voice),duration=duration(attribute.duration),
                    title=(attribute.title or "")[:512],performer=(attribute.performer or "")[:512],
                    waveform=encoded((attribute.waveform or b"")[:8192]),audio=True)
            elif name == "DocumentAttributeVideo":
                result.update(width=bounded(attribute.w),height=bounded(attribute.h),duration=duration(attribute.duration),
                    round_video=bool(attribute.round_message),streaming=bool(attribute.supports_streaming),video=True,
                    video_codec=(getattr(attribute,"video_codec","") or "")[:64])
            elif name == "DocumentAttributeAnimated":
                result["animated"] = True
            elif name == "DocumentAttributeSticker":
                result.update(sticker=True,alt=(attribute.alt or "")[:256])
            elif name == "DocumentAttributeCustomEmoji":
                result.update(custom_emoji=True,alt=(attribute.alt or "")[:256],premium=not bool(attribute.free),
                    single_color=bool(getattr(attribute,"text_color",False)))
        previews = [size for size in document.thumbs or [] if type(size).__name__ in ("PhotoSize","PhotoCachedSize","PhotoSizeProgressive")]
        if previews:
            size = max(previews,key=lambda size:int(size.w)*int(size.h))
            result["preview"] = self.representation(document,size,True,priority+20)
        stripped = next((size.bytes for size in document.thumbs or [] if type(size).__name__=="PhotoStrippedSize"),b"")
        result["immediate_thumbnail"] = encoded(stripped[:8192])
        self.store.catalog(result)
        return result

    def capture(self, message, seed=False):
        if not self.store.enabled:
            return None
        priority = 0 if seed else 100
        peer = message.peer_id
        self.source = dict(type=type(peer).__name__, id=getattr(peer,"user_id",None) or
            getattr(peer,"chat_id",None) or getattr(peer,"channel_id",None), message_id=message.id)
        media = message.media
        photo = getattr(media,"photo",None)
        if photo is not None:
            result = self.photo(photo,priority)
            if result and getattr(media,"video",None) is not None:
                result["live_video"] = self.document(media.video,priority)
                self.store.catalog(result)
            return result
        document = getattr(media,"document",None)
        if document is not None:
            result = self.document(document,priority)
            if result:
                cover = getattr(media,"video_cover",None)
                if cover is not None:
                    result["cover"] = self.photo(cover,priority+10)
                alternatives = [self.document(item,priority-10) for item in (getattr(media,"alt_documents",[]) or [])[:8]]
                result["alternatives"] = [item for item in alternatives if item]
                self.store.catalog(result)
            return result
        return None
