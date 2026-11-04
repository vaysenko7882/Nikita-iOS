import asyncio
import base64
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import shutil
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from telethon import types
from nikita_archive.archive import Archive
from nikita_archive.collector import snapshot
from nikita_archive.collector import collect
from nikita_archive.http_api import make_server
from nikita_archive.media_capture import MediaCapture
from nikita_archive.media_store import CHUNK, MAX_MEDIA_SIZE, MediaStore
from nikita_archive.profiles import ProfileStore

NOW = datetime.now(timezone.utc)


def document(attributes=None, size=17, identifier=700):
    return types.Document(identifier, 99887766, b"private-file-reference", NOW,
        "audio/ogg", size, 2, attributes or [])


def message(media, identifier=10):
    return types.Message(identifier, types.PeerUser(42), date=NOW, message="caption",
        media=media, from_id=types.PeerUser(42), grouped_id=12345)


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.archive = Archive(Path(self.temporary.name)/"archive.sqlite3")
        self.archive.set_account(42)
        self.store = MediaStore(self.archive, {"media_min_free_bytes":0})
        self.archive.media = self.store
        self.capture = MediaCapture(self.store)

    def retain(self, item):
        data = snapshot(item)
        data["media"] = self.capture.capture(item)
        self.archive.observe(data)
        return data["media"]

    def test_voice_video_round_sticker_emoji_gif_and_documents_keep_native_metadata(self):
        cases = [
            ([types.DocumentAttributeAudio(12,voice=True,waveform=b"wave")],"voice"),
            ([types.DocumentAttributeVideo(4.5,1280,720,supports_streaming=True)],"video"),
            ([types.DocumentAttributeVideo(5,384,384,round_message=True)],"round_video"),
            ([types.DocumentAttributeSticker("🙂",types.InputStickerSetEmpty())],"sticker"),
            ([types.DocumentAttributeCustomEmoji("🙂",types.InputStickerSetEmpty(),free=True)],"custom_emoji"),
            ([types.DocumentAttributeAnimated()],"animated"),
            ([types.DocumentAttributeFilename("../../secret\\notes.pdf")],"file_name")]
        for index,(attributes,field) in enumerate(cases):
            with self.subTest(field=field):
                result = self.capture.capture(message(types.MessageMediaDocument(document=document(attributes,identifier=700+index))))
                self.assertTrue(result[field])
                self.assertEqual(result["asset"]["size"],17)
                self.assertNotIn("file_reference",json.dumps(result))
                self.assertNotIn("99887766",json.dumps(result))
        self.assertEqual(result["file_name"],"notes.pdf")

    def test_photo_downloads_largest_progressive_full_and_preview(self):
        photo = types.Photo(99,123,b"private",NOW,[types.PhotoSize("s",80,60,50),
            types.PhotoStrippedSize("i",b"tiny"),types.PhotoSizeProgressive("y",1280,960,[100,500,3000])],2)
        result = self.capture.capture(message(types.MessageMediaPhoto(photo=photo,spoiler=True)))
        self.assertEqual(result["asset"]["size"],3000)
        self.assertEqual(result["preview"]["size"],50)
        self.assertEqual(base64.b64decode(result["immediate_thumbnail"]),b"tiny")
        self.assertEqual(snapshot(message(types.MessageMediaPhoto(photo=photo,spoiler=True)))["spoiler"],True)

    def test_deleted_and_replaced_attachments_survive_restart_without_private_references(self):
        first = self.retain(message(types.MessageMediaDocument(document=document())))
        changed = message(types.MessageMediaDocument(document=document(identifier=701)))
        changed.edit_date = datetime.fromtimestamp(NOW.timestamp()+2,timezone.utc)
        self.retain(changed)
        self.archive.delete([10])
        restarted = Archive(self.archive.path)
        restarted.media = MediaStore(restarted,{"media_min_free_bytes":0})
        events = restarted.sync(0)["events"]
        self.assertEqual([item["kind"] for item in events],["edit","delete"])
        self.assertEqual(events[0]["media"]["asset"]["blob_id"],first["asset"]["blob_id"])
        self.assertNotEqual(events[0]["media"]["id"],events[1]["media"]["id"])
        serialized = json.dumps(events)
        for private in ("file_reference","access_hash","location","private-file-reference"):
            self.assertNotIn(private,serialized)
        self.assertEqual(events[1]["grouped_id"],12345)

    def test_old_snapshot_gains_media_without_fake_edit(self):
        item = message(types.MessageMediaDocument(document=document()))
        self.archive.observe(snapshot(item))
        self.retain(item)
        self.assertEqual(self.archive.sync(0)["events"],[])
        self.archive.delete([10])
        self.assertEqual(self.archive.sync(0)["events"][0]["media"]["kind"],"document")

    def test_old_journal_can_find_retained_attachment_by_original_id(self):
        item = message(types.MessageMediaDocument(document=document()))
        self.archive.observe(snapshot(item))
        self.archive.delete([10])
        self.capture.capture(item)
        self.assertEqual(self.archive.sync(0)["events"][0]["media"]["id"],700)

    def test_size_limit_path_validation_and_live_priority(self):
        self.assertIsNone(self.store.register("large",{},MAX_MEDIA_SIZE+1,"text/plain",100))
        with self.assertRaises(ValueError): self.store.path("../../config.json")
        self.store.register("history",{},5,"text/plain",0)
        live = self.store.register("live",{},20,"text/plain",100)
        self.assertEqual(self.store.claim()["id"],live["blob_id"])

    def test_disk_reservations_pause_new_downloads_without_deleting_archive(self):
        self.store.register("first",{},60,"text/plain",100)
        self.store.register("second",{},70,"text/plain",100)
        with patch("nikita_archive.media_store.shutil.disk_usage",return_value=shutil._ntuple_diskusage(1000,900,100)):
            self.assertIsNotNone(self.store.claim())
            self.assertIsNone(self.store.claim())
            self.assertEqual(self.store.stats()["waiting_for_disk"],1)

    def test_large_blocked_backlog_does_not_starve_a_later_file_that_fits(self):
        for index in range(150):
            self.store.register("blocked-"+str(index),{},2*1024**3,"video/mp4",1000)
        fits=self.store.register("later-smaller-file",{},32*1024**2,"application/pdf",0)
        with patch("nikita_archive.media_store.shutil.disk_usage",return_value=shutil._ntuple_diskusage(4*1024**3,3*1024**3,1024**3)):
            self.assertEqual(self.store.claim()["id"],fits["blob_id"])

    def test_story_lane_does_not_consume_avatars_or_archive_jobs(self):
        self.archive.profiles = ProfileStore(self.archive)
        self.archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
        archive = self.store.register("archive",{},5,"video/mp4",2000)
        avatar = self.store.register("avatar",{"source":dict(type="CodeGramProfile",peer_id=77,section="avatars")},5,"image/jpeg",500)
        self.archive.profiles.associate(77,avatar)
        self.assertIsNone(self.store.claim(story_only=True))
        story = self.store.register("story",{"source":dict(type="CodeGramProfile",peer_id=77,section="stories")},5,"video/mp4",1000)
        self.archive.profiles.associate(77,story)
        self.assertEqual(self.store.claim(story_only=True)["id"],story["blob_id"])
        self.assertIsNone(self.store.claim(story_only=True))
        self.assertEqual(self.store.claim()["id"],archive["blob_id"])

    def test_story_lane_survives_reference_refresh_and_restart_but_respects_opt_out(self):
        self.archive.profiles = ProfileStore(self.archive)
        self.archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
        story = self.store.register("shared",{"source":dict(type="CodeGramProfile",peer_id=77,section="stories")},5,"video/mp4",1000)
        self.archive.profiles.associate(77,story)
        # The same immutable file can subsequently arrive in a normal chat;
        # that must not lose its place in the story lane.
        self.store.register("shared",{"source":dict(type="PeerUser",id=77,message_id=10)},5,"video/mp4",100)
        restarted = MediaStore(self.archive,{"media_min_free_bytes":0})
        self.archive.profiles.configure(77,{"enabled":False})
        self.assertIsNone(restarted.claim(story_only=True))
        self.archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
        self.assertEqual(restarted.claim(story_only=True)["id"],story["blob_id"])

    def test_reserved_lane_prioritizes_new_story_over_older_story_backlog(self):
        self.archive.profiles = ProfileStore(self.archive)
        self.archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
        source=dict(type="CodeGramProfile",peer_id=77,section="stories")
        old=self.store.register("old",{"source":source},5,"video/mp4",1000)
        new=self.store.register("new",{"source":source},30,"video/mp4",1000)
        self.archive.profiles.associate(77,old)
        self.archive.profiles.associate(77,new)
        self.assertEqual(self.store.claim(story_only=True)["id"],new["blob_id"])
        self.assertEqual(self.store.claim(story_only=True)["id"],old["blob_id"])

    def test_existing_pending_story_is_migrated_into_reserved_lane(self):
        self.archive.profiles = ProfileStore(self.archive)
        self.archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
        story = self.store.register("old-story",{"source":dict(type="CodeGramProfile",peer_id=77,section="stories")},5,"video/mp4",1000)
        self.archive.profiles.associate(77,story)
        # Reproduce a database created by the previous release, before the
        # new durable lane existed; the attachment and profile history remain.
        with self.archive.connect() as db:
            db.execute("DROP TABLE media_story_assets")
            db.execute("DELETE FROM meta WHERE key='story_media_queue_v1'")
        upgraded = MediaStore(self.archive,{"media_min_free_bytes":0})
        self.assertEqual(upgraded.claim(story_only=True)["id"],story["blob_id"])

    def test_api_construction_does_not_reset_in_progress_downloads(self):
        asset = self.store.register("active",{},8,"text/plain",100)
        self.store.claim()
        MediaStore(self.archive,{})
        with self.archive.connect() as db:
            self.assertEqual(db.execute("SELECT state FROM media_assets WHERE id=?",(asset["blob_id"],)).fetchone()[0],"downloading")
        self.store.recover()
        self.assertEqual(self.store.stats()["pending"],1)

    def test_completed_blob_survives_crash_before_database_ready_commit(self):
        data=b"already downloaded before the sender removed it"
        asset=self.store.register("publish-interrupted",{},len(data),"text/plain",100)
        job=self.store.claim()
        identifier=asset["blob_id"]
        partial=self.store.path(identifier,partial=True)
        partial.write_bytes(data)
        partial.replace(self.store.path(identifier))
        restarted=MediaStore(self.archive,{"media_min_free_bytes":0})
        restarted.recover()
        state,ready=restarted.ready(identifier)
        self.assertEqual(state,"ready")
        self.assertEqual(ready["sha256"],hashlib.sha256(data).hexdigest())
        self.assertEqual(ready["path"].read_bytes(),data)
        self.assertIsNone(restarted.claim())

    def complete_inline(self,data=b"the original bytes"):
        result=self.store.register("inline",{"inline":base64.b64encode(data).decode()},len(data),"text/plain",100)
        job=self.store.claim()
        asyncio.run(self.store.download(None,job))
        self.store.reservations.pop(job["id"],None)
        return result["blob_id"]

    def test_authenticated_range_protocol_pending_epoch_hash_and_head(self):
        identifier=self.complete_inline()
        pending=self.store.register("pending",{},1,"text/plain",100)["blob_id"]
        server=make_server(self.archive,"a"*40,0)
        thread=threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        def request(path,headers=None,method="GET"):
            connection=http.client.HTTPConnection(*server.server_address,timeout=3)
            connection.request(method,path,headers=headers or {})
            response=connection.getresponse()
            result=response.status,dict(response.getheaders()),response.read()
            connection.close()
            return result
        path="/v1/media/"+identifier
        self.assertEqual(request(path)[0],401)
        headers={"Authorization":"Bearer "+"a"*40,"X-Nikita-Archive-Epoch":self.archive.server_id,"Range":"bytes=4-11"}
        status,fields,body=request(path,headers)
        self.assertEqual((status,body),(206,b"original"))
        self.assertEqual(fields["X-Nikita-Range-SHA256"],hashlib.sha256(body).hexdigest())
        self.assertEqual(fields["Content-Range"],"bytes 4-11/18")
        self.assertEqual(request(path,{**headers,"X-Nikita-Archive-Epoch":"wrong"})[0],409)
        self.assertEqual(request(path,{**headers,"Range":"bytes=999-"})[0],416)
        self.assertEqual(request(path,{**headers,"Range":"bytes=0-1,4-5"})[0],400)
        self.assertEqual(request("/v1/media/"+pending,headers)[0],503)
        self.assertEqual(request(path,headers,"HEAD")[2],b"")

    def test_resume_realigns_partial_and_verifies_complete_bytes(self):
        data=b"v"*(CHUNK+301)
        item=self.capture.capture(message(types.MessageMediaDocument(document=document(size=len(data)))))
        identifier=item["asset"]["blob_id"]
        self.store.path(identifier,partial=True).write_bytes(data[:CHUNK+111])
        offsets=[]
        class Client:
            async def iter_download(self,location,offset,**kwargs):
                offsets.append(offset)
                self_location=bytes(location)
                self_location and None
                yield data[offset:]
        job=self.store.claim()
        asyncio.run(self.store.download(Client(),job))
        self.assertEqual(offsets,[CHUNK])
        state,ready=self.store.ready(identifier)
        self.assertEqual(state,"ready")
        self.assertEqual(ready["path"].read_bytes(),data)
        self.assertEqual(ready["sha256"],hashlib.sha256(data).hexdigest())
        ready["path"].write_bytes(b"changed")
        self.assertEqual(self.store.ready(identifier)[0],"failed")

    def test_oversized_and_incomplete_downloads_never_publish_partial_blob(self):
        for data in (b"x"*18,b"x"*16):
            with self.subTest(length=len(data)):
                result=self.capture.capture(message(types.MessageMediaDocument(document=document(identifier=800+len(data)))))
                job=self.store.claim()
                class Client:
                    async def iter_download(self,*args,**kwargs): yield data
                with self.assertRaises(ValueError): asyncio.run(self.store.download(Client(),job))
                self.assertFalse(self.store.path(result["asset"]["blob_id"]).exists())
                self.store.reservations.pop(job["id"],None)


