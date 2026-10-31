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

def validate(path, expected_version=None, expected_build=None):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA integrity check failed.')
        names = [n for n in archive.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
        if len(names) != 1:
            raise ValueError('Expected one iPhone application.')
        location = names[0]
        info = plistlib.loads(archive.read(location))
        if info.get('CFBundleDisplayName') != 'Никита':
            raise ValueError('Compiled app does not have the Nikita display name.')
        if info.get('CFBundleIdentifier') != 'personal.nikita.messenger':
            raise ValueError('Compiled app does not have the personal bundle identifier.')
        if expected_version is not None and info.get('CFBundleShortVersionString') != expected_version:
            raise ValueError('Compiled app version differs from the current source; refusing a stale artifact.')
        if expected_build is not None and info.get('CFBundleVersion') != str(expected_build):
            raise ValueError('Compiled build number differs from this run; refusing a stale artifact.')
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
    result = validate(source, expected_version=version, expected_build=os.environ.get('GITHUB_RUN_NUMBER', '1'))
    output = ROOT / 'build' / 'nikita'
    output.mkdir(parents=True, exist_ok=True)
    target = output / 'Nikita.ipa'
    shutil.copyfile(source, target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (output / 'Nikita.ipa.sha256').write_text(digest + '  Nikita.ipa\n')
    result.update({
        'sha256': digest,
        'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'compiled': True, 'runtime_tested': False,
        'signing': 'Sign with the owner certificate before installation',
    })
    (output / 'Build.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('Validated compiled Nikita IPA:', target)

if __name__ == '__main__':
    main()

