import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nikita_archive.archive import Archive
from nikita_archive.http_api import make_server

SCRATCH = Path(__file__).resolve().parents[2] / "build/nikita-server-tests"
SCRATCH.mkdir(parents=True, exist_ok=True)


def message(text="original", *, kind="user", peer=20, mid=10, version=100):
    return {"peer_type": kind, "peer_id": peer, "message_id": mid, "author_type": "user", "author_id": 20,
        "outgoing": False, "date": 100, "version_date": version, "text": text, "media_title": "", "thread_id": None,
        "fingerprint": text}


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.path = Path(self.folder.name) / "archive.sqlite3"
        self.archive = Archive(self.path)
        self.archive.set_account(123)

    def tearDown(self):
        self.folder.cleanup()

    def test_edits_archive_previous_content_and_deletion_archives_latest(self):
        self.archive.observe(message("A"))
        self.archive.observe(message("B", version=110))
        self.archive.observe(message("C", version=120))
        self.archive.delete([10], captured_at=130)
        events = self.archive.sync(0)["events"]
        self.assertEqual([event["text"] for event in events], ["A", "B", "C"])
        self.assertEqual([event["kind"] for event in events], ["edit", "edit", "delete"])
        self.assertEqual([event["captured_at"] for event in events], [110, 120, 130])
        self.assertNotIn("fingerprint", events[0])

    def test_reconnect_duplicates_do_not_duplicate_journal(self):
        self.archive.observe(message("A"))
        self.archive.observe(message("A"))
        self.archive.observe(message("B", version=110))
        self.archive.observe(message("B", version=110))
        self.archive.delete([10])
        self.archive.delete([10])
        self.assertEqual(len(self.archive.sync(0)["events"]), 2)

    def test_channel_deletion_cannot_delete_equal_id_from_another_channel(self):
        self.archive.observe(message("one", kind="channel", peer=1))
        self.archive.observe(message("two", kind="channel", peer=2))
        self.archive.observe(message("private", peer=30))
        self.archive.delete([10], channel_id=2)
        events = self.archive.sync(0)["events"]
        self.assertEqual([(event["peer_type"], event["peer_id"], event["text"]) for event in events], [("channel", 2, "two")])

    def test_unscoped_private_deletion_does_not_touch_channel(self):
        self.archive.observe(message("private"))
        self.archive.observe(message("channel", kind="channel"))
        self.archive.delete([10])
        self.assertEqual([event["text"] for event in self.archive.sync(0)["events"]], ["private"])

    def test_unknown_deletion_has_no_invented_content(self):
        self.archive.delete([77])
        result = self.archive.sync(0)
        self.assertEqual(result["events"], [])
        self.assertEqual(result["unknown_deletions"], 1)

    def test_stale_history_cannot_replace_newer_live_content(self):
        self.archive.observe(message("new", version=120))
        self.archive.observe(message("old", version=110), seed=True)
        self.archive.observe(message("race", version=120), seed=True)
        self.archive.delete([10])
        self.assertEqual([event["text"] for event in self.archive.sync(0)["events"]], ["new"])

    def test_newer_seed_preserves_content_already_observed_before_restart(self):
        self.archive.observe(message("A"))
        self.archive.observe(message("B", version=120), seed=True)
        self.assertEqual([event["text"] for event in self.archive.sync(0)["events"]], ["A"])

    def test_first_seed_does_not_invent_an_earlier_revision(self):
        self.archive.observe(message("already edited", version=120), seed=True)
        self.assertEqual(self.archive.sync(0)["events"], [])

    def test_tombstones_cannot_be_resurrected_by_old_update(self):
        self.archive.observe(message("A"))
        self.archive.delete([10])
        self.archive.observe(message("A"))
        self.archive.observe(message("B", version=120))
        self.assertEqual(len(self.archive.sync(0)["events"]), 1)

    def test_pagination_has_no_gaps_or_duplicate_sequences(self):
        self.archive.observe(message("A"))
        for i in range(1, 8):
            self.archive.observe(message(str(i), version=100 + i))
        cursor = 0
        seen = []
        while True:
            page = self.archive.sync(cursor, limit=2)
            seen.extend(event["seq"] for event in page["events"])
            cursor = page["next_cursor"]
            if not page["has_more"]:
                break
        self.assertEqual(seen, list(range(1, 8)))
        self.assertEqual(self.archive.sync(cursor)["events"], [])

    def test_restart_retains_identity_account_and_cursor(self):
        self.archive.observe(message("A"))
        self.archive.delete([10])
        before = self.archive.sync(0)
        after = Archive(self.path).sync(0)
        self.assertEqual(before, after)

    def test_replaced_server_forces_cursor_reset(self):
        self.archive.observe(message("A"))
        self.archive.delete([10])
        page = self.archive.sync(9000, server_id="old-instance")
        self.assertTrue(page["reset_required"])
        self.assertEqual(page["next_cursor"], 0)
        self.assertEqual(page["events"], [])

    def test_cannot_attach_different_account_to_existing_archive(self):
        with self.assertRaises(ValueError):
            self.archive.set_account(456)
        self.assertEqual(self.archive.sync(0)["account_id"], 123)

    def test_quotes_unicode_and_sql_are_plain_message_data(self):
        text = "Никита '); DROP TABLE events; -- <script>"
        self.archive.observe(message(text))
        self.archive.delete([10])
        self.assertEqual(self.archive.sync(0)["events"][0]["text"], text)

    def test_negative_cursor_is_rejected(self):
        with self.assertRaises(ValueError):
            self.archive.sync(-1)

    def test_http_authentication_and_read_only_sync(self):
        self.archive.observe(message("private text"))
        self.archive.delete([10])
        token = "X" * 48
        server = make_server(self.archive, token, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            with self.assertRaises(HTTPError) as result:
                urlopen(base + "/v1/sync", timeout=5)
            self.assertEqual(result.exception.code, 401)
            self.assertNotIn(b"private text", result.exception.read())
            request = Request(base + "/v1/sync?after=0", headers={"Authorization": "Bearer " + token})
            with urlopen(request, timeout=5) as response:
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                payload = json.load(response)
            self.assertEqual(payload["account_id"], 123)
            self.assertEqual(payload["events"][0]["text"], "private text")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
