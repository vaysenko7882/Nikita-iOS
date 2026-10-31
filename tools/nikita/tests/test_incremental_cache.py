import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/(name+".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class IncrementalCacheTests(unittest.TestCase):
    def test_app_version_does_not_cold_start_the_toolchain_cache(self):
        cache = load("cache_settings")
        original = dict(app="13.1.3", xcode="27.1", bazel="9.2.0:hash", macos="27")
        changed = {**original, "app": "13.1.4"}
        self.assertEqual(cache.identity(original, "Xcode 27A9275", "arm64"),
            cache.identity(changed, "Xcode 27A9275", "arm64"))
        self.assertNotEqual(cache.identity(original, "Xcode 27A9275", "arm64"),
            cache.identity(original, "Different SDK", "arm64"))

    def test_run_number_changes_only_bundle_metadata(self):
        stamp = load("stamp_build_version").stamp
        fixture = '''unchanged_rule(name = "CompileCore")
plist_fragment(
    name = "BuildNumberInfoPlist",
    template = """<key>CFBundleVersion</key><string>{buildNumber}</string>""",
    defaults = {"buildNumber": "1"},
)
unchanged_rule(name = "CompileUI")
'''
        first = stamp(fixture, 9)
        self.assertEqual(stamp(first, 10), first.replace("<string>9</string>", "<string>10</string>"))
        self.assertIn('defaults = {"buildNumber": "1"}', first)
        with self.assertRaises(ValueError):
            stamp(fixture, '1"; bad')


if __name__ == "__main__":
    unittest.main()