class CollectorMediaTests(unittest.IsolatedAsyncioTestCase):
    async def test_story_download_starts_promptly_while_archive_workers_are_busy(self):
        with tempfile.TemporaryDirectory() as directory:
            archive=Archive(Path(directory)/"archive.sqlite3")
            store=MediaStore(archive,{"media_min_free_bytes":0})
            archive.media=store
            archive.profiles=ProfileStore(archive)
            archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
            capture=MediaCapture(store)
            for identifier in (700,701):
                capture.capture(message(types.MessageMediaDocument(document=document(identifier=identifier))))
            busy=set()
            archive_started=asyncio.Event()
            story_started=asyncio.Event()
            release=asyncio.Event()
            class Client:
                async def iter_download(self,location,**kwargs):
                    if location.id in (700,701):
                        busy.add(location.id)
                        if len(busy)==2: archive_started.set()
                        await release.wait()
                    else:
                        story_started.set()
                    yield b"x"*17
            client=Client()
            tasks=[asyncio.create_task(store.worker(client)) for _ in range(2)]
            tasks.append(asyncio.create_task(store.worker(client,story_only=True)))
            try:
                await asyncio.wait_for(archive_started.wait(),3)
                capture.source=dict(type="CodeGramProfile",peer_id=77,section="stories",item_id="99")
                story=capture.document(document(identifier=799),1000)
                archive.profiles.associate(77,story)
                # An idle worker previously slept for a whole second. It must
                # wake when this media arrives, while both archive jobs wait.
                await asyncio.wait_for(story_started.wait(),0.8)
                identifier=story["asset"]["blob_id"]
                for _ in range(100):
                    if store.ready(identifier)[0]=="ready": break
                    await asyncio.sleep(0.01)
                self.assertEqual(store.ready(identifier)[0],"ready")
                self.assertEqual(store.path(identifier).read_bytes(),b"x"*17)
                self.assertFalse(release.is_set())
                self.assertEqual(len(busy),2)
            finally:
                for task in tasks: task.cancel()
                await asyncio.gather(*tasks,return_exceptions=True)

    async def test_unavailable_story_reference_keeps_failure_without_publishing_bytes(self):
        from telethon.errors import FileReferenceExpiredError
        with tempfile.TemporaryDirectory() as directory:
            archive=Archive(Path(directory)/"archive.sqlite3")
            store=MediaStore(archive,{"media_min_free_bytes":0})
            archive.media=store
            archive.profiles=ProfileStore(archive)
            archive.profiles.configure(77,{"enabled":True,"access_hash":"1"})
            capture=MediaCapture(store)
            capture.source=dict(type="CodeGramProfile",peer_id=77,section="stories",item_id="99")
            story=capture.document(document(identifier=799),1000)
            archive.profiles.associate(77,story)
            identifier=story["asset"]["blob_id"]
            class Client:
                async def iter_download(self,*args,**kwargs):
                    raise FileReferenceExpiredError(None)
                    yield b"unreachable"
            task=asyncio.create_task(store.worker(Client(),story_only=True))
            try:
                for _ in range(100):
                    if store.ready(identifier)[0]=="failed": break
                    await asyncio.sleep(0.01)
                self.assertEqual(store.ready(identifier)[0],"failed")
                self.assertFalse(store.path(identifier).exists())
                with archive.connect() as db:
                    self.assertEqual(db.execute("SELECT error,attempts FROM media_assets WHERE id=?",(identifier,)).fetchone(),("FileReferenceExpiredError",1))
                self.assertTrue(archive.profiles.permits_asset(identifier))
            finally:
                task.cancel()
                await asyncio.gather(task,return_exceptions=True)

    async def test_collector_records_deletion_while_independent_download_is_busy(self):
        with tempfile.TemporaryDirectory() as directory:
            config={"database_path":str(Path(directory)/"archive.sqlite3"),"media_min_free_bytes":0}
            started=asyncio.Event()
            release=asyncio.Event()
            handlers=[]
            item=message(types.MessageMediaDocument(document=document([types.DocumentAttributeAudio(4,voice=True)])))
            class Client:
                def add_event_handler(self,callback,event): handlers.append(callback)
                async def connect(self): pass
                async def disconnect(self): pass
                async def is_user_authorized(self): return True
                async def get_me(self): return SimpleNamespace(id=42)
                def is_connected(self): return True
                async def catch_up(self): await handlers[0](SimpleNamespace(message=item))
                async def iter_dialogs(self,**kwargs):
                    yield SimpleNamespace(entity=types.User(id=42,first_name="Owner"),archived=False)
                async def iter_messages(self,*args,**kwargs):
                    if False: yield None
                async def run_until_disconnected(self): await asyncio.Event().wait()
                async def iter_download(self,*args,**kwargs):
                    started.set()
                    await release.wait()
                    yield b"x"*17
            with patch("nikita_archive.collector.client_for",return_value=Client()):
                task=asyncio.create_task(collect(config))
                try:
                    await asyncio.wait_for(started.wait(),3)
                    await handlers[2](SimpleNamespace(channel_id=None,chat_id=42,deleted_ids=[10]))
                    archive=Archive(config["database_path"])
                    archive.media=MediaStore(archive,config)
                    event=archive.sync(0)["events"][0]
                    self.assertEqual((event["kind"],event["media"]["voice"]),("delete",True))
                    identifier=event["media"]["asset"]["blob_id"]
                    self.assertEqual(archive.media.ready(identifier)[0],"downloading")
                    release.set()
                    for _ in range(100):
                        if archive.media.ready(identifier)[0]=="ready": break
                        await asyncio.sleep(0.02)
                    self.assertEqual(archive.media.ready(identifier)[0],"ready")
                    self.assertEqual(archive.media.path(identifier).read_bytes(),b"x"*17)
                finally:
                    task.cancel()
                    await asyncio.gather(task,return_exceptions=True)
                self.assertFalse(archive.sync(0)["connected"])

    async def test_worker_refreshes_an_expired_reference_without_new_authorization(self):
        from telethon.errors import FileReferenceExpiredError
        with tempfile.TemporaryDirectory() as directory:
            archive=Archive(Path(directory)/"archive.sqlite3")
            store=MediaStore(archive,{"media_min_free_bytes":0})
            capture=MediaCapture(store)
            item=message(types.MessageMediaDocument(document=document()))
            identifier=capture.capture(item)["asset"]["blob_id"]
            refreshed=document()
            refreshed.file_reference=b"fresh-reference"
            renewed=message(types.MessageMediaDocument(document=refreshed))
            calls=[]
            class Client:
                async def get_messages(self,peer,ids):
                    calls.append((peer.user_id,ids))
                    return renewed
                async def iter_download(self,location,**kwargs):
                    if location.file_reference!=b"fresh-reference": raise FileReferenceExpiredError(None)
                    yield b"x"*17
            task=asyncio.create_task(store.worker(Client()))
            try:
                for _ in range(100):
                    if store.ready(identifier)[0]=="ready": break
                    await asyncio.sleep(0.02)
                self.assertEqual(store.ready(identifier)[0],"ready")
                self.assertEqual(calls,[(42,10)])
            finally:
                task.cancel()
                await asyncio.gather(task,return_exceptions=True)


if __name__=="__main__": unittest.main()

