import argparse
import asyncio
import getpass
import json
import os
from pathlib import Path
import re
import secrets
import signal
import threading
import tempfile

from .archive import Archive
from .http_api import make_server


def load_config(path):
    config = json.loads(Path(path).read_text())
    if not re.fullmatch(r"[a-fA-F0-9]{32}", config.get("api_hash", "")) or int(config.get("api_id", 0)) <= 0:
        raise ValueError("Invalid Telegram API credentials in private configuration")
    return config


def configure(path, data_path):
    destination = Path(path)
    if destination.exists():
        raise ValueError("Configuration already exists; refusing to replace your session or token")
    api_id = input("Свой Telegram API ID (my.telegram.org/apps): ").strip()
    api_hash = getpass.getpass("Свой Telegram API hash (ввод скрыт): ").strip()
    if not api_id.isdigit() or int(api_id) <= 0 or not re.fullmatch(r"[a-fA-F0-9]{32}", api_hash):
        raise ValueError("Некорректные API ID / hash")
    directory = Path(data_path).resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = {"api_id": int(api_id), "api_hash": api_hash, "token": secrets.token_urlsafe(36),
        "session_path": str(directory / "telegram"), "database_path": str(directory / "archive.sqlite3"),
        "port": 8765, "seed_dialogs": 100, "seed_messages": 100,
        "media_enabled": True, "media_workers": 3, "media_min_free_bytes": 1024**3}
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(config, output)
    print("Конфигурация сохранена. Ключ для приложения (не публикуй):")
    print(config["token"])


async def login(config):
    from .collector import client_for
    client = client_for(config)
    # Telethon prompts in this VPS terminal. Login codes and 2FA never pass
    # through our HTTP API or the iPhone integration settings.
    await client.start(phone=lambda: input("Номер своего Telegram (+...): "),
        password=lambda: getpass.getpass("Пароль 2FA (ввод скрыт): "),
        code_callback=lambda: input("Код из Telegram: "))
    try:
        me = await client.get_me()
        Archive(config["database_path"]).set_account(me.id)
        print("Собственный аккаунт подключён. Теперь можно запустить службу.")
    finally:
        await client.disconnect()


async def use_session(config_path, session_path):
    from .collector import client_for
    from .session_files import validate_session

    session_path = Path(session_path).resolve(strict=True)
    if session_path.suffix != ".session":
        raise ValueError("Нужен файл с расширением .session.")
    validate_session(session_path)
    config = load_config(config_path)
    candidate = {**config, "session_path": str(session_path)}
    client = client_for(candidate)
    try:
        await asyncio.wait_for(client.connect(), timeout=60)
        if not await asyncio.wait_for(client.is_user_authorized(), timeout=30):
            raise ValueError("Сессия не авторизована или отозвана. Новый код не запрашивался.")
        me = await asyncio.wait_for(client.get_me(), timeout=30)
        if me is None or getattr(me, "bot", False):
            raise ValueError("Нужна сессия собственного пользовательского аккаунта, не бота.")
        account_id = me.id
    except (ValueError, RuntimeError):
        raise
    except Exception as error:
        raise RuntimeError("Не удалось проверить готовую сессию: " + type(error).__name__ +
            ". Новый код не запрашивался.") from None
    finally:
        await client.disconnect()

    # Refuse mixing accounts before changing the session pointer or token.
    Archive(config["database_path"]).set_account(account_id)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=Path(config_path).parent,
                prefix=".session-config-", delete=False) as output:
            temporary = Path(output.name)
            os.chmod(temporary, 0o600)
            json.dump(candidate, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, config_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Готовая сессия проверена и подключена. Новый код и пароль не запрашивались.")


async def run(config):
    from .collector import collect
    from .media_store import MediaStore
    archive = Archive(config["database_path"])
    archive.media = MediaStore(archive,config)
    archive.set_connected(False)
    server = make_server(archive, config["token"], int(config.get("port", 8765)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    task = asyncio.create_task(collect(config))
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, task.cancel)
    try:
        await task
    except asyncio.CancelledError:
        pass
    finally:
        server.shutdown()
        server.server_close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Nikita private archive")
    parser.add_argument("--config", default="/var/lib/nikita-archive/config.json")
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("configure")
    setup.add_argument("--data-path", default="/var/lib/nikita-archive")
    commands.add_parser("login")
    adopt = commands.add_parser("use-session")
    adopt.add_argument("session_path")
    commands.add_parser("run")
    commands.add_parser("show-token")
    args = parser.parse_args()
    try:
        if args.command == "configure":
            configure(args.config, args.data_path)
        elif args.command == "use-session":
            asyncio.run(use_session(args.config, args.session_path))
        elif args.command == "show-token":
            print(load_config(args.config)["token"])
        else:
            config = load_config(args.config)
            asyncio.run(login(config) if args.command == "login" else run(config))
    except (ValueError, OSError, RuntimeError) as error:
        # Error texts never include configuration values or session contents.
        parser.exit(1, f"Nikita: {error}\n")


if __name__ == "__main__":
    main()
