"""Release integrity checks exercise accepted bundles and targeted corruptions."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_release_bundle as release


def macho(*, platform=2, cryptid=0, kind=2):
    commands = struct.pack("<6I", 0x32, 24, platform, 0x000F0000, 0x001B0000, 0)
    commands += struct.pack("<6I", 0x2C, 24, 0, 0, cryptid, 0)
    return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, kind, 2, len(commands), 0, 0) + commands


def png(size):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = (b"\x00" + bytes(size * 3)) * size
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


class ReleaseBundleCheck(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source"
        self.output = Path(self.temporary.name) / "artifact"
        self.output.mkdir()
        manifest = self.root / "tools/nikita/assets/icons/manifest.json"
        manifest.parent.mkdir(parents=True)
        self.icons = ["CGClip", "CGPaper", "CGEcho", "CGRift", "CGSlice", "CGPixel", "CGChrome", "CGStairs"]
        manifest.write_text(json.dumps([dict(name=name) for name in self.icons]))
        (self.root / "versions.json").write_text(json.dumps(dict(app="14.5.0")))
        self.sha = "a" * 40
        self.build = "73"
        self.bundle = "Payload/CodeGram.app/"
        self.info = dict(CFBundleDisplayName="CodeGram", CFBundleIdentifier=release.BUNDLE_ID, CFBundleExecutable="CodeGram", CFBundlePackageType="APPL", CFBundleShortVersionString="14.5.0", CFBundleVersion=self.build, MinimumOSVersion="15.0", CFBundleSupportedPlatforms=["iPhoneOS"])
        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
            self.info[key] = dict(CFBundleAlternateIcons={name: dict(CFBundleIconFiles=[name] if key == "CFBundleIcons" else [name + "Ipad", name + "LargeIpad"]) for name in self.icons})
        self.entries = {self.bundle + "Info.plist": plistlib.dumps(self.info), self.bundle + "CodeGram": macho()}
        for name in release.FRAMEWORK_IDS:
            prefix = self.bundle + "Frameworks/" + name + ".framework/"
            info = dict(CFBundleIdentifier=release.BUNDLE_ID + "." + name, CFBundleExecutable=name, CFBundlePackageType="FMWK", CFBundleShortVersionString="14.5.0", CFBundleVersion=self.build, CFBundleSupportedPlatforms=["iPhoneOS"])
            self.entries[prefix + "Info.plist"] = plistlib.dumps(info)
            self.entries[prefix + name] = macho(kind=6)
        for name in self.icons:
            for suffix, size in (("@2x", 120), ("@3x", 180), ("Preview", 256)):
                self.entries[self.bundle + name + suffix + ".png"] = png(size)
        self.metadata = dict(name="CodeGram", bundle_id=release.BUNDLE_ID, minimum_os="15.0", version="14.5.0", build_number=self.build, alternate_icons=self.icons, source_commit=self.sha, compiled=True, runtime_tested=False)

    def write_bundle(self):
        ipa = self.output / "CodeGram.ipa"
        with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in self.entries.items():
                archive.writestr(name, data)
        digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.metadata["sha256"] = digest
        (self.output / "CodeGram.ipa.sha256").write_text(digest + "  CodeGram.ipa\n")
        metadata = self.output / "Build.json"
        metadata.write_text(json.dumps(self.metadata))
        (self.output / "Build.json.sha256").write_text(hashlib.sha256(metadata.read_bytes()).hexdigest() + "  Build.json\n")

    def verify(self):
        return release.verify(self.output, expected_sha=self.sha, expected_build=self.build, expected_version="14.5.0", root=self.root)

    def test_accepts_six_device_binaries_and_twenty_four_icons(self):
        self.write_bundle()
        report = self.verify()
        self.assertEqual(len(report["compiled_binaries"]), 6)
        self.assertEqual(len(report["verified_images"]), 24)
        self.assertFalse(report["runtime_tested"])

    def test_rejects_stale_source_metadata(self):
        self.metadata["source_commit"] = "b" * 40
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "source SHA"):
            self.verify()

    def test_rejects_changed_metadata_after_checksumming(self):
        self.write_bundle()
        with (self.output / "Build.json").open("a") as target:
            target.write(" ")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.verify()

    def test_rejects_simulator_framework(self):
        name = self.bundle + "Frameworks/TelegramUI.framework/TelegramUI"
        self.entries[name] = macho(platform=7, kind=6)
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "iPhoneOS device platform"):
            self.verify()

    def test_rejects_encrypted_framework(self):
        name = self.bundle + "Frameworks/TelegramCore.framework/TelegramCore"
        self.entries[name] = macho(cryptid=1, kind=6)
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "Encrypted binary"):
            self.verify()

    def test_rejects_missing_framework(self):
        name = self.bundle + "Frameworks/Postbox.framework/Info.plist"
        del self.entries[name]
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "all five"):
            self.verify()

    def test_rejects_wrong_icon_file_registry(self):
        self.info["CFBundleIcons~ipad"]["CFBundleAlternateIcons"]["CGPixel"]["CFBundleIconFiles"] = ["wrong"]
        self.entries[self.bundle + "Info.plist"] = plistlib.dumps(self.info)
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "file registry"):
            self.verify()

    def test_rejects_corrupt_png_chunk_after_zip_checksum_passes(self):
        name = self.bundle + "CGPixelPreview.png"
        data = bytearray(self.entries[name])
        data[-1] ^= 1
        self.entries[name] = bytes(data)
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "PNG chunk CRC"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
