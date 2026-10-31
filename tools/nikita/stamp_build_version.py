#!/usr/bin/env python3
"""Stamp bundle metadata without changing Bazel's global configuration."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def stamp(source, number):
    if not re.fullmatch(r"[1-9][0-9]{0,9}", str(number)):
        raise ValueError("A positive numeric build number is required")
    marker = '    name = "BuildNumberInfoPlist",'
    if source.count(marker) != 1:
        raise ValueError("Build-number rule changed; refusing an unchecked stamp")
    start = source.rfind("plist_fragment(", 0, source.index(marker))
    end = source.index("\n)", source.index(marker)) + 2
    block = source[start:end]
    pattern = r"(<key>CFBundleVersion</key>\s*<string>)(?:\{buildNumber\}|[0-9]+)(</string>)"
    updated, count = re.subn(pattern, lambda match: match[1] + str(number) + match[2], block)
    if count != 1:
        raise ValueError("Bundle-version template changed")
    return source[:start] + updated + source[end:]


if __name__ == "__main__":
    path = ROOT / "Telegram/BUILD"
    path.write_text(stamp(path.read_text(), sys.argv[1]))
    print("Stamped bundle build number; compilation configuration remains stable.")
