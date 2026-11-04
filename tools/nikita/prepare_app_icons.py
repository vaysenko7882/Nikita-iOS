#!/usr/bin/env python3
"""Register the owner's native alternate icons in the unsigned device package."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def png(path, size):
    data = path.read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data) < 24 or struct.unpack_from('>II', data, 16) != (size, size):
        raise ValueError('Invalid generated icon: ' + path.name)
    return data


def prepare(source, destination, *, root=ROOT):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Keep the original compiled IPA separate from the prepared package.')
    choices = json.loads((root / 'tools/nikita/assets/icons/manifest.json').read_text())
    images = root / 'Telegram/Telegram-iOS'
    overlays = {}
    with zipfile.ZipFile(source) as original:
        locations = [n for n in original.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
        if len(locations) != 1:
            raise ValueError('Expected one compiled application.')
        location = locations[0]
        bundle = location.rsplit('/', 1)[0] + '/'
        info = plistlib.loads(original.read(location))
        if info.get('CFBundleIdentifier') != 'personal.nikita.messenger' or info.get('CFBundleDisplayName') != 'CodeGram':
            raise ValueError('Refusing to prepare a different application.')
        for choice in choices:
            name = choice['name']
            for suffix, size in (('@2x', 120), ('@3x', 180), ('Ipad', 76), ('Ipad@2x', 152), ('LargeIpad@2x', 167)):
                filename = name + suffix + '.png'
                overlays[bundle + filename] = png(images / (name + '.alticon') / filename, size)
            filename = name + 'Preview.png'
            overlays[bundle + filename] = png(images / 'CodeGramIconPreviews' / filename, 256)
            for key, files in (('CFBundleIcons', [name]), ('CFBundleIcons~ipad', [name + 'Ipad', name + 'LargeIpad'])):
                icons = info.setdefault(key, {}).setdefault('CFBundleAlternateIcons', {})
                icons[name] = {'CFBundleIconFiles': files, 'UIPrerenderedIcon': True}
        overlays[bundle + 'CGOriginalPreview.png'] = png(images / 'CodeGramIconPreviews/CGOriginalPreview.png', 256)
        overlays[location] = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=destination.name + '.', dir=destination.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
                for entry in original.infolist():
                    if entry.filename in overlays:
                        output.writestr(entry, overlays.pop(entry.filename))
                    else:
                        with original.open(entry) as reader, output.open(entry, 'w') as writer:
                            shutil.copyfileobj(reader, writer, 1024 * 1024)
                for filename, data in overlays.items():
                    output.writestr(filename, data)
            with zipfile.ZipFile(temporary) as check:
                if check.testzip() is not None:
                    raise ValueError('Prepared package failed its integrity check.')
            os.replace(temporary, destination)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return [choice['name'] for choice in choices]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print('Registered native alternate icons:', ', '.join(prepare(args.source, args.destination)))
