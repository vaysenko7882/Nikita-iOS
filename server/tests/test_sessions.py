import contextlib
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nikita_archive.__main__ import use_session
from nikita_archive.archive import Archive
from nikita_archive.session_files import copy_session, validate_session


def session_file(path, key=bytes(range(256))):
    with sqlite3.connect(path) as database:
        database.executescript("""
            CREATE TABLE version(version INTEGER PRIMARY KEY);
            INSERT INTO version VALUES(7);
            CREATE TABLE sessions(dc_id INTEGER PRIMARY KEY,server_address TEXT,port INTEGER,auth_key BLOB,takeout_id INTEGER);
            CREATE TABLE entities(id INTEGER PRIMARY KEY, name TEXT);
        """)
        database.execute("INSERT INTO sessions VALUES(2,'149.154.167.51',443,?,NULL)", (key,))


class SessionFilesTests(unittest.TestCase):
    def test_backup_includes_committed_wal_data_without_modifying_source(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/"my_account.session"
            destination = Path(directory)/"archive.session"
            session_file(source)
            with contextlib.closing(sqlite3.connect(source)) as writer:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.execute("INSERT INTO entities VALUES(1,'committed in WAL')")
                writer.commit()
                before = source.read_bytes()
                copy_session(source, destination)
                self.assertEqual(source.read_bytes(), before)
                with contextlib.closing(sqlite3.connect(destination)) as copied:
                    self.assertEqual(copied.execute("SELECT name FROM entities").fetchone()[0], "committed in WAL")
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            validate_session(destination)

    def test_does_not_overwrite_an_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory)/"source.session", Path(directory)/"existing.session"
            session_file(source)
            destination.write_bytes(b"existing data")
            with self.assertRaises(FileExistsError):
                copy_session(source, destination)
            self.assertEqual(destination.read_bytes(), b"existing data")

    def test_missing_source_does_not_create_an_empty_session(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory)/"missing.session", Path(directory)/"copy.session"
            with self.assertRaises(FileNotFoundError):
                copy_session(source, destination)
            self.assertFalse(source.exists())
            self.assertFalse(destination.exists())

    def test_unauthorized_empty_key_is_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory)/"source.session", Path(directory)/"copy.session"
            session_file(source, key=b"")
            with self.assertRaisesRegex(ValueError, "нет готового ключа"):
                copy_session(source, destination)
            self.assertFalse(destination.exists())

    def test_other_session_formats_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"pyrogram.session"
            with sqlite3.connect(path) as database:
                database.execute("CREATE TABLE sessions(dc_id INTEGER, api_id INTEGER, auth_key BLOB, user_id INTEGER)")
            with self.assertRaisesRegex(ValueError, "Telethon"):
                validate_session(path)
            path.write_text("a string session is not a SQLite file")
            with self.assertRaisesRegex(ValueError, "Telethon"):
                validate_session(path)


class ActivateSessionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config_path = self.directory/"config.json"
        self.snapshot = self.directory/"imported.session"
        session_file(self.snapshot)
        self.config = {"api_id": 123, "api_hash": "a"*32, "token": "existing-private-token",
            "session_path": str(self.directory/"previous"), "database_path": str(self.directory/"archive.sqlite3")}
        self.config_path.write_text(json.dumps(self.config))
        self.client = SimpleNamespace(connect=mock.AsyncMock(), disconnect=mock.AsyncMock(),
            is_user_authorized=mock.AsyncMock(return_value=True),
            get_me=mock.AsyncMock(return_value=SimpleNamespace(id=12345, bot=False)),
            start=mock.AsyncMock(side_effect=AssertionError("new login is forbidden")),
            send_code_request=mock.AsyncMock(side_effect=AssertionError("codes are forbidden")))
        self.factory = mock.Mock(return_value=self.client)

    async def activate(self):
        with mock.patch.dict(sys.modules, {"nikita_archive.collector": SimpleNamespace(client_for=self.factory)}):
            with mock.patch("builtins.input", side_effect=AssertionError("prompts are forbidden")):
                with contextlib.redirect_stdout(io.StringIO()):
                    await use_session(self.config_path, self.snapshot)

    def assert_no_login(self):
        self.client.start.assert_not_called()
        self.client.send_code_request.assert_not_called()

    async def test_uses_existing_session_without_new_login_or_token_rotation(self):
        await self.activate()
        updated = json.loads(self.config_path.read_text())
        self.assertEqual(updated["session_path"], str(self.snapshot))
        self.assertEqual(updated["token"], self.config["token"])
        self.assertEqual(self.config_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(Archive(self.config["database_path"]).sync(0)["account_id"], 12345)
        self.client.disconnect.assert_awaited_once()
        self.assert_no_login()

    async def test_revoked_session_leaves_previous_config_intact(self):
        self.client.is_user_authorized.return_value = False
        before = self.config_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "отозвана"):
            await self.activate()
        self.assertEqual(self.config_path.read_bytes(), before)
        self.client.get_me.assert_not_called()
        self.client.disconnect.assert_awaited_once()
        self.assert_no_login()

    async def test_other_account_does_not_replace_session_or_mix_archive(self):
        Archive(self.config["database_path"]).set_account(999)
        before = self.config_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "different Telegram account"):
            await self.activate()
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertEqual(Archive(self.config["database_path"]).sync(0)["account_id"], 999)
        self.assert_no_login()

    async def test_bot_session_is_rejected(self):
        self.client.get_me.return_value = SimpleNamespace(id=12345, bot=True)
        before = self.config_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "не бота"):
            await self.activate()
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assert_no_login()

    async def test_invalid_file_is_rejected_before_any_network(self):
        self.snapshot.write_text("not a session")
        with self.assertRaisesRegex(ValueError, "Telethon"):
            await self.activate()
        self.factory.assert_not_called()

    async def test_network_failure_does_not_expose_details_or_change_config(self):
        self.client.connect.side_effect = ConnectionError("private transport detail")
        before = self.config_path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "ConnectionError") as captured:
            await self.activate()
        self.assertNotIn("private transport detail", str(captured.exception))
        self.assertEqual(self.config_path.read_bytes(), before)
        self.client.disconnect.assert_awaited_once()
        self.assert_no_login()


if __name__ == "__main__":
    unittest.main()
