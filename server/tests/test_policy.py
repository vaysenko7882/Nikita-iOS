import asyncio
import base64
import hashlib
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from nikita_archive.archive import Archive
from nikita_archive.policy import CapturePolicy,PolicyConflict
from nikita_archive.media_store import MediaStore,CapturePaused,CHUNK
from nikita_archive.http_api import make_server


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive=Archive(Path(self.temp.name)/"archive.sqlite3")
        self.archive.set_account(42)
        self.policy=CapturePolicy(self.archive)
        self.archive.policy=self.policy
        for kind,identifier,category,archived in [("user",42,"private",False),("user",43,"private",True),
            ("chat",8,"groups",False),("channel",9,"channels",False),("channel",10,"groups",False)]:
            self.policy.register(kind,identifier,category,str(identifier),archived)
        self.store=MediaStore(self.archive,{"media_min_free_bytes":0})
        self.archive.media=self.store

    def test_default_excludes_groups_channels_and_everything_archived(self):
        self.assertTrue(self.policy.allows("user",42))
        for peer in [("user",43),("chat",8),("channel",9),("channel",10),("user",999)]:
            self.assertFalse(self.policy.allows(*peer))

    def test_explicit_exceptions_override_folder_and_peer_type(self):
        rules=self.policy.current()
        rules["exceptions"]=[dict(peer_type="user",peer_id=43,mode="always"),dict(peer_type="channel",peer_id=9,mode="always"),
            dict(peer_type="user",peer_id=42,mode="never")]
        self.policy.update(rules)
        self.assertTrue(self.policy.allows("user",43))
        self.assertTrue(self.policy.allows("channel",9))
        self.assertFalse(self.policy.allows("user",42))
        self.assertTrue(CapturePolicy(self.archive).allows("user",43))

    def test_folder_updates_apply_before_next_capture(self):
        self.policy.set_folder("user",42,True)
        self.assertFalse(self.policy.allows("user",42))
        self.policy.set_folder("user",42,False)
        self.assertTrue(self.policy.allows("user",42))

    def test_stale_or_invalid_rules_do_not_replace_saved_policy(self):
        initial=self.policy.current()
        self.policy.update(initial)
        with self.assertRaises(PolicyConflict): self.policy.update(initial)
        for invalid in [{**self.policy.current(),"revision":True},{**self.policy.current(),"defaults":{"private":1}},
            {**self.policy.current(),"exceptions":[dict(peer_type="user",peer_id=-1,mode="always")]}]:
            with self.assertRaises(ValueError): self.policy.update(invalid)

    def snapshot(self,identifier,peer_id=42):
        return dict(peer_type="user",peer_id=peer_id,message_id=identifier,text="original",fingerprint="original",version_date=1,date=1)

    def test_denied_messages_and_new_deleted_versions_are_not_collected(self):
        self.archive.observe(self.snapshot(1,43))
        with self.archive.connect() as db: self.assertEqual(db.execute("SELECT COUNT(*) FROM messages").fetchone()[0],0)
        self.archive.observe(self.snapshot(1))
        self.policy.set_folder("user",42,True)
        self.archive.delete([1])
        self.assertEqual(self.archive.sync(0)["events"],[])

    def asset(self,identity="one",message_id=1,data=b"sample"):
        return self.store.register(identity,{"inline":base64.b64encode(data).decode(),
            "source":dict(type="PeerUser",id=42,message_id=message_id)},len(data),"audio/ogg",100)

    def test_queued_downloads_pause_and_resume_without_losing_original_bytes(self):
        asset=self.asset()
        self.policy.set_folder("user",42,True)
        self.assertIsNone(self.store.claim())
        with self.archive.connect() as db:
            self.assertEqual(db.execute("SELECT state FROM media_assets WHERE id=?",(asset["blob_id"],)).fetchone()[0],"paused_policy")
        rules=self.policy.current(); rules["exceptions"]=[dict(peer_type="user",peer_id=42,mode="always")]; self.policy.update(rules)
        job=self.store.claim()
        asyncio.run(self.store.download(None,job))
        self.assertEqual(self.store.ready(asset["blob_id"])[0],"ready")
        self.assertEqual(self.store.path(asset["blob_id"]).read_bytes(),b"sample")

    def test_storage_counts_shared_files_once_and_reports_deleted_subset(self):
        self.archive.observe(self.snapshot(1)); self.archive.observe(self.snapshot(2))
        asset=self.asset(); self.asset(message_id=2)
        self.store.set_category(asset["blob_id"],"voice")
        asyncio.run(self.store.download(None,self.store.claim()))
        self.archive.delete([1])
        result=self.store.storage()
        self.assertEqual(result["stored_bytes"],6)
        self.assertEqual(result["deleted_bytes"],6)
        self.assertEqual(result["categories"],[dict(category="voice",bytes=6,count=1)])
        self.assertEqual(result["deleted_messages"],1)
        self.assertGreater(result["database_bytes"],0)
        self.assertEqual(result["total_bytes"],result["stored_bytes"]+result["database_bytes"]+result["partial_bytes"])

    def test_partial_files_count_towards_actual_usage(self):
        asset=self.asset()
        self.store.path(asset["blob_id"],partial=True).write_bytes(b"abc")
        result=self.store.storage()
        self.assertEqual(result["stored_bytes"],0)
        self.assertEqual(result["partial_bytes"],3)
        self.assertEqual(result["total_bytes"],result["database_bytes"]+3)

    def test_rule_change_during_download_pauses_before_more_bytes_are_saved(self):
        from telethon import types
        data=b"x"*(CHUNK*3)
        location=types.InputDocumentFileLocation(id=1,access_hash=2,file_reference=b"ref",thumb_size="")
        asset=self.store.register("mid-download",dict(location=base64.b64encode(bytes(location)).decode(),dc_id=1,
            source=dict(type="PeerUser",id=42,message_id=1)),len(data),"video/mp4",100)
        policy=self.policy
        class Client:
            async def iter_download(self,*args,**kwargs):
                yield data[:CHUNK]
                policy.set_folder("user",42,True)
                yield data[CHUNK:2*CHUNK]
        job=self.store.claim()
        with self.assertRaises(CapturePaused): asyncio.run(self.store.download(Client(),job))
        self.assertEqual(self.store.path(asset["blob_id"],partial=True).stat().st_size,CHUNK)
        self.assertFalse(self.store.path(asset["blob_id"]).exists())

    def test_shared_asset_can_continue_if_another_source_is_allowed(self):
        asset=self.asset()
        self.store.register("one",dict(inline=base64.b64encode(b"sample").decode(),
            source=dict(type="PeerUser",id=43,message_id=2)),6,"audio/ogg",100)
        self.policy.set_folder("user",42,True)
        self.assertFalse(self.store.permitted(asset["blob_id"]))
        rules=self.policy.current(); rules["exceptions"]=[dict(peer_type="user",peer_id=43,mode="always")]; self.policy.update(rules)
        self.assertTrue(self.store.permitted(asset["blob_id"]))

    def test_policy_api_authentication_account_binding_and_conflict(self):
        server=make_server(self.archive,"t"*40,0)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        def request(method,path,payload=None,account="42",authorized=True):
            body=json.dumps(payload).encode() if payload is not None else None
            headers={"X-CodeGram-Account-ID":account}
            if authorized: headers["Authorization"]="Bearer "+"t"*40
            conn=http.client.HTTPConnection(*server.server_address,timeout=3)
            conn.request(method,path,body,headers)
            response=conn.getresponse(); data=response.read(); status=response.status; conn.close()
            return status,json.loads(data)
        self.assertEqual(request("GET","/v1/policy",authorized=False)[0],401)
        status,rules=request("GET","/v1/policy")
        self.assertEqual((status,rules["account_id"],rules["server_version"]),(200,42,4))
        self.assertEqual(request("PUT","/v1/policy",rules,account="43")[0],403)
        self.assertEqual(request("PUT","/v1/policy",rules)[0],200)
        self.assertEqual(request("PUT","/v1/policy",rules)[0],409)
        self.assertEqual(request("GET","/v1/storage")[1]["account_id"],42)


if __name__=="__main__": unittest.main()
