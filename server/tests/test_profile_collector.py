import asyncio
import datetime
import json
from pathlib import Path
from types import SimpleNamespace as NS
import tempfile
import time
import unittest
from unittest.mock import patch
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
        if isinstance(request,functions.photos.GetUserPhotosRequest):
            return types.photos.Photos(photos=[],users=[])
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
    async def asyncTearDown(self):
        await self.observer.close()
        self.temp.cleanup()
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


    def story(self, story_id=1):
        now=datetime.datetime.now(datetime.timezone.utc)
        photo=types.Photo(id=11,access_hash=99,file_reference=b"private",date=now,
            sizes=[types.PhotoSize(type="x",w=100,h=100,size=8)],dc_id=2)
        return types.StoryItem(id=story_id,date=now,expire_date=now+datetime.timedelta(hours=6),
            media=types.MessageMediaPhoto(photo=photo),caption="Brief story")

    async def test_create_then_delete_push_retains_content_without_polling(self):
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=self.story()))
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=types.StoryItemDeleted(1)))
        story_events=[e for e in reversed(self.events()) if e["kind"].startswith("stories.")]
        self.assertEqual([e["kind"] for e in story_events],["stories.added","stories.deleted"])
        self.assertEqual(story_events[-1]["payload"]["before"]["caption"],"Brief story")
        self.assertTrue(story_events[-1]["media"])
        self.assertEqual(self.client.calls,[])  # No timer/RPC for full or deleted updates.
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=types.StoryItemDeleted(1)))
        self.assertEqual(len([e for e in self.events() if e["kind"]=="stories.deleted"]),1)

    async def test_late_poll_cannot_resurrect_an_explicitly_deleted_story(self):
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=types.StoryItemDeleted(1)))
        await self.observer.stories(100,None,[self.story()])
        self.assertFalse(any(e["kind"]=="stories.added" for e in self.events()))
        event=next(e for e in self.events() if e["kind"]=="stories.deleted")
        self.assertIsNone(event["payload"]["before"])  # Missing bytes aren't invented.

    async def test_skipped_push_is_persisted_before_hydration_and_deletion_is_not_blocked(self):
        started=asyncio.Event();release=asyncio.Event()
        async def resolve(request):
            started.set()
            await release.wait()
            return NS(stories=[self.story()])
        self.observer.request=resolve
        now=datetime.datetime.now(datetime.timezone.utc)
        skipped=types.StoryItemSkipped(1,now,now+datetime.timedelta(hours=6))
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=skipped))
        self.assertEqual(self.events()[0]["payload"]["after"]["content_state"],"not_loaded")
        await asyncio.wait_for(started.wait(),1)
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=types.StoryItemDeleted(1)))
        release.set()
        await asyncio.gather(*list(self.observer.story_tasks))
        self.assertEqual([e["kind"] for e in reversed(self.events()) if e["kind"].startswith("stories.")],
                         ["stories.added","stories.deleted","stories.content_recovered"])
        recovered=next(e for e in self.events() if e["kind"]=="stories.content_recovered")
        self.assertEqual(recovered["payload"]["before"]["content_state"],"not_loaded")
        self.assertEqual(recovered["payload"]["after"]["caption"],"Brief story")
        self.assertTrue(recovered["media"])
        deleted=next(e for e in self.events() if e["kind"]=="stories.deleted")
        self.assertEqual(deleted["payload"]["before"]["content_state"],"not_loaded")
        self.assertIsNone(deleted["payload"]["after"])

        class Downloader:
            async def iter_download(self,location,**kwargs):
                yield b"story123"
        job=self.archive.media.claim(story_only=True)
        self.assertIsNotNone(job)
        await self.archive.media.download(Downloader(),job)
        restored=ProfileStore(self.archive)
        self.archive.profiles=restored
        history=restored.history(100)["events"]
        recovered=next(e for e in history if e["kind"]=="stories.content_recovered")
        self.assertEqual(recovered["media"][0]["state"],"ready")
        asset=recovered["media"][0]["blob_id"]
        self.assertTrue(self.archive.media.permitted(asset))
        self.assertEqual(self.archive.media.path(asset).read_bytes(),b"story123")
        with self.archive.connect() as db:
            self.assertEqual(db.execute("SELECT active FROM profile_items WHERE peer_id=100 AND section='stories' AND item_id='1'").fetchone()[0],0)
            self.assertIsNotNone(db.execute("SELECT 1 FROM profile_story_deletions WHERE peer_id=100 AND story_id='1'").fetchone())
        # Repeated late results are deduplicated without an active resurrection.
        restored.collection(100,"stories",{"1":recovered["payload"]["after"]},complete=False)
        self.assertEqual(len([e for e in restored.history(100)["events"] if e["kind"]=="stories.content_recovered"]),1)
        self.assertFalse(any(e["kind"]=="stories.changed" for e in restored.history(100)["events"]))

    async def test_skipped_push_never_overwrites_retained_full_story(self):
        story=self.story()
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=story))
        skipped=types.StoryItemSkipped(1,story.date,story.expire_date)
        self.store.skipped_story(100,skipped.to_dict())
        with self.archive.connect() as db:
            value=json.loads(db.execute("SELECT payload FROM profile_items WHERE section='stories'").fetchone()[0])
        self.assertEqual(value["caption"],"Brief story")
        self.assertNotIn("content_state",value)

    async def test_rapid_name_change_and_revert_are_recorded_before_a_scan(self):
        self.store.fields(100,{"first_name":"Original","last_name":"Name","about":"Kept","stargifts_count":2})
        self.observer.user_update(types.UpdateUserName(100,"Brief","Name",[]))
        self.observer.user_update(types.UpdateUserName(100,"Original","Name",[]))
        names=[e["payload"]["after"] for e in reversed(self.events()) if e["kind"]=="profile.changed" and e["payload"]["field"]=="first_name"]
        self.assertEqual(names,["Brief","Original"])
        self.assertEqual(self.store.field_value(100,"about"),"Kept")
        self.assertEqual(self.store.field_value(100,"stargifts_count"),2)
        self.assertEqual(self.client.calls,[])

    async def test_embedded_full_user_update_records_photo_before_refresh(self):
        self.store.fields(100,{"current_photo_id":"1","about":"Retained"})
        entity=types.User(id=100,first_name="Name",photo=types.UserProfilePhoto(photo_id=2,dc_id=1))
        update=types.UpdateUser(100);update._entities={100:entity}
        self.observer.user_update(update)
        self.assertEqual(self.store.field_value(100,"current_photo_id"),"2")
        self.assertEqual(self.store.field_value(100,"about"),"Retained")
        self.assertEqual(self.client.calls,[])

    async def test_own_block_update_never_claims_target_blocked_or_unblocked_me(self):
        await self.observer.scan(100,"456")
        self.observer.user_update(types.UpdatePeerBlocked(types.PeerUser(100),blocked=True))
        self.observer.user_update(types.UpdatePeerBlocked(types.PeerUser(100),blocked=False))
        events=[e for e in self.events() if e["kind"].startswith("own_blocklist.")]
        self.assertEqual([e["kind"] for e in events],["own_blocklist.unblocked","own_blocklist.blocked"])
        self.assertTrue(all(e["payload"]["certainty"]=="confirmed" for e in events))
        assessment=self.store.status(100)["profiles"][0]["block_assessment"]
        self.assertEqual(assessment["blocked_by_target"],"unknown_not_exposed_by_telegram")
        self.assertFalse(any(e["kind"].startswith("block_signals.") for e in self.events()))

    async def test_raw_status_correlates_existing_photo_loss_without_rpc(self):
        self.client.user.photo=types.UserProfilePhoto(photo_id=1,dc_id=1)
        self.client.user.status=types.UserStatusOnline(datetime.datetime.now(datetime.timezone.utc))
        with patch("nikita_archive.profiles.time.time",return_value=100):
            await self.observer.scan(100,"456")
        self.client.calls.clear()
        with patch("nikita_archive.profiles.time.time",return_value=101):
            self.store.observe_availability(100,{"photo_visible":False})
        with patch("nikita_archive.profiles.time.time",return_value=102):
            self.observer.user_update(types.UpdateUserStatus(100,types.UserStatusEmpty()))
        event=next(e for e in self.events() if e["kind"]=="block_signals.possible_restriction")
        self.assertEqual(event["payload"]["after"]["source"],"telegram_update")
        self.assertEqual(event["payload"]["after"]["certainty"],"inferred")
        with patch("nikita_archive.profiles.time.time",return_value=103):
            self.observer.user_update(types.UpdateUserStatus(100,types.UserStatusRecently()))
        event=next(e for e in self.events() if e["kind"]=="block_signals.visibility_restored")
        self.assertEqual(event["payload"]["after"]["certainty"],"observation")
        self.assertEqual(self.client.calls,[])

    async def test_slow_full_response_does_not_overwrite_new_own_block_update(self):
        self.store.observe_availability(100,{"profile_request":"ok","photo_visible":True,"last_seen_visibility":"visible","blocked_by_me":False})
        original=self.observer.request
        async def request(value):
            result=await original(value)
            if isinstance(value,functions.users.GetFullUserRequest):
                self.observer.user_update(types.UpdatePeerBlocked(types.PeerUser(100),blocked=True))
            return result
        self.observer.request=request
        await self.observer.scan(100,"456")
        assessment=self.store.status(100)["profiles"][0]["block_assessment"]
        self.assertTrue(assessment["observations"]["blocked_by_me"])
        self.assertFalse(any(e["kind"]=="own_blocklist.unblocked" for e in self.events()))

    async def test_negative_photo_update_invalidates_an_older_full_response(self):
        self.store.observe_availability(100,{"profile_request":"ok","photo_visible":False,"last_seen_visibility":"UserStatusEmpty"})
        self.client.user.photo=NS(photo_id=1)
        self.client.user.status=types.UserStatusRecently()
        original=self.observer.request
        async def request(value):
            result=await original(value)
            if isinstance(value,functions.users.GetFullUserRequest):
                class PhotoUpdate:
                    user_id=100
                    photo=types.UserProfilePhotoEmpty()
                with patch.object(types,"UpdateUserPhoto",PhotoUpdate,create=True):
                    self.observer.user_update(PhotoUpdate())
            return result
        self.observer.request=request
        await self.observer.scan(100,"456")
        assessment=self.store.status(100)["profiles"][0]["block_assessment"]
        self.assertFalse(assessment["observations"]["photo_visible"])
        self.assertEqual(assessment["state"],"insufficient_evidence")

    async def test_gift_count_change_refreshes_without_waiting_for_gift_interval(self):
        self.client.info.stargifts_count=1
        await self.observer.scan(100,"456")
        self.client.info.stargifts_count=2
        await self.observer.scan(100,"456")
        self.assertEqual(len([r for r in self.client.calls if isinstance(r,functions.payments.GetSavedStarGiftsRequest)]),2)

    async def test_hydration_and_scan_share_rpc_backoff_deadline(self):
        observer=ProfileCollector(self.client,self.store)
        observer.pause_until=135
        clock=[100.0];sleeps=[]
        async def fake_sleep(seconds):
            sleeps.append(seconds)
            clock[0]+=seconds
        with patch("nikita_archive.profile_collector.time.monotonic",lambda:clock[0]), patch("nikita_archive.profile_collector.asyncio.sleep",fake_sleep):
            await observer.request(functions.users.GetFullUserRequest(types.InputUser(100,456)))
            self.assertEqual(sleeps,[35])
            self.client.flood=True
            with self.assertRaises(errors.FloodWaitError):
                await observer.request(functions.users.GetFullUserRequest(types.InputUser(100,456)))
            self.assertEqual(observer.pause_until,clock[0]+37)

    async def test_rpc_rechecks_backoff_extended_while_already_sleeping(self):
        observer=ProfileCollector(self.client,self.store)
        observer.last_request=100
        clock=[100.0];sleeps=[];calls=[]
        async def fake_sleep(seconds):
            sleeps.append(seconds)
            clock[0]+=seconds
            if len(sleeps)==1:
                observer.pause_until=clock[0]+35
        async def client(request,**kwargs):
            calls.append(clock[0])
        observer.client=client
        with patch("nikita_archive.profile_collector.time.monotonic",lambda:clock[0]), patch("nikita_archive.profile_collector.asyncio.sleep",fake_sleep):
            await observer.request(functions.users.GetFullUserRequest(types.InputUser(100,456)))
        self.assertEqual(sleeps,[1,35])
        self.assertEqual(calls,[136])

    async def test_rapid_username_change_and_removal_are_recorded_without_scan(self):
        self.store.fields(100,{"first_name":"Name","username":"old"})
        self.observer.user_update(types.UpdateUserName(100,"Name","",[
            types.Username(username="brief",active=True),types.Username(username="inactive",active=False)]))
        self.observer.user_update(types.UpdateUserName(100,"Name","",[]))
        names=[e["payload"]["after"] for e in reversed(self.events()) if e["kind"]=="profile.changed" and e["payload"]["field"]=="username"]
        self.assertEqual(names,["brief",None])
        self.assertEqual(self.client.calls,[])

    async def test_story_metadata_survives_a_media_reference_capture_error(self):
        def fail(*args): raise ValueError("private file reference")
        self.observer.capture.photo=fail
        await self.observer.pushed_story(NS(peer=types.PeerUser(100),story=self.story()))
        event=next(e for e in self.events() if e["kind"]=="stories.added")
        self.assertEqual(event["payload"]["after"]["caption"],"Brief story")
        self.assertEqual(event["payload"]["after"]["media_capture_error"],"ValueError")
        self.assertNotIn("private file reference",json.dumps(event))

    async def test_story_poll_records_new_story_while_gift_collection_is_blocked(self):
        gift_started=asyncio.Event();release_gift=asyncio.Event()
        published=[False]
        story_calls=[]
        async def request(value,**kwargs):
            if isinstance(value,functions.payments.GetSavedStarGiftsRequest):
                gift_started.set()
                await release_gift.wait()
            if isinstance(value,functions.stories.GetPeerStoriesRequest):
                story_calls.append(value.peer.user_id)
                return NS(stories=NS(stories=[self.story()] if published[0] else []))
            return await self.client(value,**kwargs)
        self.observer.request=request
        self.observer.story_poll_interval=0.02
        task=asyncio.create_task(self.observer.run())
        try:
            await asyncio.wait_for(gift_started.wait(),2)
            self.assertFalse(any(e["kind"]=="stories.added" for e in self.events()))
            published[0]=True
            async def received():
                while not any(e["kind"]=="stories.added" for e in self.events()):
                    await asyncio.sleep(0.01)
            await asyncio.wait_for(received(),2)
            self.assertFalse(release_gift.is_set())
            self.assertFalse(task.done())
            self.assertTrue(story_calls)
            status=self.store.status(100)["profiles"][0]
            self.assertGreater(status["last_story_check"],0)
            self.assertEqual(status["story_error"],"")
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
        self.assertIsNone(self.observer.story_poll_task)

    async def test_slow_gift_rpc_does_not_hold_story_pacing_lock(self):
        observer=ProfileCollector(self.client,self.store)
        gift_started=asyncio.Event();release=asyncio.Event();started=[]
        async def client(value,**kwargs):
            started.append(time.monotonic())
            if isinstance(value,functions.payments.GetSavedStarGiftsRequest):
                gift_started.set()
                await release.wait()
            return NS(stories=NS(stories=[]))
        observer.client=client
        gift=asyncio.create_task(observer.request(functions.payments.GetSavedStarGiftsRequest(types.InputPeerUser(100,456),"",100)))
        try:
            await asyncio.wait_for(gift_started.wait(),2)
            await asyncio.wait_for(observer.request(functions.stories.GetPeerStoriesRequest(types.InputPeerUser(100,456))),3)
            self.assertFalse(gift.done())
            self.assertGreaterEqual(started[1]-started[0],0.9)
        finally:
            release.set()
            await gift
            await observer.close()

    async def test_story_poll_backoff_is_separate_from_full_profile_status(self):
        self.client.flood=True
        task=asyncio.create_task(self.observer.poll_stories())
        try:
            async def paused():
                while not self.observer.pause_until>time.monotonic():
                    await asyncio.sleep(0.01)
            await asyncio.wait_for(paused(),2)
            await asyncio.sleep(0.05)
            self.assertEqual(len(self.client.calls),1)
            status=self.store.status(100)["profiles"][0]
            self.assertIn("ограничил",status["story_error"])
            self.assertEqual(status["error"],"")
            self.assertEqual(status["last_story_check"],0)
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task

    async def test_avatar_pagination_uses_paced_requests_and_keeps_collection_on_failure(self):
        self.store.collection(100,"avatars",{"existing":{"id":"existing"}})
        calls=[]
        photo=self.story().media.photo
        async def request(value,**kwargs):
            calls.append(value)
            if value.offset:
                raise errors.FloodWaitError(value,capture=35)
            return NS(photos=[photo]*100,count=101)
        self.observer.request=request
        with self.assertRaises(errors.FloodWaitError):
            await self.observer.avatars(100,types.InputPeerUser(100,456),(11,),[])
        self.assertTrue(all(isinstance(call,functions.photos.GetUserPhotosRequest) for call in calls))
        self.assertEqual([call.offset for call in calls],[0,100])
        self.assertFalse(any(e["kind"]=="avatars.no_longer_visible" for e in self.events()))

    async def test_profile_wait_never_shortens_a_longer_story_backoff(self):
        async def request(value):
            self.observer.pause_until=time.monotonic()+300
            raise errors.FloodWaitError(value,capture=35)
        self.observer.request=request
        task=asyncio.create_task(self.observer.run_profiles())
        try:
            async def paused():
                while not self.observer.pause_until>time.monotonic():
                    await asyncio.sleep(0.01)
            await asyncio.wait_for(paused(),2)
            self.assertGreater(self.observer.pause_until-time.monotonic(),290)
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
