"""Durable private attachment queue and immutable, authenticated blob storage."""
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time

CHUNK = 512 * 1024
MAX_MEDIA_SIZE = 8 * 1024**3
BLOB_ID = re.compile(r"^[a-f0-9]{64}$")


class MediaStore:
    def __init__(self, archive, config):
        self.archive = archive
        self.root = Path(config.get("media_path", Path(archive.path).parent/"media"))
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        self.enabled = bool(config.get("media_enabled", True))
        self.reserve = max(0, int(config.get("media_min_free_bytes", 1024**3)))
        self.workers = max(2, min(4, int(config.get("media_workers", 3))))
        self.reservations = {}
        with archive.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS media_assets(
                    id TEXT PRIMARY KEY, request TEXT NOT NULL, size INTEGER NOT NULL,
                    mime TEXT NOT NULL, priority INTEGER NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending', sha256 TEXT NOT NULL DEFAULT '',
                    attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0,
                    error TEXT NOT NULL DEFAULT '', mtime_ns INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS media_queue ON media_assets(state,retry_at,priority);
                CREATE TABLE IF NOT EXISTS media_catalog(
                    original_id INTEGER NOT NULL, kind TEXT NOT NULL, descriptor TEXT NOT NULL,
                    PRIMARY KEY(original_id,kind));
            """)

    def recover(self):
        with self.archive.connect() as db:
            db.execute("UPDATE media_assets SET state='pending' WHERE state='downloading'")

    def path(self, identifier, partial=False):
        if not isinstance(identifier, str) or not BLOB_ID.fullmatch(identifier):
            raise ValueError("Invalid blob identifier")
        return self.root/(identifier + (".part" if partial else ".blob"))

    def register(self, identity, request, size, mime, priority):
        if not isinstance(size, int) or not 0 < size <= MAX_MEDIA_SIZE:
            return None
        identifier = hashlib.sha256(identity.encode()).hexdigest()
        mime = mime if re.fullmatch(r"[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+", mime or "") else "application/octet-stream"
        with self.archive.connect() as db:
            db.execute("""INSERT INTO media_assets(id,request,size,mime,priority) VALUES(?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET request=excluded.request,
                priority=MAX(media_assets.priority,excluded.priority),
                state=CASE WHEN media_assets.state='failed' THEN 'pending' ELSE media_assets.state END,
                attempts=CASE WHEN media_assets.state='failed' THEN 0 ELSE media_assets.attempts END,
                retry_at=CASE WHEN media_assets.state='failed' THEN 0 ELSE media_assets.retry_at END""",
                (identifier, json.dumps(request), size, mime, priority))
        return {"blob_id": identifier, "size": size}

    def catalog(self, descriptor):
        with self.archive.connect() as db:
            db.execute("INSERT OR REPLACE INTO media_catalog VALUES(?,?,?)",
                (descriptor["id"], descriptor["kind"], json.dumps(descriptor, separators=(",", ":"))))

    def claim(self, small_only=False):
        if not self.enabled:
            return None
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            maximum = 16*1024**2 if small_only else MAX_MEDIA_SIZE
            candidates = db.execute("SELECT id,request,size,mime,attempts FROM media_assets WHERE state='pending' AND retry_at<=? AND size<=? ORDER BY priority DESC,size,rowid LIMIT 128",
                (time.time(), maximum)).fetchall()
            available = max(0, shutil.disk_usage(self.root).free - self.reserve - sum(self.reservations.values()))
            for identifier, request, size, mime, attempts in candidates:
                partial = self.path(identifier, partial=True)
                offset = partial.stat().st_size if partial.exists() else 0
                remaining = max(0, size - offset)
                if remaining > available:
                    db.execute("UPDATE media_assets SET error='waiting_for_disk' WHERE id=?", (identifier,))
                    continue
                db.execute("UPDATE media_assets SET state='downloading',error='' WHERE id=?", (identifier,))
                self.reservations[identifier] = remaining
                return dict(id=identifier, request=json.loads(request), size=size, mime=mime, attempts=attempts)
        return None

    def complete(self, job, digest):
        destination = self.path(job["id"])
        os.replace(self.path(job["id"], partial=True), destination)
        os.chmod(destination, 0o600)
        info = destination.stat()
        with self.archive.connect() as db:
            db.execute("UPDATE media_assets SET state='ready',sha256=?,error='',mtime_ns=? WHERE id=?",
                (digest, info.st_mtime_ns, job["id"]))

    def defer(self, job, error, delay=None):
        attempts = job["attempts"] + 1
        with self.archive.connect() as db:
            db.execute("UPDATE media_assets SET state=?,attempts=?,retry_at=?,error=? WHERE id=?",
                ("failed" if attempts >= 8 else "pending", attempts,
                 time.time() + (delay if delay is not None else min(3600, 15 * 2**min(attempts, 8))),
                 type(error).__name__[:64], job["id"]))

    async def download(self, client, job):
        from telethon.extensions import BinaryReader
        from telethon import types
        temporary = self.path(job["id"], partial=True)
        request = job["request"]
        offset = temporary.stat().st_size if temporary.exists() else 0
        offset = min(offset, job["size"])
        # Telegram requires aligned offsets. Re-fetch a partial trailing block.
        if offset != job["size"]:
            offset -= offset % CHUNK
        flags = os.O_CREAT | os.O_RDWR
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "r+b") as output:
            output.truncate(offset)
            output.seek(offset)
            if "inline" in request:
                data = base64.b64decode(request["inline"], validate=True)
                if len(data) != job["size"]:
                    raise ValueError("Inline attachment size mismatch")
                output.seek(0)
                await asyncio.to_thread(output.write, data)
                offset = len(data)
            elif offset < job["size"]:
                with BinaryReader(base64.b64decode(request["location"], validate=True)) as reader:
                    location = reader.tgread_object()
                if not isinstance(location, (types.InputDocumentFileLocation, types.InputPhotoFileLocation)):
                    raise ValueError("Unsupported stored file location")
                async for data in client.iter_download(location, offset=offset, request_size=CHUNK,
                        file_size=job["size"], dc_id=request["dc_id"]):
                    if not data:
                        continue
                    if offset + len(data) > job["size"]:
                        raise ValueError("Attachment exceeded its declared size")
                    if shutil.disk_usage(self.root).free < len(data) + self.reserve:
                        raise OSError("Insufficient attachment storage")
                    await asyncio.to_thread(output.write, data)
                    offset += len(data)
                    self.reservations[job["id"]] = max(0, job["size"] - offset)
            output.flush()
            await asyncio.to_thread(os.fsync, output.fileno())
        if offset != job["size"]:
            raise ValueError("Incomplete Telegram download")
        def checksum():
            digest = hashlib.sha256()
            with temporary.open("rb") as source:
                for data in iter(lambda: source.read(1024*1024), b""):
                    digest.update(data)
            return digest.hexdigest()
        digest = await asyncio.to_thread(checksum)
        self.complete(job, digest)

    async def worker(self, client, small_only=False):
        while True:
            job = self.claim(small_only)
            if job is None:
                await asyncio.sleep(1)
                continue
            try:
                await self.download(client, job)
            except asyncio.CancelledError:
                with self.archive.connect() as db:
                    db.execute("UPDATE media_assets SET state='pending' WHERE id=? AND state='downloading'", (job["id"],))
                raise
            except Exception as error:
                # A queued reference may expire while Telegram still has the
                # message. Refresh that reference once; deletion is not treated
                # as recoverable content and never creates an invented file.
                source = job["request"].get("source")
                if type(error).__name__ in ("FileReferenceExpiredError", "FileReferenceInvalidError") and source:
                    try:
                        from telethon import types
                        from .media_capture import MediaCapture
                        peers = {"PeerUser":types.PeerUser,"PeerChat":types.PeerChat,"PeerChannel":types.PeerChannel}
                        message = await client.get_messages(peers[source["type"]](source["id"]), ids=source["message_id"])
                        if message is not None:
                            MediaCapture(self).capture(message)
                            with self.archive.connect() as db:
                                row = db.execute("SELECT request FROM media_assets WHERE id=?", (job["id"],)).fetchone()
                            job["request"] = json.loads(row[0])
                            await self.download(client,job)
                            continue
                    except Exception as refreshed_error:
                        error = refreshed_error
                self.defer(job, error, getattr(error, "seconds", None))
            finally:
                self.reservations.pop(job["id"], None)

    def ready(self, identifier):
        path = self.path(identifier)
        with self.archive.connect() as db:
            row = db.execute("SELECT state,size,mime,sha256,mtime_ns FROM media_assets WHERE id=?", (identifier,)).fetchone()
        if not row:
            return "missing", None
        if row[0] != "ready":
            return row[0], None
        try:
            info = path.stat()
        except OSError:
            return "failed", None
        if info.st_size != row[1] or info.st_mtime_ns != row[4]:
            return "failed", None
        return "ready", dict(path=path, size=row[1], mime=row[2], sha256=row[3])

    def stats(self):
        with self.archive.connect() as db:
            counts = dict(db.execute("SELECT state,COUNT(*) FROM media_assets GROUP BY state"))
            waiting = db.execute("SELECT COUNT(*) FROM media_assets WHERE error='waiting_for_disk'").fetchone()[0]
            total = db.execute("SELECT COALESCE(SUM(size),0) FROM media_assets WHERE state='ready'").fetchone()[0]
        return dict(enabled=self.enabled, ready=counts.get("ready",0),
            pending=counts.get("pending",0)+counts.get("downloading",0), failed=counts.get("failed",0),
            waiting_for_disk=waiting, stored_bytes=total, free_bytes=shutil.disk_usage(self.root).free)
