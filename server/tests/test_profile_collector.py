import asyncio
import datetime
import json
from pathlib import Path
from types import SimpleNamespace as NS
import tempfile
import time
import unittest
from telethon import errors, functions, types
from nikita_archive.archive import Archive
from nikita_archive.media_store import MediaStore
from nikita_archive.profile_collector import ProfileCollector
from nikita_archive.profiles import ProfileStore


class Gift:
    def __init__(self):
        self.gift=NS(id=9,sticker=None)
        self.from_id=types.PeerUser(7)
        self.name_hidden=False
        self.unsaved=False
    def to_dict(self):
        return dict(date=1000,gift=dict(id=9,title="Gift"),from_id=self.from_id.to_dict(),name_hidden=self.name_hidden,unsaved=self.unsaved)


class Client:
    def __init__(self):
        self.user=NS(id=100,first_name="Alice",last_name="Name",photo=None,status=None)
        self.info=NS(about="Before",blocked=False)
        self.gift=Gift()
        self.fail_stories=False
        self.partial_gifts=False
        self.calls=[]
        self.chats=[]
        self.flood=False
    async def __call__(self, request, **kwargs):
        self.calls.append(request)
        if self.flood:
            raise errors.FloodWaitError(request,capture=35)
        if isinstance(request,functions.users.GetFullUserRequest):
            return NS(users=[self.user],full_user=self.info)
        if isinstance(request,functions.stories.GetPeerStoriesRequest):
            if self.fail_stories: raise RuntimeError("Private collection")
            return NS(stories=NS(stories=[]))
        if isinstance(request,functions.payments.GetSavedStarGiftsRequest):
            if request.offset: raise RuntimeError("Interrupted page")
            sender=NS(id=7,first_name="Sender",last_name=None,username="sender")
            return NS(users=[sender],chats=self.chats,gifts=[self.gift],count=1,next_offset="next" if self.partial_gifts else None)
        raise AssertionError(type(request).__name__)
    async def iter_profile_photos(self,peer):
        for photo in []: yield photo


class ProfileCollectorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.archive=Archive(Path(self.temp.name)/"archive.sqlite3")
        self.archive.media=MediaStore(self.archive,{"media_min_free_bytes":0})
        self.store=ProfileStore(self.archive);self.archive.profiles=self.store
        self.store.configure(100,{"enabled":True,"access_hash":"456"})
        self.client=Client();self.observer=ProfileCollector(self.client,self.store)
        self.observer.request=self.client
    async def asyncTearDown(self): self.temp.cleanup()
    def events(self): return self.store.history(100,limit=100)["events"]

    async def test_scan_keeps_name_bio_and_only_real_changes(self):
        self.assertEqual(await self.observer.scan(100,"456"),"")
        first=len(self.events())
        self.assertEqual(await self.observer.scan(100,"456"),"")
        self.assertEqual(len(self.events()),first)
        self.client.user.first_name="Changed";self.client.info.about="After"
        await self.observer.scan(100,"456")
        fields={e["payload"]["field"] for e in self.events() if e["kind"]=="profile.changed"}
        self.assertEqual(fields,{"first_name","about"})

    async def test_restricted_stories_do_not_stop_gifts_or_clear_history(self):
        self.store.collection(100,"stories",{"old":{"caption":"kept"}})
        self.client.fail_stories=True
        warning=await self.observer.scan(100,"456")
        self.assertIn("Сторис",warning)
        self.assertTrue(any(e["kind"]=="gifts.added" for e in self.events()))
        self.assertFalse(any(e["kind"]=="stories.no_longer_visible" for e in self.events()))

    async def test_mutable_gift_visibility_keeps_identity_and_hides_sender(self):
        peer=types.InputPeerUser(100,456)
        await self.observer.gifts(100,peer)
        self.client.gift.name_hidden=True;self.client.gift.unsaved=True
        await self.observer.gifts(100,peer)
        changed=[e for e in self.events() if e["kind"]=="gifts.changed" and e["payload"]["item_id"]!="_visible_order"]
        self.assertEqual(len(changed),1)
        self.assertIsNone(changed[0]["payload"]["after"]["sender"])
        self.assertIsNone(changed[0]["payload"]["after"]["from_id"])
        self.assertFalse(any(e["kind"]=="gifts.no_longer_visible" for e in self.events()))

    async def test_failed_gift_pagination_does_not_publish_a_partial_collection(self):
        self.store.collection(100,"gifts",{"existing":{"title":"Existing"}})
        self.client.partial_gifts=True
        with self.assertRaises(RuntimeError): await self.observer.gifts(100,types.InputPeerUser(100,456))
        self.assertFalse(any(e["kind"]=="gifts.no_longer_visible" for e in self.events()))
        with self.archive.connect() as db:
            self.assertEqual(db.execute("SELECT active FROM profile_items WHERE item_id='existing'").fetchone()[0],1)

    async def test_pushed_story_registers_media_without_waiting_for_next_poll(self):
        now=datetime.datetime.now(datetime.timezone.utc)
        photo=types.Photo(id=11,access_hash=99,file_reference=b"private",date=now,sizes=[types.PhotoSize(type="x",w=100,h=100,size=8)],dc_id=2)
        story=types.StoryItem(id=1,date=now,expire_date=now+datetime.timedelta(hours=6),media=types.MessageMediaPhoto(photo=photo),caption="Story")
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=story))
        event=next(e for e in self.events() if e["kind"]=="stories.added")
        self.assertEqual(event["payload"]["after"]["caption"],"Story")
        self.assertTrue(event["media"])
        encoded=json.dumps(event)
        self.assertNotIn("file_reference",encoded);self.assertNotIn("access_hash",encoded)
        self.assertEqual(self.client.calls,[])
        for asset in event["media"]: self.assertTrue(self.store.permits_asset(asset["blob_id"]))

    async def test_my_block_flag_is_not_misreported_as_their_block(self):
        self.client.info.blocked=True
        await self.observer.scan(100,"456")
        event=next(e for e in self.events() if e["kind"]=="availability.added")
        value=event["payload"]["after"]
        self.assertTrue(value["blocked_by_me"])
        self.assertEqual(value["blocked_by_target"],"unknown_not_exposed_by_telegram")

    async def test_channel_gift_sender_keeps_its_received_title(self):
        self.client.gift.from_id=types.PeerChannel(8)
        self.client.chats=[NS(id=8,title="Sender channel",username="channel")]
        await self.observer.gifts(100,types.InputPeerUser(100,456))
        event=next(e for e in self.events() if e["kind"]=="gifts.added" and e["payload"]["item_id"]!="_visible_order")
        self.assertEqual(event["payload"]["after"]["sender"]["title"],"Sender channel")

    async def test_flood_wait_pauses_observer_instead_of_tight_retry_loop(self):
        self.client.flood=True
        task=asyncio.create_task(self.observer.run())
        try:
            for _ in range(20):
                if self.observer.pause_until>time.monotonic(): break
                await asyncio.sleep(0.01)
            self.assertGreater(self.observer.pause_until,time.monotonic())
            self.assertEqual(len(self.client.calls),1)
            self.assertIn("ограничил",self.store.status(100)["profiles"][0]["error"])
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
