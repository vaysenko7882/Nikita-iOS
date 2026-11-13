"""Ephemeral live-audio relay for На связи. No audio is written to disk."""
from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from aiohttp import web, WSMsgType

MAX_AUDIO = 4096
MAX_CLIENTS = 64
MAX_ROOMS = 512
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def check_hello(message: dict, nonce: str) -> tuple[str, bytes, str, str]:
    if message.get("type") != "hello":
        raise ValueError("hello required")
    room, key, identifier = message.get("room"), message.get("key"), message.get("id")
    if not isinstance(room, str) or not HEX64.fullmatch(room) or not isinstance(key, str) or not HEX64.fullmatch(key):
        raise ValueError("invalid room")
    if not isinstance(identifier, str) or str(uuid.UUID(identifier)) != identifier:
        raise ValueError("invalid participant")
    name = message.get("name")
    if not isinstance(name, str) or not name.strip() or len(name) > 24:
        raise ValueError("invalid name")
    expected = hmac.digest(bytes.fromhex(key), f"{nonce}:{identifier}:{room}".encode(), "sha256")
    try:
        supplied = base64.b64decode(message.get("proof", ""), validate=True)
    except (ValueError, TypeError):
        raise ValueError("invalid proof") from None
    if not hmac.compare_digest(expected, supplied):
        raise ValueError("invalid proof")
    return room, bytes.fromhex(key), identifier, name.strip()


def audio_packet(data: bytes) -> tuple[str, str | None, bytes]:
    if not 34 < len(data) <= MAX_AUDIO + 34 or data[:2] != b"\x01\x00":
        raise ValueError("invalid audio frame")
    sender = str(uuid.UUID(bytes=data[2:18]))
    target = None if data[18:34] == bytes(16) else str(uuid.UUID(bytes=data[18:34]))
    return sender, target, data[34:]


@dataclass
class PushRegistration:
    token: str
    channel: str
    name: str
    updated: float = field(default_factory=time.monotonic)


@dataclass
class Client:
    identifier: str
    name: str
    ws: web.WebSocketResponse
    outgoing: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(64))

    def send(self, payload: bytes | dict) -> None:
        # A slow receiver never causes an unbounded audio backlog or stalls peers.
        if self.outgoing.full():
            with contextlib.suppress(asyncio.QueueEmpty):
                self.outgoing.get_nowait()
        self.outgoing.put_nowait(payload)


@dataclass
class Room:
    key: bytes
    clients: dict[str, Client] = field(default_factory=dict)
    push: dict[str, PushRegistration] = field(default_factory=dict)
    speaker: str | None = None
    speaker_name: str = ""
    target: str | None = None
    last_audio: float = 0
    started: float = 0
    touched: float = field(default_factory=time.monotonic)
    # Up to 1.5 seconds of transient network pre-roll, removed on talk end.
    preroll: deque = field(default_factory=lambda: deque(maxlen=75))

    def recipients(self, source: str, target: str | None):
        return [client for identifier, client in self.clients.items() if identifier != source and (target is None or target == identifier)]

    def participants(self) -> None:
        names = {key: registration.name for key, registration in self.push.items()}
        names.update({key: client.name for key, client in self.clients.items()})
        payload = {"type": "peers", "peers": [{"id": key, "name": name} for key, name in names.items()]}
        for client in self.clients.values():
            client.send(payload)

    def end(self) -> None:
        if self.speaker:
            payload = {"type": "talk", "id": self.speaker, "name": self.speaker_name, "active": False, "target": self.target}
            for client in self.recipients(self.speaker, self.target):
                client.send(payload)
        self.speaker = None
        self.target = None
        self.preroll.clear()


