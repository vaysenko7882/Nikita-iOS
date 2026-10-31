"""Private, consistent copies of existing Telethon SQLite sessions."""
from contextlib import closing
from pathlib import Path
import argparse
import os
import sqlite3


def _verify_database(database):
    try:
        columns = {row[1] for row in database.execute("PRAGMA table_info(sessions)")}
        if not {"dc_id", "server_address", "port", "auth_key"}.issubset(columns):
            raise ValueError("Нужна SQLite-сессия Telethon. Pyrogram, tdata и строковые сессии не подходят.")
        version = database.execute("SELECT version FROM version").fetchone()
        row = database.execute("SELECT dc_id,server_address,port,auth_key FROM sessions").fetchone()
        if not version or not isinstance(version[0], int) or version[0] < 1:
            raise ValueError("В файле нет версии сессии Telethon.")
        if (not row or not isinstance(row[0], int) or row[0] <= 0 or
                not isinstance(row[1], str) or not row[1] or
                not isinstance(row[2], int) or not 1 <= row[2] <= 65535 or
                not isinstance(row[3], bytes) or len(row[3]) != 256):
            raise ValueError("В файле нет готового ключа сессии. Новый код не запрашивался.")
    except sqlite3.Error:
        raise ValueError("Файл повреждён или не является SQLite-сессией Telethon.") from None


def _source_uri(path):
    source = Path(path).resolve(strict=True)
    if not source.is_file():
        raise ValueError("Укажи обычный файл сессии на своём VPS.")
    return source.as_uri() + "?mode=ro"


def validate_session(path):
    with closing(sqlite3.connect(_source_uri(path), uri=True, timeout=5)) as database:
        _verify_database(database)


def copy_session(source, destination):
    # O_EXCL prevents replacing any existing session, including symlinks. The
    # SQLite backup includes committed WAL records without altering the source.
    destination = Path(destination)
    created = False
    try:
        with closing(sqlite3.connect(_source_uri(source), uri=True, timeout=5)) as original:
            _verify_database(original)
            descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
            created = True
            with closing(sqlite3.connect(destination)) as snapshot:
                original.backup(snapshot)
                _verify_database(snapshot)
    except Exception:
        if created:
            destination.unlink(missing_ok=True)
        raise


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Copy your existing Telethon session without logging in")
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    try:
        copy_session(args.source, args.destination)
    except ValueError as error:
        parser.exit(1, f"Nikita: {error}\n")
    except (OSError, sqlite3.Error):
        parser.exit(1, "Nikita: Не удалось прочитать файл сессии или создать его приватную копию.\n")


if __name__ == "__main__":
    main()
