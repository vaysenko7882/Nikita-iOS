#!/usr/bin/env python3
"""Rebind this Solvgram build's two Foundation async data(for:) imports.

Only load-command header padding, two chained-import library ordinals and the
two existing import strings are changed. Sections, pointer chains, async frame
descriptor references, link-edit offsets and all other imports stay in place.

Bit layouts follow Apple's dyld/include/mach-o/fixup-chains.h:
https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/fixup-chains.h
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

from package_ipa import commands, dylib_path, first_section_offset, DYLIB_LOAD_PATH

LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
DEPENDENCY_COMMANDS = {0xC, 0x20, 0x80000018, 0x8000001F, 0x80000023}
FOUNDATION_LIBRARY = "/usr/lib/swift/libswiftFoundation.dylib"
NATIVE_FUNCTION = "_$sSo12NSURLSessionC10FoundationE4data3for8delegateAC4DataV_So13NSURLResponseCtAC10URLRequestV_So0A12TaskDelegate_pSgtYaKF"
TARGETS = {
    0xDC4990: (NATIVE_FUNCTION, "_SGSessionData"),
    0xDC4998: (NATIVE_FUNCTION + "Tu", "_SGSessionDataTu"),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decoded_library_ordinal(raw: int, bits: int) -> int:
    """Only the top fifteen encodings are negative special dyld ordinals.

    This intentionally does not sign-extend at bit 7/15: ordinary positive
    library ordinals 128...240 and 32768...65520 are valid in these formats.
    """
    modulus = 1 << bits
    return raw - modulus if raw >= modulus - 15 else raw


class Image:
    def __init__(self, data: bytes):
        self.data = data
        self.header, self.commands = commands(data)
        if self.header[1] != 0x0100000C or self.header[3] != 6:
            raise ValueError("Expected thin ARM64 MH_DYLIB TelegramCore framework")
        self.dependencies = []
        self.segments = []
        fixups = []
        for cmd, pos, raw in self.commands:
            if cmd in DEPENDENCY_COMMANDS:
                self.dependencies.append(dylib_path(raw))
            if cmd == LC_SEGMENT_64:
                name, va, vm_size, file_offset, file_size = struct.unpack_from("<16sQQQQ", raw, 8)
                self.segments.append({"name": name.rstrip(b"\0").decode(), "va": va,
                                      "vm_size": vm_size, "file_offset": file_offset,
                                      "file_size": file_size})
            if cmd == LC_DYLD_CHAINED_FIXUPS:
                if len(raw) != 16:
                    raise ValueError("Malformed chained-fixups command")
                fixups.append(struct.unpack_from("<II", raw, 8))
        if len(fixups) != 1:
            raise ValueError("Expected exactly one chained-fixups command")
        self.fixups_offset, self.fixups_size = fixups[0]
        self.fixups_end = self.fixups_offset + self.fixups_size
        if self.fixups_size < 28 or self.fixups_end > len(data):
            raise ValueError("Chained fixups exceed file")
        (version, starts, imports, symbols, count, import_format,
         symbol_format) = struct.unpack_from("<7I", data, self.fixups_offset)
        if version != 0 or symbol_format != 0:
            raise ValueError("Unsupported chained-fixups version/compressed symbol pool")
        if import_format not in (1, 2, 3):
            raise ValueError("Unsupported chained-import format")
        self.import_format = import_format
        self.import_size = {1: 4, 2: 8, 3: 16}[import_format]
        self.ordinal_bits = 16 if import_format == 3 else 8
        self.starts_offset = self.fixups_offset + starts
        self.imports_offset = self.fixups_offset + imports
        self.symbols_offset = self.fixups_offset + symbols
        if starts >= self.fixups_size or imports >= self.fixups_size or symbols >= self.fixups_size:
            raise ValueError("Chained-fixups table offset out of bounds")
        if self.imports_offset + count * self.import_size > self.symbols_offset:
            raise ValueError("Chained-import table overlaps symbol pool")
        self.imports = []
        for index in range(count):
            offset = self.imports_offset + index * self.import_size
            word_size = 8 if import_format == 3 else 4
            word = int.from_bytes(data[offset:offset + word_size], "little")
            if import_format == 3:
                ordinal_raw = word & 0xFFFF
                weak = (word >> 16) & 1
                name_relative = word >> 32
                addend = struct.unpack_from("<q", data, offset + 8)[0]
            else:
                ordinal_raw = word & 0xFF
                weak = (word >> 8) & 1
                name_relative = word >> 9
                addend = struct.unpack_from("<i", data, offset + 4)[0] if import_format == 2 else 0
            name_start = self.symbols_offset + name_relative
            if not self.symbols_offset <= name_start < self.fixups_end:
                raise ValueError("Import symbol offset out of bounds")
            name_end = data.find(b"\0", name_start, self.fixups_end)
            if name_end < 0:
                raise ValueError("Import symbol is not null-terminated")
            name = data[name_start:name_end].decode("utf-8")
            ordinal = decoded_library_ordinal(ordinal_raw, self.ordinal_bits)
            if ordinal > len(self.dependencies):
                raise ValueError("Import library ordinal exceeds dependency count")
            library = self.dependencies[ordinal - 1] if ordinal > 0 else f"special:{ordinal}"
            self.imports.append({"index": index, "offset": offset, "word_size": word_size,
                                 "word": word, "library_ordinal": ordinal, "library": library,
                                 "weak": weak, "name": name, "name_start": name_start,
                                 "name_end": name_end, "addend": addend})

    def file_offset(self, address: int, size: int = 8) -> int:
        for segment in self.segments:
            relative = address - segment["va"]
            if 0 <= relative and relative + size <= segment["file_size"]:
                return segment["file_offset"] + relative
        raise ValueError(f"Address {address:#x} is not file-backed")

    def bindings(self) -> dict[int, dict]:
        """Walk the existing 64-bit chains, without changing pointer words."""
        data = self.data
        st = self.starts_offset
        segment_count = struct.unpack_from("<I", data, st)[0]
        if segment_count != len(self.segments) or st + 4 + segment_count * 4 > self.fixups_end:
            raise ValueError("Chained segment table does not match Mach-O segments")
        result = {}
        preferred_base = next(s["va"] for s in self.segments if s["file_offset"] == 0 and s["file_size"])
        for segment_index in range(segment_count):
            relative = struct.unpack_from("<I", data, st + 4 + segment_index * 4)[0]
            if not relative:
                continue
            info = st + relative
            if info + 22 > self.fixups_end:
                raise ValueError("Truncated chained segment")
            size, page_size, pointer_format, segment_offset, _, page_count = struct.unpack_from("<IHHQIH", data, info)
            if pointer_format not in (2, 6):
                raise ValueError("This patch supports only native 64/64_OFFSET pointer chains")
            if size < 22 + 2 * page_count or info + size > self.fixups_end or page_size not in (0x1000, 0x4000):
                raise ValueError("Malformed chained segment page starts")
            if preferred_base + segment_offset != self.segments[segment_index]["va"]:
                raise ValueError("Chained segment virtual offset mismatch")
            for page in range(page_count):
                entry = struct.unpack_from("<H", data, info + 22 + 2 * page)[0]
                if entry == 0xFFFF:
                    continue
                starts = []
                if entry & 0x8000:
                    overflow_index = entry & 0x7FFF
                    while True:
                        position = info + 22 + overflow_index * 2
                        if position + 2 > info + size:
                            raise ValueError("Chained overflow start out of bounds")
                        overflow = struct.unpack_from("<H", data, position)[0]
                        starts.append(overflow & 0x7FFF)
                        overflow_index += 1
                        if overflow & 0x8000:
                            break
                else:
                    starts.append(entry)
                for start in starts:
                    if start >= page_size:
                        raise ValueError("Chain start exceeds page")
                    address = preferred_base + segment_offset + page * page_size + start
                    page_end = preferred_base + segment_offset + (page + 1) * page_size
                    seen = set()
                    while True:
                        if address in seen or address + 8 > page_end:
                            raise ValueError("Chained pointer loop/page overrun")
                        seen.add(address)
                        pointer = struct.unpack_from("<Q", data, self.file_offset(address))[0]
                        if pointer >> 63:
                            import_index = pointer & 0xFFFFFF
                            if import_index >= len(self.imports):
                                raise ValueError("Chained bind import index out of bounds")
                            if address in result:
                                raise ValueError("Duplicate chained binding address")
                            result[address] = {**self.imports[import_index], "pointer": pointer,
                                               "pointer_addend": (pointer >> 24) & 0xFF}
                        following = (pointer >> 51) & 0xFFF
                        if following == 0:
                            break
                        address += following * 4
        return result


def add_dependency(data: bytes) -> tuple[bytes, int, tuple[int, int] | None]:
    image = Image(data)
    matches = [i + 1 for i, name in enumerate(image.dependencies) if name == DYLIB_LOAD_PATH]
    if matches:
        if len(matches) != 1:
            raise ValueError("Duplicate injected dependency")
        return data, matches[0], None
    ordinal = len(image.dependencies) + 1
    if ordinal > (1 << image.ordinal_bits) - 16:
        raise ValueError("New dependency ordinal cannot fit chained-import format")
    name = DYLIB_LOAD_PATH.encode() + b"\0"
    command_size = (24 + len(name) + 7) & ~7
    command = struct.pack("<6I", LC_LOAD_DYLIB, command_size, 24, 0, 0x10000, 0x10000)
    command += name + b"\0" * (command_size - 24 - len(name))
    end = 32 + image.header[5]
    if end + command_size > first_section_offset(data) or any(data[end:end + command_size]):
        raise ValueError("Insufficient verified-zero header padding for dependency")
    result = bytearray(data)
    struct.pack_into("<II", result, 16, image.header[4] + 1, image.header[5] + command_size)
    result[end:end + command_size] = command
    return bytes(result), ordinal, (end, end + command_size)


def binding_signature(binding: dict) -> tuple:
    return (binding["name"], binding["library"], binding["library_ordinal"],
            binding["weak"], binding["addend"], binding["pointer"], binding["pointer_addend"])


def patch_bytes(original: bytes) -> tuple[bytes, dict]:
    before = Image(original)
    bindings_before = before.bindings()
    selected = {}
    already_patched = []
    for address, (native, replacement) in TARGETS.items():
        binding = bindings_before.get(address)
        if binding is None:
            raise ValueError(f"Missing expected async bind slot {address:#x}")
        if binding["name"] == replacement and binding["library"] == DYLIB_LOAD_PATH:
            already_patched.append(address)
        elif binding["name"] != native or binding["library"] != FOUNDATION_LIBRARY:
            raise ValueError(f"Unexpected import at {address:#x}: {binding['name']} from {binding['library']}")
        selected[binding["index"]] = (address, replacement, binding)
    if already_patched:
        if len(already_patched) != len(TARGETS):
            raise ValueError("Partially patched async imports; refusing ambiguous input")
        return original, {"already_patched": True, "input_sha256": digest(original),
                          "output_sha256": digest(original), "changed_bindings": []}
    selected_indexes = set(selected)
    for index, (address, replacement, item) in selected.items():
        occurrences = [addr for addr, binding in bindings_before.items() if binding["index"] == index]
        if occurrences != [address]:
            raise ValueError("Target import has additional bindings; patch would affect unrelated slots")
        if len(replacement.encode()) > item["name_end"] - item["name_start"]:
            raise ValueError("Replacement import name does not fit existing string")
        region_start, region_end = item["name_start"], item["name_end"] + 1
        for other in before.imports:
            if other["index"] == index:
                continue
            if max(region_start, other["name_start"]) < min(region_end, other["name_end"] + 1):
                raise ValueError(f"Import string is shared/overlaps another entry ({other['index']}); refusing to overwrite")
    with_dependency, ordinal, header_region = add_dependency(original)
    output = bytearray(with_dependency)
    allowed_regions = [(16, 24)] if header_region else []
    if header_region:
        allowed_regions.append(header_region)
    modifications = []
    mask = (1 << before.ordinal_bits) - 1
    for index, (address, replacement, item) in selected.items():
        word = (item["word"] & ~mask) | ordinal
        start, end = item["offset"], item["offset"] + item["word_size"]
        output[start:end] = word.to_bytes(item["word_size"], "little")
        string_start, string_end = item["name_start"], item["name_end"] + 1
        new_name = replacement.encode() + b"\0"
        output[string_start:string_end] = new_name + b"\0" * (string_end - string_start - len(new_name))
        allowed_regions.extend([(start, end), (string_start, string_end)])
        modifications.append({"slot_va": hex(address), "import_index": index,
                              "original_symbol": item["name"], "replacement_symbol": replacement,
                              "old_library_ordinal": item["library_ordinal"],
                              "new_library_ordinal": ordinal,
                              "import_word_file_offset": hex(start),
                              "symbol_file_range": [hex(string_start), hex(string_end)]})
    output = bytes(output)
    after = Image(output)
    bindings_after = after.bindings()
    if bindings_before.keys() != bindings_after.keys():
        raise AssertionError("Chained binding addresses changed")
    changed_bindings = []
    for address, old in bindings_before.items():
        new = bindings_after[address]
        if binding_signature(old) != binding_signature(new):
            if address not in TARGETS or new["name"] != TARGETS[address][1] or new["library"] != DYLIB_LOAD_PATH:
                raise AssertionError(f"Unexpected changed binding at {address:#x}")
            if old["pointer"] != new["pointer"] or old["weak"] != new["weak"] or old["addend"] != new["addend"]:
                raise AssertionError("Pointer chain/weakness/addend changed")
            changed_bindings.append(hex(address))
    if set(changed_bindings) != {hex(a) for a in TARGETS}:
        raise AssertionError("Expected exactly two modified async bindings")
    if len(output) != len(original):
        raise AssertionError("Mach-O file size changed")
    # This is deliberately checked bytewise, rather than trusting a parser's
    # reserialization: no data, instruction or chain word can silently move.
    cursor = 0
    for start, end in sorted(allowed_regions):
        if start > cursor and original[cursor:start] != output[cursor:start]:
            raise AssertionError(f"Unexpected bytes changed before {start:#x}")
        cursor = max(cursor, end)
    if original[cursor:] != output[cursor:]:
        raise AssertionError("Unexpected trailing bytes changed")
    before_target_indexes = selected_indexes
    for old, new in zip(before.imports, after.imports):
        if old["index"] not in before_target_indexes and old != new:
            raise AssertionError("Unrelated import entry changed")
    return output, {"already_patched": False, "input_sha256": digest(original),
                    "output_sha256": digest(output), "dependency": DYLIB_LOAD_PATH,
                    "new_library_ordinal": ordinal, "imports_format": before.import_format,
                    "imports_count": len(before.imports), "binding_count": len(bindings_before),
                    "changed_bindings": sorted(changed_bindings), "modifications": modifications,
                    "allowed_file_ranges": [[hex(a), hex(b)] for a, b in sorted(allowed_regions)],
                    "size_bytes": len(output), "all_other_bytes_preserved": True}


def verify_lief(before_data: bytes, after_data: bytes) -> dict:
    import lief
    old_image = lief.MachO.parse(list(before_data)).at(0)
    new_image = lief.MachO.parse(list(after_data)).at(0)
    def inventory(image):
        return {binding.address: (binding.symbol.name if binding.has_symbol else None,
                                  binding.library.name if binding.has_library else f"special:{binding.library_ordinal}",
                                  binding.library_ordinal, binding.addend, binding.weak_import)
                for binding in image.bindings}
    old, new = inventory(old_image), inventory(new_image)
    if old.keys() != new.keys():
        raise AssertionError("LIEF reports changed binding addresses")
    differences = {address: (old[address], new[address]) for address in old if old[address] != new[address]}
    if set(differences) != set(TARGETS):
        raise AssertionError("LIEF did not confirm exactly two changed bindings")
    for address, (_, entry) in differences.items():
        if entry[0] != TARGETS[address][1] or entry[1] != DYLIB_LOAD_PATH:
            raise AssertionError("LIEF reports an incorrect replacement symbol/library")
    return {"binding_count": len(old), "changed_bindings": {hex(k): v for k, v in differences.items()},
            "confirmed_exactly_two_changes": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--verify-lief", action="store_true")
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve() or args.output.exists():
        parser.error("Output must be a new file distinct from the input")
    original = args.input.read_bytes()
    patched, report = patch_bytes(original)
    if args.verify_lief and not report["already_patched"]:
        report["independent_lief_verification"] = verify_lief(original, patched)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(patched)
    if digest(args.input.read_bytes()) != digest(original):
        raise AssertionError("Original input changed")
    serialized = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.write_text(serialized)
    print(serialized)


if __name__ == "__main__":
    main()
