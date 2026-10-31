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
