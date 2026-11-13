#!/usr/bin/env python3
"""Integrity/regression checks using the actual attached ARM64 framework."""
from __future__ import annotations

import os
import struct
import unittest
from pathlib import Path

from patch_async_imports import Image, TARGETS, patch_bytes, decoded_library_ordinal, verify_lief, DYLIB_LOAD_PATH

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(os.environ.get("SG_ASYNC_TEST_CORE", ROOT / "inspect_ipa/TelegramCoreFramework"))


class AsyncImportPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = FIXTURE.read_bytes()
        cls.before = Image(cls.original)
        cls.patched, cls.report = patch_bytes(cls.original)
        cls.after = Image(cls.patched)

    def test_special_ordinals_do_not_sign_extend_ordinary_high_values(self):
        for bits, positive, last, first_special in [(8, 128, 240, 241), (16, 32768, 65520, 65521)]:
            self.assertEqual(decoded_library_ordinal(positive, bits), positive)
            self.assertEqual(decoded_library_ordinal(last, bits), last)
            self.assertEqual(decoded_library_ordinal(first_special, bits), -15)
            self.assertEqual(decoded_library_ordinal((1 << bits) - 1, bits), -1)

    def test_exact_function_and_async_frame_descriptor_rebound(self):
        old, new = self.before.bindings(), self.after.bindings()
        self.assertEqual(old.keys(), new.keys())
        differences = {address for address in old if old[address] != new[address]}
        self.assertEqual(differences, set(TARGETS))
        for address, (_, replacement) in TARGETS.items():
            self.assertEqual(new[address]["name"], replacement)
            self.assertEqual(new[address]["library"], DYLIB_LOAD_PATH)
            self.assertEqual(new[address]["library_ordinal"], 43)
            for key in ("pointer", "pointer_addend", "weak", "addend", "index"):
                self.assertEqual(old[address][key], new[address][key])

    def test_independent_lief_reader_confirms_only_two_bindings_changed(self):
        result = verify_lief(self.original, self.patched)
        self.assertTrue(result["confirmed_exactly_two_changes"])
        self.assertEqual(result["binding_count"], 16164)

    def test_all_original_sections_offsets_sizes_and_content_preserved(self):
        self.assertEqual(len(self.original), len(self.patched))
        self.assertEqual(self.before.segments, self.after.segments)
        for cmd, _, raw in self.before.commands:
            if cmd != 0x19:
                continue
            nsects = struct.unpack_from("<I", raw, 64)[0]
            for i in range(nsects):
                section = raw[72 + i * 80:72 + (i + 1) * 80]
                size = struct.unpack_from("<Q", section, 40)[0]
                offset = struct.unpack_from("<I", section, 48)[0]
                flags = struct.unpack_from("<I", section, 64)[0]
                if offset and size and (flags & 0xFF) not in (1, 0xC, 0x12):
                    self.assertEqual(self.original[offset:offset + size], self.patched[offset:offset + size], section[:16])
        self.assertEqual(self.before.dependencies, self.after.dependencies[:-1])
        self.assertEqual(self.after.dependencies[-1], DYLIB_LOAD_PATH)
        self.assertEqual(len(self.after.imports), len(self.before.imports))

    def test_repeated_application_does_not_append_or_change_anything(self):
        second, report = patch_bytes(self.patched)
        self.assertEqual(second, self.patched)
        self.assertTrue(report["already_patched"])

    def test_shared_suffix_symbol_is_rejected(self):
        corrupted = bytearray(self.original)
        target = next(i for i in self.before.imports if i["name"] == TARGETS[0xDC4990][0])
        other = self.before.imports[0]
        self.assertEqual(self.before.import_format, 1)
        name_relative = target["name_start"] + 5 - self.before.symbols_offset
        word = (other["word"] & 0x1FF) | (name_relative << 9)
        struct.pack_into("<I", corrupted, other["offset"], word)
        with self.assertRaisesRegex(ValueError, "shared/overlaps"):
            patch_bytes(bytes(corrupted))

    def test_wrong_slot_is_rejected_instead_of_rebinding_unrelated_import(self):
        corrupted = bytearray(self.original)
        offset = self.before.file_offset(0xDC4990)
        pointer = struct.unpack_from("<Q", corrupted, offset)[0]
        struct.pack_into("<Q", corrupted, offset, pointer & ~0xFFFFFF)
        with self.assertRaisesRegex(ValueError, "Unexpected import"):
            patch_bytes(bytes(corrupted))

    def test_occupied_header_padding_is_rejected(self):
        corrupted = bytearray(self.original)
        corrupted[32 + self.before.header[5]] = 0xA5
        with self.assertRaisesRegex(ValueError, "header padding"):
            patch_bytes(bytes(corrupted))

    def test_unknown_import_format_is_rejected(self):
        corrupted = bytearray(self.original)
        struct.pack_into("<I", corrupted, self.before.fixups_offset + 20, 9)
        with self.assertRaisesRegex(ValueError, "import format"):
            patch_bytes(bytes(corrupted))


if __name__ == "__main__":
    unittest.main(verbosity=2)
