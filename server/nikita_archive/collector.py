import asyncio
import hashlib
import json
import time

from telethon import TelegramClient, events, types
from telethon.tl.types import DocumentAttributeAudio, DocumentAttributeFilename, DocumentAttributeVideo

from .archive import Archive


def peer(value):
    if isinstance(value, types.PeerUser):
        return "user", value.user_id
    if isinstance(value, types.PeerChat):
        return "chat", value.chat_id
    if isinstance(value, types.PeerChannel):
        return "channel", value.channel_id
    return None, None


def snapshot(message):
    peer_type, peer_id = peer(message.peer_id)
    if not peer_type or not message.date or isinstance(message, types.MessageService):
        return None
    author_type, author_id = peer(message.from_id)
    media_title = ""
    media = message.media
    if getattr(media, "photo", None):
        media_title = "Фото"
    document = getattr(media, "document", None)
    if document:
        media_title = "Файл"
        for attribute in document.attributes:
            if isinstance(attribute, DocumentAttributeAudio):
                media_title = "Голосовое сообщение" if attribute.voice else "Аудио"
            elif isinstance(attribute, DocumentAttributeVideo):
                media_title = "Видеосообщение" if attribute.round_message else "Видео"
            elif isinstance(attribute, DocumentAttributeFilename):
                media_title = attribute.file_name
    # Only hash media identifiers and entities; neither access_hash nor file_reference
    # is exposed through the archive API. Binary media is not downloaded by this service.
    content = {"text": message.message or "", "media_id": getattr(document, "id", None) or getattr(getattr(media, "photo", None), "id", None),
        "media_type": type(media).__name__, "entities": [item.to_dict() for item in message.entities or []]}
    fingerprint = hashlib.sha256(json.dumps(content, sort_keys=True, default=str).encode()).hexdigest()
    reply = getattr(message, "reply_to", None)
    thread_id = None
    if reply and getattr(reply, "forum_topic", False):
        thread_id = getattr(reply, "reply_to_top_id", None) or getattr(reply, "reply_to_msg_id", None)
    return {"peer_type": peer_type, "peer_id": peer_id, "message_id": message.id,
        "author_type": author_type, "author_id": author_id, "outgoing": bool(message.out),
        "date": int(message.date.timestamp()), "version_date": int((message.edit_date or message.date).timestamp()),
        "thread_id": thread_id, "text": message.message or "", "media_title": media_title,
        "media_id": content["media_id"], "fingerprint": fingerprint}


def client_for(config):
    return TelegramClient(str(config["session_path"]), int(config["api_id"]), config["api_hash"],
        device_model="Nikita Archive VPS", app_version="2.0", system_version="Linux",
        sequential_updates=True, auto_reconnect=True, catch_up=True)


async def collect(config):
    archive = Archive(config["database_path"])
    client = client_for(config)

    async def observe(event):
        item = snapshot(event.message)
        if item:
            archive.observe(item)

    client.add_event_handler(observe, events.NewMessage())
    client.add_event_handler(observe, events.MessageEdited())

    async def deleted(event):
        # Private/basic-group deletes carry only globally unique message IDs.
        # Channel deletes need the channel namespace; equal IDs in other channels
        # must never cause unrelated messages to be marked deleted.
        channel_id = getattr(event, "channel_id", None)
        if channel_id is None and event.chat_id and event.chat_id < -1000000000000:
            channel_id = -event.chat_id - 1000000000000
        archive.delete(list(event.deleted_ids), channel_id=channel_id)

    client.add_event_handler(deleted, events.MessageDeleted())

    async def connection_monitor():
        while True:
            archive.set_connected(client.is_connected())
            await asyncio.sleep(30)

    await client.connect()
    if not await client.is_user_authorized():
        await client.disconnect()
        raise RuntimeError("First run: nikita-archive --config <path> login")
    me = await client.get_me()
    archive.set_account(me.id)
    monitor = asyncio.create_task(connection_monitor())
    try:
        # Register handlers BEFORE catch-up. The baseline is only what still
        # exists now; it cannot reconstruct versions already lost before setup.
        await client.catch_up()
        async for dialog in client.iter_dialogs(limit=int(config.get("seed_dialogs", 100))):
            async for message in client.iter_messages(dialog.entity, limit=int(config.get("seed_messages", 100))):
                item = snapshot(message)
                if item:
                    archive.observe(item, seed=True)
        await client.run_until_disconnected()
    finally:
        monitor.cancel()
        await asyncio.gather(monitor, return_exceptions=True)
        archive.set_connected(False)
        await client.disconnect()
