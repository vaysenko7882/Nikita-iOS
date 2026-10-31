#!/usr/bin/env python3
"""Stable toolchain identity and bounded reusable build-cache storage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def identity(versions, xcode, architecture):
    # The app version and GitHub run number must not invalidate dependency cache.
    toolchain = {key: versions[key] for key in ("xcode", "bazel", "macos")}
    toolchain.update(actual_xcode=xcode, architecture=architecture, layout=1)
    return hashlib.sha256(json.dumps(toolchain, sort_keys=True).encode()).hexdigest()[:24]


def prepare():
    root = Path.home()/"Library/Caches/NikitaBuild/v1"
    root.mkdir(parents=True, exist_ok=True)
    key = identity(json.loads((ROOT/"versions.json").read_text()),
        subprocess.check_output(["xcodebuild", "-version"], text=True).strip(), platform.machine())
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"toolchain={key}\npath={root}\n")
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"NIKITA_BUILD_CACHE={root}\n")


def prune():
    root = Path(os.environ["NIKITA_BUILD_CACHE"]).resolve()
    # Only these build outputs/downloads are cached. Never cache a workspace,
    # API configuration, signing certificate, Telegram session or credentials.
    for child, budget in [("actions", 8*1024**3), ("repositories", 1536*1024**2)]:
        folder = root/child
        if not folder.is_dir():
            continue
        files = []
        for path in folder.rglob("*"):
            try:
                if path.is_file() and not path.is_symlink():
                    info = path.stat()
                    files.append((info.st_mtime, info.st_size, path))
            except FileNotFoundError:
                pass # Bazel's idle garbage collector can remove an entry.
        size = sum(item[1] for item in files)
        before = size
        for _, length, path in sorted(files):
            if size <= budget:
                break
            path.unlink(missing_ok=True)
            size -= length
        # A missing CAS blob is a verified Bazel cache miss, never stale output.
        print(f"{child}: {before} bytes before / {size} bytes retained")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["prepare", "prune"])
    args = parser.parse_args()
    prepare() if args.command == "prepare" else prune()
