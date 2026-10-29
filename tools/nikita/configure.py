#!/usr/bin/env python3
"""Prepare a personal API configuration without logging its credentials."""
import argparse
import configparser
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build-system' / 'nikita-local-configuration.json'

def configuration(environment):
    api_id = environment.get('TG_API_ID', '').strip()
    api_hash = environment.get('TG_API_HASH', '').strip()
    if not api_id.isascii() or not api_id.isdecimal() or not (0 < int(api_id) < 2**31):
        raise ValueError('Add your Telegram application ID as the TG_API_ID repository secret.')
    if not re.fullmatch(r'[0-9a-fA-F]{32}', api_hash):
        raise ValueError('Add your Telegram application hash as the TG_API_HASH repository secret.')
    return {
        'bundle_id': 'personal.nikita.messenger',
        'api_id': api_id, 'api_hash': api_hash,
        # Placeholder for the unsigned artifact; replaced by the on-device signer.
        'team_id': 'NIKITA0001', 'app_center_id': '0',
        'is_internal_build': 'false', 'is_appstore_build': 'false', 'appstore_id': '0',
        'app_specific_url_scheme': 'nikita', 'premium_iap_product_id': '',
        'enable_siri': False, 'enable_icloud': False,
    }

def fetch_submodules():
    modules = configparser.ConfigParser()
    modules.read(ROOT / '.gitmodules')
    for section in modules.sections():
        name = section.removeprefix('submodule "').removesuffix('"')
        url = modules[section]['url'].strip()
        if url.startswith('../'):
            suffix = url[3:]
            if '/' in suffix or not re.fullmatch(r'[A-Za-z0-9_.-]+', suffix):
                raise ValueError('Unsupported relative submodule URL.')
            path = modules[section]['path']
            # Preserve access to author-specific commits, with the official
            # upstream as a fallback when the author's relative repo is absent.
            environment = {**os.environ, 'GIT_TERMINAL_PROMPT': '0'}
            for owner in ('yar2slav', 'TelegramMessenger'):
                resolved = f'https://github.com/{owner}/{suffix}'
                subprocess.run(['git', 'config', f'submodule.{name}.url', resolved], cwd=ROOT, check=True)
                if (ROOT / path / '.git').exists():
                    subprocess.run(['git', '-C', path, 'remote', 'set-url', 'origin', resolved], cwd=ROOT, check=True)
                result = subprocess.run(['git', 'submodule', 'update', '--init', '--', path], cwd=ROOT, env=environment)
                if result.returncode == 0:
                    break
            else:
                raise ValueError(f'Could not fetch the pinned upstream dependency: {path}')
    subprocess.run(['git', 'submodule', 'update', '--init', '--recursive', '--jobs', '4'], cwd=ROOT, check=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--submodules', action='store_true')
    args = parser.parse_args()
    if args.submodules:
        fetch_submodules()
        return
    value = configuration(os.environ)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(OUTPUT, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, 'w') as f:
        json.dump(value, f, indent=2)
        f.write('\n')
    print('Personal Telegram API configuration prepared; credentials were not printed.')

if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
