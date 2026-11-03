#!/usr/bin/env python3
"""Validate and identify an actual compiled iOS device artifact."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]

def validate(path, expected_version=None, expected_build=None, required_alternate_icons=()):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA integrity check failed.')
        names = [n for n in archive.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
        if len(names) != 1:
            raise ValueError('Expected one iPhone application.')
        location = names[0]
        info = plistlib.loads(archive.read(location))
        if info.get('CFBundleDisplayName') != 'CodeGram':
            raise ValueError('Compiled app does not have the CodeGram display name.')
        if info.get('CFBundleIdentifier') != 'personal.nikita.messenger':
            raise ValueError('Compiled app does not have the personal bundle identifier.')
        if expected_version is not None and info.get('CFBundleShortVersionString') != expected_version:
            raise ValueError('Compiled app version differs from the current source; refusing a stale artifact.')
        if expected_build is not None and info.get('CFBundleVersion') != str(expected_build):
            raise ValueError('Compiled build number differs from this run; refusing a stale artifact.')
        bundle = location.rsplit('/', 1)[0] + '/'
        for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            declared = info.get(key, {}).get('CFBundleAlternateIcons', {})
            if any(name not in declared for name in required_alternate_icons):
                raise ValueError('Compiled app is missing declared CodeGram alternate icons.')
        for name in required_alternate_icons:
            for suffix, size in (('@2x', 120), ('@3x', 180), ('Preview', 256)):
                filename = bundle + name + suffix + '.png'
                if filename not in archive.namelist():
                    raise ValueError('Compiled app is missing a CodeGram icon image: ' + name)
                header = archive.read(filename)[:24]
                if not header.startswith(b'\x89PNG\r\n\x1a\n') or struct.unpack_from('>II', header, 16) != (size, size):
                    raise ValueError('Invalid compiled CodeGram icon dimensions: ' + name)
        executable = location.rsplit('/', 1)[0] + '/' + info['CFBundleExecutable']
        data = archive.read(executable)
        magic, cpu = struct.unpack_from('<II', data)
        if magic != 0xfeedfacf or cpu != 0x100000c:
            raise ValueError('Expected an arm64 Mach-O executable.')
        offset = 32
        device = False
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            cmd, size = struct.unpack_from('<II', data, offset)
            if size < 8 or offset + size > len(data):
                raise ValueError('Invalid Mach-O load command.')
            if cmd == 0x32:
                device = struct.unpack_from('<I', data, offset + 8)[0] == 2
            if cmd == 0x2c and struct.unpack_from('<I', data, offset + 16)[0] != 0:
                raise ValueError('Encrypted executable cannot be re-signed.')
            offset += size
        if not device:
            raise ValueError('Simulator binaries cannot be installed on an iPhone.')
        return {'name': info['CFBundleDisplayName'], 'bundle_id': info['CFBundleIdentifier'], 'minimum_os': info['MinimumOSVersion'],
            'version': info.get('CFBundleShortVersionString'), 'build_number': info.get('CFBundleVersion')}

def main():
    source = Path(sys.argv[1])
    version = json.loads((ROOT / 'versions.json').read_text())['app']
    choices = json.loads((ROOT / 'tools/nikita/assets/icons/manifest.json').read_text())
    result = validate(source, expected_version=version, expected_build=os.environ.get('GITHUB_RUN_NUMBER', '1'), required_alternate_icons=[item['name'] for item in choices])
    result['alternate_icons'] = [item['name'] for item in choices]
    output = ROOT / 'build' / 'nikita'
    output.mkdir(parents=True, exist_ok=True)
    target = output / 'CodeGram.ipa'
    shutil.copyfile(source, target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (output / 'CodeGram.ipa.sha256').write_text(digest + '  CodeGram.ipa\n')
    result.update({
        'sha256': digest,
        'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'compiled': True, 'runtime_tested': False,
        'signing': 'Sign with the owner certificate before installation',
    })
    (output / 'Build.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('Validated compiled CodeGram IPA:', target)

if __name__ == '__main__':
    main()

