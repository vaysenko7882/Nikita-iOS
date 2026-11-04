import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from nikita_archive.archive import Archive
from nikita_archive.http_api import make_server
from nikita_archive.media_store import MediaStore
from nikita_archive.policy import CapturePolicy
from nikita_archive.profiles import ProfileStore, public_value


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.archive = Archive(Path(self.temp.name)/"archive.sqlite3")
        self.archive.set_account(123)
        self.archive.policy = CapturePolicy(self.archive)
        self.archive.media = MediaStore(self.archive,{"media_min_free_bytes":0})
        self.store = ProfileStore(self.archive)
        self.archive.profiles = self.store
        self.store.configure(100,{"enabled":True,"access_hash":"-456","title":"Person"})

    def tearDown(self):
        self.temp.cleanup()

    def history(self):
        return self.store.history(100,limit=100)["events"]

    def test_story_diagnostics_migrate_without_changing_profile_state(self):
        legacy=Archive(Path(self.temp.name)/"legacy.sqlite3")
        with legacy.connect() as db:
            db.execute("""CREATE TABLE tracked_profiles(peer_id INTEGER PRIMARY KEY,access_hash TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,title TEXT NOT NULL DEFAULT '',next_check INTEGER NOT NULL DEFAULT 0,
                last_check INTEGER NOT NULL DEFAULT 0,error TEXT NOT NULL DEFAULT '',fields TEXT NOT NULL DEFAULT '{}')""")
            db.execute("INSERT INTO tracked_profiles(peer_id,access_hash,title,error) VALUES(100,'456','Kept','ProfileError')")
        restored=ProfileStore(legacy)
        self.assertEqual(restored.watching(),[(100,'456')])
        status=restored.status(100)["profiles"][0]
        self.assertEqual((status["last_story_check"],status["story_error"]),(0,""))
        restored.story_checked(100,"StoryError")
        restored.story_checked(100)
        status=restored.status(100)["profiles"][0]
        self.assertGreater(status["last_story_check"],0)
        self.assertEqual(status["story_error"],"")
        self.assertEqual(status["error"],"ProfileError")
        self.assertEqual(status["title"],"Kept")
        self.assertNotIn("access_hash",json.dumps(restored.status()))

    def test_opt_in_is_required_and_disabled_history_survives(self):
        self.store.fields(200,{"first_name":"Untracked"})
        self.assertEqual(self.store.history(200)["events"],[])
        self.store.fields(100,{"first_name":"Before"})
        self.store.configure(100,{"enabled":False})
        count = len(self.history())
        self.store.fields(100,{"first_name":"After"})
        self.store.collection(100,"stories",{"1":{"caption":"ignored"}})
        self.assertEqual(len(self.history()),count)
        restored = ProfileStore(self.archive)
        self.assertEqual(len(restored.history(100)["events"]),count)
        self.assertFalse(restored.status(100)["profiles"][0]["enabled"])

    def test_previous_name_bio_and_gift_count_are_retained_without_fake_changes(self):
        first = {"first_name":"Alice","about":"Old","stargifts_count":2}
        self.store.fields(100,first); self.store.fields(100,first)
        self.store.fields(100,{**first,"about":"New","stargifts_count":3})
        changed = [e for e in self.history() if e["kind"]=="profile.changed"]
        self.assertEqual(len(changed),2)
        bio = next(e["payload"] for e in changed if e["payload"]["field"]=="about")
        self.assertEqual((bio["before"],bio["after"]),("Old","New"))

    def test_gift_sender_date_attributes_and_visibility_are_preserved(self):
        gift = {"sender":{"id":"7","first_name":"Sender"},"date":1234,"gift":{"id":9,"title":"Gift","attributes":[{"name":"Model"}]}}
        self.store.collection(100,"gifts",{"g1":gift})
        self.store.collection(100,"gifts",{})
        removed = self.history()[0]
        self.assertEqual(removed["kind"],"gifts.no_longer_visible")
        self.assertEqual(removed["payload"]["before"],gift)
        self.store.collection(100,"gifts",{"g1":gift})
        self.assertEqual(self.history()[0]["kind"],"gifts.added")

    def test_partial_or_failed_pages_never_remove_visible_gifts(self):
        self.store.collection(100,"gifts",{"a":{"id":1},"b":{"id":2}})
        self.store.collection(100,"gifts",{"a":{"id":1}},complete=False)
        self.assertFalse(any(e["kind"].endswith("no_longer_visible") for e in self.history()))

    def test_stable_gift_order_does_not_generate_repeated_removal(self):
        for _ in range(3):
            self.store.collection(100,"gifts",{"a":{"id":1}})
            self.store.collection(100,"gifts",{"_visible_order":{"count":1,"order":["a"]}},complete=False)
        self.assertEqual(len([e for e in self.history() if e["kind"].startswith("gifts.")]),2)

    def test_tracking_permission_allows_its_media_and_disable_pauses(self):
        blob = self.archive.media.register("profile-picture",{},8,"image/jpeg",1000)
        identifier = blob["blob_id"]
        self.assertFalse(self.archive.media.permitted(identifier))
        self.store.associate(100,{"asset":blob})
        self.assertTrue(self.archive.media.permitted(identifier))
        self.store.configure(100,{"enabled":False})
        self.assertFalse(self.archive.media.permitted(identifier))

    def test_history_has_all_pages_without_duplicates(self):
        for index in range(80):
            self.store.fields(100,{"first_name":str(index)})
        values, before = [], 0
        while True:
            page = self.store.history(100,before,7)
            values += [e["seq"] for e in page["events"]]
            if not page["has_more"]: break
            before = page["next_before"]
        self.assertEqual(len(values),81)
        self.assertEqual(len(values),len(set(values)))

    def test_credentials_and_phone_are_not_exported_recursively(self):
        value = public_value({"access_hash":123,"phone":"secret","gift":{"file_reference":b"secret","model":"Kept"},"bytes":b"private"})
        self.assertEqual(value,{"gift":{"model":"Kept"}})
        self.assertNotIn("access_hash",json.dumps(self.store.status()))

    def test_availability_is_never_interpreted_as_proven_target_block(self):
        self.store.collection(100,"availability",{"current":{"photo_visible":True,"blocked_by_target":"unknown_not_exposed_by_telegram"}},complete=False)
        self.store.collection(100,"availability",{"current":{"photo_visible":False,"blocked_by_target":"unknown_not_exposed_by_telegram"}},complete=False)
        event = self.history()[0]
        self.assertEqual(event["kind"],"availability.changed")
        self.assertEqual(event["payload"]["after"]["blocked_by_target"],"unknown_not_exposed_by_telegram")

    def observe(self, when, **values):
        with patch("nikita_archive.profiles.time.time",return_value=when):
            self.store.observe_availability(100,values)
        return self.store.status(100)["profiles"][0]["block_assessment"]

    def test_missing_data_and_status_alone_are_not_a_target_block(self):
        self.observe(100,profile_request="ok",photo_visible=False,last_seen_visibility="UserStatusEmpty")
        self.observe(101,profile_request="ok",photo_visible=False,last_seen_visibility="NoneType")
        self.assertEqual(self.store.status(100)["profiles"][0]["block_assessment"]["state"],"insufficient_evidence")
        self.observe(102,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        result=self.observe(103,last_seen_visibility="UserStatusEmpty")
        self.assertEqual(result["state"],"insufficient_evidence")
        self.assertFalse(any(e["kind"].startswith("block_signals.") for e in self.history()))

    def test_recent_status_and_photo_loss_is_inferred_not_confirmed(self):
        self.observe(100,profile_request="ok",photo_visible=True,last_seen_visibility="visible",blocked_by_me=False)
        self.observe(101,last_seen_visibility="UserStatusEmpty")
        result=self.observe(102,photo_visible=False)
        self.assertEqual((result["state"],result["certainty"]),("possible_restriction","inferred"))
        self.assertEqual(result["blocked_by_target"],"unknown_not_exposed_by_telegram")
        self.assertEqual(result["reasons"],["status_became_unavailable","photo_became_unavailable"])
        self.assertTrue(result["before"]["photo_visible"])
        self.assertEqual(result["previously_visible_at"],100)
        self.observe(103,profile_request="ok",photo_visible=False,last_seen_visibility="UserStatusEmpty")
        self.store=ProfileStore(self.archive)
        self.observe(104,profile_request="ok",photo_visible=False,last_seen_visibility="UserStatusEmpty")
        events=[e for e in self.history() if e["kind"]=="block_signals.possible_restriction"]
        self.assertEqual(len(events),1)
        self.assertEqual(events[0]["payload"]["after"]["possible_since"],102)

    def test_stale_or_confounded_observations_do_not_raise_block_inference(self):
        self.observe(100,profile_request="ok",photo_visible=True,last_seen_visibility="visible",blocked_by_me=False)
        self.observe(110,profile_request="unavailable",reason="UserPrivacyRestrictedError")
        result=self.observe(300,profile_request="ok",photo_visible=False,last_seen_visibility="UserStatusEmpty")
        self.assertEqual(result["state"],"insufficient_evidence")
        self.observe(301,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        result=self.observe(302,photo_visible=False,last_seen_visibility="UserStatusEmpty",blocked_by_me=True)
        self.assertEqual(result["state"],"insufficient_evidence")
        self.assertEqual(result["reasons"],["blocked_by_me"])
        self.observe(303,blocked_by_me=False)
        self.observe(304,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        result=self.observe(305,photo_visible=False,last_seen_visibility="UserStatusEmpty",account_deleted=True)
        self.assertEqual(result["reasons"],["account_deleted"])
        self.assertFalse(any(e["kind"]=="block_signals.possible_restriction" for e in self.history()))

    def test_restored_visibility_is_not_reported_as_confirmed_unblock(self):
        self.observe(100,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        self.observe(101,photo_visible=False,last_seen_visibility="UserStatusEmpty")
        result=self.observe(102,last_seen_visibility="visible")
        self.assertEqual((result["state"],result["certainty"]),("visibility_restored","observation"))
        events=[e for e in self.history() if e["kind"]=="block_signals.visibility_restored"]
        self.assertEqual(len(events),1)
        self.assertEqual(events[0]["payload"]["after"]["blocked_by_target"],"unknown_not_exposed_by_telegram")
        self.observe(103,last_seen_visibility="UserStatusEmpty")
        self.assertEqual(len([e for e in self.history() if e["kind"]=="block_signals.possible_restriction"]),1)

    def test_inference_ignores_gifts_and_does_not_journal_duplicate_presence(self):
        self.observe(100,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        count=len(self.history())
        with patch("nikita_archive.profiles.time.time",return_value=101):
            self.store.observe_availability(100,{"last_seen_visibility":"visible"},source="telegram_update",record_general=False)
        self.assertEqual(len(self.history()),count)
        self.store.collection(100,"gifts",{"gift":{"gift":{"id":7}}})
        self.store.collection(100,"gifts",{})
        self.assertFalse(any(e["kind"].startswith("block_signals.") for e in self.history()))

    def test_reenabling_tracking_does_not_reuse_unobserved_restriction_state(self):
        self.observe(100,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        self.observe(101,photo_visible=False,last_seen_visibility="UserStatusEmpty")
        self.assertEqual(self.store.status(100)["profiles"][0]["block_assessment"]["state"],"possible_restriction")
        self.store.configure(100,{"enabled":False})
        self.assertIsNone(self.store.status(100)["profiles"][0]["block_assessment"])
        self.store.configure(100,{"enabled":True,"access_hash":"-456"})
        self.assertIsNone(self.store.status(100)["profiles"][0]["block_assessment"])
        result=self.observe(102,photo_visible=False,last_seen_visibility="UserStatusEmpty",profile_request="ok")
        self.assertEqual(result["state"],"insufficient_evidence")
        self.assertEqual(len([e for e in self.history() if e["kind"]=="block_signals.possible_restriction"]),1)
        self.observe(103,photo_visible=True,last_seen_visibility="visible")
        self.assertFalse(any(e["kind"]=="block_signals.visibility_restored" for e in self.history()))

    def test_disabled_tracking_does_not_receive_block_assessment(self):
        self.store.configure(100,{"enabled":False})
        count=len(self.history())
        self.observe(100,profile_request="ok",photo_visible=True,last_seen_visibility="visible")
        self.assertEqual(len(self.history()),count)
        self.assertIsNone(self.store.status(100)["profiles"][0]["block_assessment"])

    def test_raw_notifications_deduplicate_but_changed_name_is_logged(self):
        self.store.collection(100,"notifications",{"_name":{"first_name":"Before"}},complete=False)
        self.store.collection(100,"notifications",{"_name":{"first_name":"Before"}},complete=False)
        self.store.collection(100,"notifications",{"_name":{"first_name":"After"}},complete=False)
        self.assertEqual(len([e for e in self.history() if e["kind"].startswith("notifications.")]),2)

    def test_invalid_or_excessive_targets_do_not_replace_state(self):
        for invalid in [-1,0,"x",True,2**63]:
            with self.assertRaises(ValueError): self.store.configure(invalid,{"enabled":True,"access_hash":"1"})
        with self.assertRaises(ValueError): self.store.configure(100,{"enabled":True,"access_hash":"secret"})
        self.assertTrue(self.store.enabled(100))
        for i in range(1,self.store.MAX_PROFILES): self.store.configure(100+i,{"enabled":True,"access_hash":"1"})
        with self.assertRaises(ValueError): self.store.configure(999,{"enabled":True,"access_hash":"1"})

    def test_profile_http_auth_account_binding_and_private_hash(self):
        server = make_server(self.archive,"t"*48,0)
        thread = threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def call(method,path,body=None,headers=None):
            conn = http.client.HTTPConnection("127.0.0.1",server.server_address[1],timeout=5)
            conn.request(method,path,body=json.dumps(body) if body else None,headers=headers or {})
            response=conn.getresponse();value=json.loads(response.read());conn.close();return response.status,value
        try:
            self.assertEqual(call("GET","/v1/profiles")[0],401)
            auth={"Authorization":"Bearer "+"t"*48}
            self.assertEqual(call("PUT","/v1/profiles/100",{"enabled":False},auth)[0],403)
            auth["X-CodeGram-Account-ID"]="123"
            code,value=call("GET","/v1/profiles/100/history",headers=auth)
            self.assertEqual(code,200);self.assertEqual(value["account_id"],123)
            self.assertEqual(value["server_version"],5)
            self.assertNotIn("access_hash",json.dumps(value))
            self.assertEqual(call("PUT","/v1/profiles/100",{"enabled":False},auth)[0],200)
            self.assertFalse(self.store.enabled(100))
        finally:
            server.shutdown();server.server_close();thread.join()


    def test_explicit_story_tombstone_survives_restart_and_late_poll(self):
        self.store.collection(100,"stories",{"1":{"caption":"Preserved","media":{"blob_id":"retained"}}})
        self.store.deleted_story(100,1)
        restored=ProfileStore(self.archive)
        restored.collection(100,"stories",{"1":{"caption":"Stale poll"}})
        with self.archive.connect() as db:
            self.assertEqual(db.execute("SELECT active FROM profile_items WHERE section='stories' AND item_id='1'").fetchone()[0],0)
        events=[e for e in self.history() if e["kind"]=="stories.deleted"]
        self.assertEqual(len(events),1)
        self.assertEqual(events[0]["payload"]["before"]["caption"],"Preserved")

    def test_profile_nudge_rechecks_soon_without_erasing_other_fields(self):
        with patch("nikita_archive.profiles.time.time",return_value=1000):
            self.store.checked(100)
            self.store.nudge(100)
        with self.archive.connect() as db:
            self.assertEqual(db.execute("SELECT next_check FROM tracked_profiles WHERE peer_id=100").fetchone()[0],1002)
        self.assertEqual(self.store.status()["poll_interval"],15)
        self.assertEqual(self.store.status()["gift_interval"],60)

    def test_disabled_profile_ignores_story_push_and_tombstone(self):
        self.store.configure(100,{"enabled":False})
        count=len(self.history())
        self.store.skipped_story(100,{"id":1})
        self.store.deleted_story(100,1)
        self.assertEqual(len(self.history()),count)
