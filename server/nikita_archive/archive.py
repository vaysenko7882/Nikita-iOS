"""Atomic revision journal. No Telegram credentials or network dependency here."""
from __future__ import annotations

import json
from contextlib import contextmanager
from pathlib import Path
import sqlite3
import time
import uuid


class Archive:
    def __init__(self, path: str | Path):
        self.path = str(path)
        self.media = None
        Path(self.path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(
                    peer_type TEXT NOT NULL, peer_id INTEGER NOT NULL, message_id INTEGER NOT NULL,
                    payload TEXT NOT NULL, fingerprint TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(peer_type, peer_id, message_id));
                CREATE INDEX IF NOT EXISTS by_message_id ON messages(message_id, peer_type);
                CREATE TABLE IF NOT EXISTS events(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL);
            """)
            db.execute("INSERT OR IGNORE INTO meta VALUES('server_id', ?)", (str(uuid.uuid4()),))

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA busy_timeout=30000")
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def _meta(db, key, default=""):
        row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else default

    @property
    def server_id(self):
        with self.connect() as db:
            return self._meta(db, "server_id")

    def set_account(self, account_id: int):
        with self.connect() as db:
            previous = self._meta(db, "account_id")
            if previous and int(previous) != account_id:
                raise ValueError("This archive belongs to a different Telegram account. Use a new data directory.")
            db.execute("INSERT OR REPLACE INTO meta VALUES('account_id', ?)", (str(account_id),))

    def set_connected(self, connected: bool):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO meta VALUES('connected', ?)", ("1" if connected else "0",))
            db.execute("INSERT OR REPLACE INTO meta VALUES('last_connection_check', ?)", (str(int(time.time())),))

    def observe(self, snapshot: dict, *, seed: bool = False):
        required = ("peer_type", "peer_id", "message_id", "text", "fingerprint", "version_date")
        if not all(key in snapshot for key in required):
            raise ValueError("Incomplete message snapshot")
        if snapshot["peer_type"] not in ("user", "chat", "channel") or snapshot["message_id"] <= 0:
            raise ValueError("Invalid cloud message")
        key = (snapshot["peer_type"], snapshot["peer_id"], snapshot["message_id"])
        payload = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"))
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload, fingerprint, deleted FROM messages WHERE peer_type=? AND peer_id=? AND message_id=?", key).fetchone()
            if row:
                previous = json.loads(row[0])
                if row[2] or snapshot["version_date"] < previous["version_date"]:
                    return
                if snapshot["fingerprint"] == row[1]:
                    # Add attachment descriptors to pre-upgrade snapshots without
                    # inventing a user edit or dropping their previous content.
                    if snapshot.get("media") and not previous.get("media"):
                        db.execute("UPDATE messages SET payload=? WHERE peer_type=? AND peer_id=? AND message_id=?",
                            (payload, *key))
                    return
                # Do not let an initial history page race a newer live update.
                if seed and snapshot["version_date"] <= previous["version_date"]:
                    return
                event = {**previous, "kind": "edit", "captured_at": snapshot["version_date"]}
                event.pop("fingerprint", None)
                db.execute("INSERT INTO events(payload) VALUES(?)", (json.dumps(event, ensure_ascii=False),))
            db.execute("INSERT INTO messages(peer_type,peer_id,message_id,payload,fingerprint) VALUES(?,?,?,?,?) ON CONFLICT(peer_type,peer_id,message_id) DO UPDATE SET payload=excluded.payload, fingerprint=excluded.fingerprint", (*key, payload, snapshot["fingerprint"]))

    def delete(self, message_ids: list[int], *, channel_id: int | None = None, captured_at: int | None = None):
        captured_at = captured_at or int(time.time())
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            for message_id in message_ids:
                if channel_id is None:
                    rows = db.execute("SELECT peer_type,peer_id,payload,deleted FROM messages WHERE message_id=? AND peer_type IN ('user','chat')", (message_id,)).fetchall()
                else:
                    rows = db.execute("SELECT peer_type,peer_id,payload,deleted FROM messages WHERE message_id=? AND peer_type='channel' AND peer_id=?", (message_id, channel_id)).fetchall()
                if not rows:
                    value = int(self._meta(db, "unknown_deletions", "0")) + 1
                    db.execute("INSERT OR REPLACE INTO meta VALUES('unknown_deletions', ?)", (str(value),))
                for peer_type, peer_id, payload, already_deleted in rows:
                    if already_deleted:
                        continue
                    event = {**json.loads(payload), "kind": "delete", "captured_at": captured_at}
                    if self.media is not None:
                        def urgent(value):
                            if isinstance(value,dict):
                                if "blob_id" in value:
                                    db.execute("UPDATE media_assets SET priority=MAX(priority,1000),retry_at=0 WHERE id=? AND state='pending'",(value["blob_id"],))
                                for child in value.values(): urgent(child)
                            elif isinstance(value,list):
                                for child in value: urgent(child)
                        urgent(event.get("media"))
                    event.pop("fingerprint", None)
                    db.execute("INSERT INTO events(payload) VALUES(?)", (json.dumps(event, ensure_ascii=False),))
                    db.execute("UPDATE messages SET deleted=1 WHERE peer_type=? AND peer_id=? AND message_id=?", (peer_type, peer_id, message_id))

    def sync(self, after: int, *, server_id: str = "", limit: int = 100):
        if after < 0:
            raise ValueError("Cursor must be nonnegative")
        limit = max(1, min(200, limit))
        with self.connect() as db:
            # One read transaction: account, epoch, cursor and events are consistent.
            db.execute("BEGIN")
            identity = self._meta(db, "server_id")
            head = db.execute("SELECT COALESCE(MAX(seq), 0) FROM events").fetchone()[0]
            reset = bool(server_id and server_id != identity) or after > head
            rows = [] if reset else db.execute("SELECT seq,payload FROM events WHERE seq>? ORDER BY seq LIMIT ?", (after, limit + 1)).fetchall()
            selected = []
            response_bytes = 0
            for row in rows[:limit]:
                size = len(row[1].encode("utf-8")) + 64
                if selected and response_bytes + size > 2 * 1024 * 1024:
                    break
                selected.append(row)
                response_bytes += size
            last_check = int(self._meta(db, "last_connection_check", "0"))
            events = [{**json.loads(payload), "seq": seq} for seq, payload in selected]
            if self.media is not None:
                for event in events:
                    if not event.get("media") and event.get("media_id") is not None:
                        known = db.execute("SELECT descriptor FROM media_catalog WHERE original_id=? LIMIT 2", (event["media_id"],)).fetchall()
                        if len(known) == 1:
                            event["media"] = json.loads(known[0][0])
                    def enrich(value):
                        if isinstance(value, dict):
                            if "blob_id" in value:
                                row = db.execute("SELECT state,sha256 FROM media_assets WHERE id=?", (value["blob_id"],)).fetchone()
                                if row:
                                    value.update(state=row[0], sha256=row[1])
                            for child in list(value.values()):
                                enrich(child)
                        elif isinstance(value, list):
                            for child in value:
                                enrich(child)
                    enrich(event.get("media"))
                response_bytes = 0
                for index, event in enumerate(events):
                    size = len(json.dumps(event,ensure_ascii=False).encode())
                    if index and response_bytes + size > 2 * 1024 * 1024:
                        events = events[:index]
                        selected = selected[:index]
                        break
                    response_bytes += size
            return {"protocol": 1, "server_id": identity, "account_id": int(self._meta(db, "account_id", "0")),
                "reset_required": reset, "next_cursor": 0 if reset else selected[-1][0] if selected else after,
                "has_more": len(rows) > len(selected), "events": events,
                "media_stats": self.media.stats() if self.media is not None else None,
                "connected": self._meta(db, "connected") == "1" and time.time() - last_check < 90,
                "unknown_deletions": int(self._meta(db, "unknown_deletions", "0"))}
