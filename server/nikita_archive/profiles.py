"""Opt-in profile snapshots and an append-only, paginated change journal."""
from __future__ import annotations

import datetime
import json
import time


def public_value(value):
    """Keep received profile metadata, never export Telegram download credentials."""
    if hasattr(value, "to_dict"):
        value = value.to_dict()
    if isinstance(value, dict):
        return {str(k): public_value(v) for k, v in value.items()
                if k not in {"access_hash", "file_reference", "phone", "stripped_thumb", "bytes"}
                and not isinstance(v, (bytes, bytearray))}
    if isinstance(value, (list, tuple)):
        return [public_value(v) for v in value if not isinstance(v, (bytes, bytearray))]
    if isinstance(value, datetime.datetime):
        return int(value.timestamp())
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def blob_ids(value):
    if isinstance(value, dict):
        if isinstance(value.get("blob_id"), str):
            yield value["blob_id"]
        for child in value.values():
            yield from blob_ids(child)
    elif isinstance(value, list):
        for child in value:
            yield from blob_ids(child)


class ProfileStore:
    MAX_PROFILES = 50
    POLL_INTERVAL = 15
    GIFT_INTERVAL = 60

    def __init__(self, archive):
        self.archive = archive
        with archive.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS tracked_profiles(
                    peer_id INTEGER PRIMARY KEY, access_hash TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1, title TEXT NOT NULL DEFAULT '',
                    next_check INTEGER NOT NULL DEFAULT 0, last_check INTEGER NOT NULL DEFAULT 0,
                    error TEXT NOT NULL DEFAULT '', fields TEXT NOT NULL DEFAULT '{}');
                CREATE TABLE IF NOT EXISTS profile_events(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, peer_id INTEGER NOT NULL,
                    kind TEXT NOT NULL, observed_at INTEGER NOT NULL, payload TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS profile_journal ON profile_events(peer_id,seq);
                CREATE TABLE IF NOT EXISTS profile_items(
                    peer_id INTEGER NOT NULL, section TEXT NOT NULL, item_id TEXT NOT NULL,
                    payload TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY(peer_id,section,item_id));
                CREATE TABLE IF NOT EXISTS profile_story_deletions(
                    peer_id INTEGER NOT NULL, story_id TEXT NOT NULL,
                    PRIMARY KEY(peer_id,story_id));
                CREATE TABLE IF NOT EXISTS profile_media(
                    peer_id INTEGER NOT NULL, blob_id TEXT NOT NULL,
                    PRIMARY KEY(peer_id,blob_id));
            """)

    @staticmethod
    def identifier(value):
        if isinstance(value, bool) or not str(value).isdigit() or not 0 < int(value) < 2**63:
            raise ValueError("Invalid cloud user")
        return int(value)

    def configure(self, peer_id, value):
        peer_id = self.identifier(peer_id)
        enabled = value.get("enabled")
        if not isinstance(enabled, bool):
            raise ValueError("enabled must be boolean")
        access_hash = value.get("access_hash")
        if enabled and (isinstance(access_hash, bool) or not isinstance(access_hash, str)
                        or not access_hash.lstrip("-").isdigit()
                        or not -(2**63) <= int(access_hash) < 2**63):
            raise ValueError("A user access hash from this account is required")
        title = str(value.get("title", ""))[:256]
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT enabled FROM tracked_profiles WHERE peer_id=?", (peer_id,)).fetchone()
            if enabled and (not previous or not previous[0]):
                count = db.execute("SELECT COUNT(*) FROM tracked_profiles WHERE enabled=1").fetchone()[0]
                if count >= self.MAX_PROFILES:
                    raise ValueError("Tracking limit reached (50 profiles)")
            if enabled:
                db.execute("""INSERT INTO tracked_profiles(peer_id,access_hash,title) VALUES(?,?,?)
                    ON CONFLICT(peer_id) DO UPDATE SET enabled=1,access_hash=excluded.access_hash,
                    title=CASE WHEN excluded.title!='' THEN excluded.title ELSE title END,next_check=0,error=''""",
                    (peer_id, access_hash, title))
            elif previous:
                db.execute("UPDATE tracked_profiles SET enabled=0 WHERE peer_id=?", (peer_id,))
            if previous is None and enabled or previous is not None and bool(previous[0]) != enabled:
                self._event(db, peer_id, "tracking.enabled" if enabled else "tracking.disabled", {"enabled": enabled})
        return self.status(peer_id)

    def _event(self, db, peer_id, kind, payload, now=None):
        db.execute("INSERT INTO profile_events(peer_id,kind,observed_at,payload) VALUES(?,?,?,?)",
                   (peer_id, kind, int(time.time()) if now is None else int(now),
                    json.dumps(payload, ensure_ascii=False, separators=(",", ":"))))

    def status(self, peer_id=None):
        with self.archive.connect() as db:
            columns = "peer_id,enabled,title,last_check,error"
            if peer_id is None:
                rows = db.execute("SELECT " + columns + " FROM tracked_profiles ORDER BY enabled DESC,title,peer_id").fetchall()
            else:
                rows = db.execute("SELECT " + columns + " FROM tracked_profiles WHERE peer_id=?", (self.identifier(peer_id),)).fetchall()
            profiles = [dict(peer_id=str(p), enabled=bool(e), title=t, last_check=last, error=error) for p,e,t,last,error in rows]
            if peer_id is not None and not profiles:
                profiles = [dict(peer_id=str(peer_id),enabled=False,title="",last_check=0,error="")]
            for item in profiles:
                event_count,last_event = db.execute("SELECT COUNT(*),MAX(observed_at) FROM profile_events WHERE peer_id=?", (int(item["peer_id"]),)).fetchone()
                item["event_count"] = event_count
                item["last_event_at"] = last_event or 0
        return {"profiles": profiles, "poll_interval": self.POLL_INTERVAL, "gift_interval": self.GIFT_INTERVAL,
                "push_updates": True, "target_block_status": "not_exposed_by_telegram"}

    def due(self):
        with self.archive.connect() as db:
            return db.execute("SELECT peer_id,access_hash FROM tracked_profiles WHERE enabled=1 AND next_check<=? ORDER BY next_check,peer_id", (int(time.time()),)).fetchall()

    def access_hash(self, peer_id):
        with self.archive.connect() as db:
            row = db.execute("SELECT access_hash FROM tracked_profiles WHERE peer_id=? AND enabled=1", (peer_id,)).fetchone()
            return row[0] if row else None

    def field_value(self, peer_id, field):
        with self.archive.connect() as db:
            row = db.execute("SELECT fields FROM tracked_profiles WHERE peer_id=? AND enabled=1", (peer_id,)).fetchone()
            return json.loads(row[0]).get(field) if row else None

    def enabled(self, peer_id):
        with self.archive.connect() as db:
            return bool(db.execute("SELECT 1 FROM tracked_profiles WHERE peer_id=? AND enabled=1", (peer_id,)).fetchone())

    def checked(self, peer_id, error="", delay=POLL_INTERVAL):
        now = int(time.time())
        with self.archive.connect() as db:
            db.execute("UPDATE tracked_profiles SET next_check=?,last_check=CASE WHEN ?='' THEN ? ELSE last_check END,error=? WHERE peer_id=?",
                       (now + max(self.POLL_INTERVAL, int(delay)), error, now, error[:128], peer_id))

    def nudge(self, peer_id):
        with self.archive.connect() as db:
            db.execute("UPDATE tracked_profiles SET next_check=MIN(next_check,MAX(?,last_check+2)) WHERE peer_id=? AND enabled=1",(int(time.time()),peer_id))

    def associate(self, peer_id, descriptor):
        with self.archive.connect() as db:
            db.executemany("INSERT OR IGNORE INTO profile_media VALUES(?,?)", [(peer_id,b) for b in set(blob_ids(descriptor))])

    def permits_asset(self, identifier):
        with self.archive.connect() as db:
            return bool(db.execute("SELECT 1 FROM profile_media m JOIN tracked_profiles p ON p.peer_id=m.peer_id WHERE m.blob_id=? AND p.enabled=1 LIMIT 1", (identifier,)).fetchone())

    def fields(self, peer_id, values, *, partial=False):
        values = public_value(values)
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT fields,enabled FROM tracked_profiles WHERE peer_id=?", (peer_id,)).fetchone()
            if not row or not row[1]:
                return
            previous = json.loads(row[0])
            if partial:
                values = {**previous, **values}
            if not previous:
                self._event(db, peer_id, "profile.baseline", {"after": values})
            else:
                for field in sorted(previous.keys() | values.keys()):
                    if previous.get(field) != values.get(field):
                        self._event(db, peer_id, "profile.changed", {"field": field, "before": previous.get(field), "after": values.get(field)})
            title = " ".join(v for v in (values.get("first_name"), values.get("last_name")) if v)
            db.execute("UPDATE tracked_profiles SET fields=?,title=? WHERE peer_id=?",
                       (json.dumps(values,ensure_ascii=False,sort_keys=True),title,peer_id))

    def collection(self, peer_id, section, items, *, complete=True):
        if section not in ("gifts", "avatars", "stories", "availability", "notifications"):
            raise ValueError("Unknown collection")
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if not db.execute("SELECT 1 FROM tracked_profiles WHERE peer_id=? AND enabled=1", (peer_id,)).fetchone():
                return
            old = {key:(json.loads(payload),bool(active)) for key,payload,active in db.execute(
                "SELECT item_id,payload,active FROM profile_items WHERE peer_id=? AND section=?", (peer_id,section))}
            for key, item in items.items():
                key, item = str(key), public_value(item)
                previous = old.get(key)
                # A late answer may contain real content received just before
                # deletion. Retain it in the archive, but never reactivate the
                # story or rewrite the earlier append-only deletion event.
                if section == "stories" and db.execute(
                        "SELECT 1 FROM profile_story_deletions WHERE peer_id=? AND story_id=?",
                        (peer_id,key)).fetchone():
                    if previous is None or previous[0] != item:
                        self._event(db,peer_id,"stories.content_recovered",{
                            "item_id":key,"before":previous[0] if previous else None,
                            "after":item,"source":"late_telegram_result"})
                        db.execute("INSERT INTO profile_items VALUES(?,?,?,?,0) ON CONFLICT(peer_id,section,item_id) DO UPDATE SET payload=excluded.payload,active=0",
                                   (peer_id,section,key,json.dumps(item,ensure_ascii=False,sort_keys=True)))
                    continue
                if previous is None or not previous[1] or previous[0] != item:
                    kind = "added" if previous is None or not previous[1] else "changed"
                    self._event(db, peer_id, section + "." + kind, {"item_id":key,"before":previous[0] if previous else None,"after":item})
                    db.execute("INSERT INTO profile_items VALUES(?,?,?,?,1) ON CONFLICT(peer_id,section,item_id) DO UPDATE SET payload=excluded.payload,active=1",
                               (peer_id,section,key,json.dumps(item,ensure_ascii=False,sort_keys=True)))
            if complete:
                for key, (item, active) in old.items():
                    if active and key not in items and not key.startswith("_"):
                        self._event(db, peer_id, section + ".no_longer_visible", {"item_id":key,"before":item,"after":None})
                        db.execute("UPDATE profile_items SET active=0 WHERE peer_id=? AND section=? AND item_id=?", (peer_id,section,key))

    def skipped_story(self, peer_id, story):
        """Keep evidence immediately, before a network fetch can lose the story."""
        key = str(story["id"])
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if not db.execute("SELECT 1 FROM tracked_profiles WHERE peer_id=? AND enabled=1", (peer_id,)).fetchone():
                return
            if db.execute("SELECT 1 FROM profile_story_deletions WHERE peer_id=? AND story_id=?", (peer_id,key)).fetchone():
                return
            if db.execute("SELECT 1 FROM profile_items WHERE peer_id=? AND section='stories' AND item_id=?", (peer_id,key)).fetchone():
                return  # Never replace a full retained story with a skipped stub.
            item = {**public_value(story), "content_state": "not_loaded"}
            self._event(db,peer_id,"stories.added",{"item_id":key,"before":None,"after":item})
            db.execute("INSERT INTO profile_items VALUES(?,'stories',?,?,1)",
                       (peer_id,key,json.dumps(item,ensure_ascii=False,sort_keys=True)))

    def deleted_story(self, peer_id, story_id):
        """An explicit Telegram tombstone is different from expiry/visibility."""
        key = str(story_id)
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if not db.execute("SELECT 1 FROM tracked_profiles WHERE peer_id=? AND enabled=1", (peer_id,)).fetchone():
                return
            if db.execute("SELECT 1 FROM profile_story_deletions WHERE peer_id=? AND story_id=?", (peer_id,key)).fetchone():
                return
            row = db.execute("SELECT payload FROM profile_items WHERE peer_id=? AND section='stories' AND item_id=?", (peer_id,key)).fetchone()
            self._event(db,peer_id,"stories.deleted",{"item_id":key,"before":json.loads(row[0]) if row else None,"after":None,"source":"telegram_update"})
            db.execute("INSERT INTO profile_story_deletions VALUES(?,?)",(peer_id,key))
            db.execute("UPDATE profile_items SET active=0 WHERE peer_id=? AND section='stories' AND item_id=?", (peer_id,key))

    def history(self, peer_id, before=0, limit=30):
        peer_id, before = self.identifier(peer_id), int(before)
        if before < 0:
            raise ValueError("Invalid cursor")
        limit = max(1,min(100,int(limit)))
        with self.archive.connect() as db:
            rows = db.execute("SELECT seq,kind,observed_at,payload FROM profile_events WHERE peer_id=? AND (?=0 OR seq<?) ORDER BY seq DESC LIMIT ?", (peer_id,before,before,limit+1)).fetchall()
            result, size = [], 0
            for seq,kind,observed,payload in rows[:limit]:
                if result and size + len(payload.encode()) > 2*1024*1024:
                    break
                value = json.loads(payload)
                media = []
                if self.archive.media:
                    for blob in sorted(set(blob_ids(value))):
                        asset = db.execute("SELECT state,size,mime FROM media_assets WHERE id=?", (blob,)).fetchone()
                        if asset:
                            media.append(dict(blob_id=blob,state=asset[0],size=asset[1],mime=asset[2]))
                result.append(dict(seq=seq,kind=kind,observed_at=observed,payload=value,media=media))
                size += len(payload.encode())
        return {**self.status(peer_id),"events":result,"next_before":result[-1]["seq"] if result else before,"has_more":len(rows)>len(result)}

