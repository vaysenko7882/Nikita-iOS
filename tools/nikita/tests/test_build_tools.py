import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

TOOLS = Path(__file__).resolve().parents[1]
ROOT = TOOLS.parents[1]
SCRATCH = ROOT / 'build' / 'nikita-tests'
SCRATCH.mkdir(parents=True, exist_ok=True)

def load(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

configure = load('configure')
validator = load('validate_ipa')

class ConfigurationTests(unittest.TestCase):
    def test_relative_submodules_keep_the_original_fork_owner(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
            root = Path(folder)
            (root / '.gitmodules').write_text('[submodule "calls"]\npath = calls\nurl = ../tgcalls.git\n')
            with patch.object(configure, 'ROOT', root), patch.object(configure.subprocess, 'run') as run:
                run.return_value.returncode = 0
                configure.fetch_submodules()
            self.assertEqual(run.call_args_list[0].args[0], ['git', 'config', 'submodule.calls.url', 'https://github.com/yar2slav/tgcalls.git'])

    def test_missing_personal_keys_fail_without_fallback(self):
        with self.assertRaises(ValueError):
            configure.configuration({})

    def test_rejects_api_hash_that_would_inject_build_configuration(self):
        with self.assertRaises(ValueError):
            configure.configuration({'TG_API_ID': '123456', 'TG_API_HASH': 'a' * 32 + '\nprint("bad")'})

    def test_temporary_credentials_are_private_and_not_logged(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
            output = Path(folder) / 'configuration.json'
            capture = io.StringIO()
            test_hash = 'b' * 32
            with patch.object(configure, 'OUTPUT', output), patch.dict(os.environ, {'TG_API_ID': '123456', 'TG_API_HASH': test_hash}), patch('sys.argv', ['configure.py']), contextlib.redirect_stdout(capture):
                configure.main()
            value = json.loads(output.read_text())
            self.assertEqual(value['api_hash'], test_hash)
            self.assertEqual(value['bundle_id'], 'personal.nikita.messenger')
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(test_hash, capture.getvalue())

class ArtifactTests(unittest.TestCase):
    def artifact(self, folder, *, platform=2, name='Никита', cryptid=0, version='13.1.4', build_number='11'):
        # Tiny format fixtures only, never a runnable application or deliverable.
        info = {'CFBundleDisplayName': name, 'CFBundleIdentifier': 'personal.nikita.messenger', 'CFBundleExecutable': 'Client', 'MinimumOSVersion': '15.0'}
        info.update(CFBundleShortVersionString=version, CFBundleVersion=build_number)
        header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 2, 48, 0x200085, 0)
        build = struct.pack('<6I', 0x32, 24, platform, 15 << 16, 27 << 16, 0)
        encryption = struct.pack('<6I', 0x2c, 24, 0, 0, cryptid, 0)
        target = Path(folder) / 'fixture.zip'
        with zipfile.ZipFile(target, 'w') as z:
            z.writestr('Payload/Client.app/Info.plist', plistlib.dumps(info))
            z.writestr('Payload/Client.app/Client', header + build + encryption)
        return target

    def test_rejects_simulator_arm64_even_though_cpu_matches(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
            with self.assertRaisesRegex(ValueError, 'Simulator'):
                validator.validate(self.artifact(folder, platform=7))

    def test_rejects_a_different_clients_binary(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
            with self.assertRaisesRegex(ValueError, 'display name'):
                validator.validate(self.artifact(folder, name='MadGram'))

    def test_rejects_encrypted_code_that_cannot_be_resigned(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
            with self.assertRaisesRegex(ValueError, 'Encrypted'):
                validator.validate(self.artifact(folder, cryptid=1))

    def test_rejects_stale_cached_app_version_or_build_number(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as folder:
            path=self.artifact(folder)
            with self.assertRaisesRegex(ValueError,'version'):
                validator.validate(path,expected_version='13.1.5',expected_build='11')
            with self.assertRaisesRegex(ValueError,'build number'):
                validator.validate(path,expected_version='13.1.4',expected_build='12')
            result=validator.validate(path,expected_version='13.1.4',expected_build='11')
            self.assertEqual((result['version'],result['build_number']),('13.1.4','11'))

if __name__ == '__main__':
    unittest.main()

