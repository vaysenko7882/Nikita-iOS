#!/usr/bin/env python3
"""Replace inherited UI names before strings are compiled; preserve source attribution."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
count = 0
for path in (ROOT / 'Telegram/Telegram-iOS').glob('*.lproj/*.strings'):
    raw = path.read_bytes()
    encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8'
    source = raw.decode(encoding)
    lines = []
    for line in source.splitlines(keepends=True):
        if '=' in line:
            key, value = line.split('=', 1)
            if '://' not in value:
                value, replaced = re.subn(r'\b(?:MadGram|MedGram|Никита)\b', 'CodeGram', value, flags=re.IGNORECASE)
                count += replaced
            line = key + '=' + value
        lines.append(line)
    updated = ''.join(lines)
    if updated != source:
        path.write_bytes(updated.encode(encoding))
print(f'Prepared CodeGram localized UI names ({count} inherited names replaced).')

# Visible Cyrillic names only; preserve internal identifiers and resource paths.
for relative in ('submodules/AuthorizationUI/Sources/AuthorizationSequenceSplashController.swift',
                 'submodules/SettingsUI/Sources/MadgramSettingsController.swift'):
    path = ROOT / relative
    if path.exists():
        path.write_text(path.read_text().replace('Никита', 'CodeGram').replace('НИКИТА', 'CodeGram'))