class APNs:
    def __init__(self):
        self.team = os.getenv("APNS_TEAM_ID", "")
        self.key_id = os.getenv("APNS_KEY_ID", "")
        self.bundle = os.getenv("APNS_BUNDLE_ID", "app.nasvyazi.walkie")
        key_path = os.getenv("APNS_PRIVATE_KEY_PATH", "")
        self.private_key = Path(key_path).read_text() if key_path else ""
        self.sandbox = os.getenv("APNS_SANDBOX", "0") == "1"
        self.jwt = None
        self.jwt_at = 0.0
        self.client = None

    async def start(self):
        if self.team and self.key_id and self.private_key:
            import httpx
            self.client = httpx.AsyncClient(http2=True, timeout=8)

    async def close(self):
        if self.client:
            await self.client.aclose()

    async def wake(self, registration: PushRegistration, speaker: str) -> bool:
        if self.client is None:
            return True
        import jwt
        if not self.jwt or time.time() - self.jwt_at > 3000:
            self.jwt_at = time.time()
            self.jwt = jwt.encode({"iss": self.team, "iat": int(self.jwt_at)}, self.private_key, algorithm="ES256", headers={"kid": self.key_id})
        host = "api.sandbox.push.apple.com" if self.sandbox else "api.push.apple.com"
        try:
            response = await self.client.post(
                f"https://{host}/3/device/{registration.token}",
                headers={"authorization": "bearer " + self.jwt, "apns-topic": self.bundle + ".voip-ptt",
                         "apns-push-type": "pushtotalk", "apns-priority": "10", "apns-expiration": "0"},
                json={"aps": {}, "channelUUID": registration.channel, "speakerName": speaker},
            )
            # Expired ephemeral channel tokens must not be retried indefinitely.
            return response.status_code not in (400, 410)
        except Exception:
            return True


async def writer(client: Client):
    while not client.ws.closed:
        payload = await client.outgoing.get()
        if isinstance(payload, bytes):
            await client.ws.send_bytes(payload)
        else:
            await client.ws.send_json(payload)


async def wake_participants(room: Room, source: str, target: str | None, apns: APNs):
    speaker = room.speaker_name
    for identifier, registration in list(room.push.items()):
        if identifier == source or (target is not None and target != identifier):
            continue
        valid = await apns.wake(registration, speaker)
        if not valid and room.push.get(identifier) is registration:
            room.push.pop(identifier, None)


