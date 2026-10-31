"""Per-account capture policy. Existing files are never deleted by a rule change."""
import json
import time

DEFAULTS = {"private": True, "groups": False, "channels": False, "archived": False}
PEER_TYPES = ("user", "chat", "channel")


class PolicyConflict(ValueError):
    pass


class CapturePolicy:
    def __init__(self, archive):
        self.archive = archive
        with archive.connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS capture_peers(
                peer_type TEXT NOT NULL, peer_id INTEGER NOT NULL, kind TEXT NOT NULL,
                title TEXT NOT NULL, archived INTEGER NOT NULL,
                PRIMARY KEY(peer_type,peer_id))""")
            db.execute("INSERT OR IGNORE INTO meta VALUES('capture_policy',?)",
                (json.dumps({"revision":1,"defaults":DEFAULTS,"exceptions":[]}),))

    def current(self, include_dialogs=False, query=""):
        with self.archive.connect() as db:
            result = json.loads(self.archive._meta(db,"capture_policy"))
            if include_dialogs:
                rows = db.execute("SELECT peer_type,peer_id,kind,title,archived FROM capture_peers WHERE title LIKE ? ORDER BY title COLLATE NOCASE LIMIT 2000",
                    ("%"+query[:128]+"%",)).fetchall()
                result["dialogs"] = [dict(peer_type=r[0],peer_id=r[1],kind=r[2],title=r[3],archived=bool(r[4])) for r in rows]
            return result

    def update(self, payload):
        if not isinstance(payload,dict): raise ValueError("Invalid policy")
        defaults = payload.get("defaults")
        exceptions = payload.get("exceptions")
        if type(payload.get("revision")) is not int: raise ValueError("Invalid revision")
        if not isinstance(defaults,dict) or set(defaults)!=set(DEFAULTS) or any(type(v) is not bool for v in defaults.values()):
            raise ValueError("Invalid capture defaults")
        if not isinstance(exceptions,list) or len(exceptions)>2000: raise ValueError("Too many capture exceptions")
        normalized = {}
        for item in exceptions:
            if not isinstance(item,dict) or item.get("peer_type") not in PEER_TYPES or type(item.get("peer_id")) is not int or not 0<item["peer_id"]<2**63 or item.get("mode") not in ("always","never"):
                raise ValueError("Invalid capture exception")
            normalized[(item["peer_type"],item["peer_id"])] = {k:item[k] for k in ("peer_type","peer_id","mode")}
        with self.archive.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = json.loads(self.archive._meta(db,"capture_policy"))
            if payload.get("revision")!=previous["revision"]: raise PolicyConflict("Policy changed; reload it")
            result = dict(revision=previous["revision"]+1,defaults=defaults,
                exceptions=[normalized[k] for k in sorted(normalized)])
            db.execute("INSERT OR REPLACE INTO meta VALUES('capture_policy',?)",(json.dumps(result),))
        return result

    def register(self, peer_type, peer_id, kind, title, archived):
        if peer_type not in PEER_TYPES or kind not in ("private","groups","channels") or not 0<int(peer_id)<2**63:
            return
        with self.archive.connect() as db:
            db.execute("INSERT OR REPLACE INTO capture_peers VALUES(?,?,?,?,?)",
                (peer_type,int(peer_id),kind,str(title or peer_id)[:255],int(bool(archived))))

    def set_folder(self, peer_type, peer_id, archived):
        with self.archive.connect() as db:
            db.execute("UPDATE capture_peers SET archived=? WHERE peer_type=? AND peer_id=?",(int(bool(archived)),peer_type,peer_id))

    def known(self, peer_type, peer_id):
        with self.archive.connect() as db:
            return db.execute("SELECT 1 FROM capture_peers WHERE peer_type=? AND peer_id=?",(peer_type,peer_id)).fetchone() is not None

    def allows(self, peer_type, peer_id):
        with self.archive.connect() as db:
            rules = json.loads(self.archive._meta(db,"capture_policy"))
            row = db.execute("SELECT kind,archived FROM capture_peers WHERE peer_type=? AND peer_id=?",(peer_type,peer_id)).fetchone()
        for exception in rules["exceptions"]:
            if exception["peer_type"]==peer_type and exception["peer_id"]==peer_id:
                return exception["mode"]=="always"
        # Unknown archive membership must never silently opt a chat into capture.
        if row is None: return False
        if row[1] and not rules["defaults"]["archived"]: return False
        return rules["defaults"][row[0]]


def source_peer(source):
    if not isinstance(source,dict): return None
    kind = {"PeerUser":"user","PeerChat":"chat","PeerChannel":"channel"}.get(source.get("type"))
    value = source.get("id")
    if kind is None or type(value) is not int or not 0<value<2**63: return None
    return kind,value,int(source.get("message_id",0))