async def websocket(request: web.Request):
    access = request.app["access_token"]
    if access and not hmac.compare_digest(request.headers.get("Authorization", ""), "Bearer " + access):
        raise web.HTTPUnauthorized(text="Access token required")
    if sum(len(room.clients) for room in request.app["rooms"].values()) >= 2048:
        raise web.HTTPServiceUnavailable(text="Capacity reached")
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=8192, compress=False)
    await ws.prepare(request)
    nonce = base64.b64encode(secrets.token_bytes(32)).decode()
    await ws.send_json({"type": "challenge", "nonce": nonce})
    client = room = None
    task = None
    try:
        first = await asyncio.wait_for(ws.receive(), 10)
        if first.type != WSMsgType.TEXT:
            raise ValueError("hello required")
        room_id, key, identifier, name = check_hello(json.loads(first.data), nonce)
        rooms = request.app["rooms"]
        room = rooms.get(room_id)
        if room is None:
            if len(rooms) >= MAX_ROOMS:
                raise ValueError("server capacity reached")
            room = rooms[room_id] = Room(key)
        if not hmac.compare_digest(room.key, key):
            raise ValueError("room authentication failed")
        if len(room.clients) >= MAX_CLIENTS:
            raise ValueError("room capacity reached")
        old = room.clients.get(identifier)
        if old:
            await old.ws.close(code=4001, message=b"Reconnected")
        client = Client(identifier, name, ws)
        room.clients[identifier] = client
        room.touched = time.monotonic()
        task = asyncio.create_task(writer(client))
        client.send({"type": "welcome", "id": identifier, "apnsConfigured": request.app["apns"].client is not None})
        room.participants()
        if room.speaker and room.speaker != identifier and (room.target is None or room.target == identifier):
            client.send({"type": "talk", "id": room.speaker, "name": room.speaker_name, "active": True, "target": room.target})
            for timestamp, frame in room.preroll:
                if time.monotonic() - timestamp <= 1.5:
                    client.send(frame)
        window = time.monotonic()
        frames = 0
        async for message in ws:
            now = time.monotonic()
            room.touched = now
            if now - window > 1:
                window, frames = now, 0
            frames += 1
            if frames > 100:
                raise ValueError("message rate exceeded")
            if message.type == WSMsgType.TEXT:
                data = json.loads(message.data)
                if not isinstance(data, dict):
                    raise ValueError("invalid control")
                if data.get("type") == "talk":
                    target = data.get("target")
                    if target is not None and (not isinstance(target, str) or str(uuid.UUID(target)) != target):
                        raise ValueError("invalid target")
                    if data.get("active") is True:
                        if room.speaker and room.speaker != identifier:
                            client.send({"type": "busy", "message": "Сейчас говорит другой участник."})
                            continue
                        room.speaker, room.speaker_name, room.target = identifier, name, target
                        room.last_audio = room.started = now
                        room.preroll.clear()
                        event = {"type": "talk", "id": identifier, "name": name, "active": True, "target": target}
                        for receiver in room.recipients(identifier, target):
                            receiver.send(event)
                        asyncio.create_task(wake_participants(room, identifier, target, request.app["apns"]))
                    elif data.get("active") is False and room.speaker == identifier:
                        room.end()
                elif data.get("type") == "pushToken":
                    token, channel = data.get("token"), data.get("channelUUID")
                    if token is None:
                        room.push.pop(identifier, None)
                    elif isinstance(token, str) and 16 <= len(token) <= 1024 and re.fullmatch(r"[0-9a-f]+", token) and isinstance(channel, str):
                        channel = str(uuid.UUID(channel))
                        room.push[identifier] = PushRegistration(token, channel, name)
                    else:
                        raise ValueError("invalid push registration")
                    room.participants()
                else:
                    raise ValueError("unknown control")
            elif message.type == WSMsgType.BINARY:
                sender, target, _ = audio_packet(message.data)
                if sender != identifier or room.speaker != identifier or target != room.target:
                    continue
                if now - room.started > 120:
                    room.end()
                    client.send({"type": "busy", "message": "Передача ограничена двумя минутами. Отпустите кнопку и нажмите снова."})
                    continue
                room.last_audio = now
                room.preroll.append((now, message.data))
                for receiver in room.recipients(identifier, target):
                    receiver.send(message.data)
            elif message.type in (WSMsgType.ERROR, WSMsgType.CLOSE, WSMsgType.CLOSED):
                break
    except (ValueError, TypeError, KeyError, json.JSONDecodeError, asyncio.TimeoutError):
        if not ws.closed:
            await ws.send_json({"type": "error", "message": "Не удалось войти в комнату. Проверьте код и адрес сервера."})
            await ws.close(code=4003, message=b"Invalid session")
    finally:
        if task:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, ConnectionError):
                await task
        if room and client and room.clients.get(client.identifier) is client:
            room.clients.pop(client.identifier, None)
            if room.speaker == client.identifier:
                room.end()
            room.participants()
    return ws


async def lifecycle(app):
    await app["apns"].start()
    async def cleanup():
        while True:
            await asyncio.sleep(1)
            now = time.monotonic()
            for identifier, room in list(app["rooms"].items()):
                if room.speaker and now - room.last_audio > 4:
                    room.end()
                room.push = {key: value for key, value in room.push.items() if now - value.updated < 12 * 3600}
                if not room.clients and now - room.touched > 3600:
                    app["rooms"].pop(identifier, None)
    task = asyncio.create_task(cleanup())
    yield
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await task
    for room in app["rooms"].values():
        for client in room.clients.values():
            await client.ws.close(code=1001, message=b"Server shutdown")
    await app["apns"].close()


def create_app(access_token: str | None = None):
    app = web.Application(client_max_size=8192)
    app["rooms"] = {}
    app["access_token"] = os.getenv("RADIO_ACCESS_TOKEN", "") if access_token is None else access_token
    app["apns"] = APNs()
    app.router.add_get("/ws", websocket)
    app.router.add_get("/health", lambda request: web.json_response({"service": "nasvyazi", "ok": True}))
    app.cleanup_ctx.append(lifecycle)
    return app


if __name__ == "__main__":
    host = os.getenv("HOST", "127.0.0.1")
    if host not in ("127.0.0.1", "::1", "localhost") and not os.getenv("RADIO_ACCESS_TOKEN") and os.getenv("RADIO_ALLOW_PUBLIC") != "1":
        raise SystemExit("Set RADIO_ACCESS_TOKEN before listening publicly; use a TLS reverse proxy.")
    web.run_app(create_app(), host=host, port=int(os.getenv("PORT", "8787")), access_log=None)
