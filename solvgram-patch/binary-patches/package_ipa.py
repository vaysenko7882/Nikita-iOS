#!/usr/bin/env python3
"""Byte-preserving, unsigned IPA packaging for a thin ARM64 injected dylib.

Original input is never extracted or changed. Load-command changes stay inside
verified zero header padding; existing sections, fixups and link-edit offsets do
not move. Old signature blobs remain inert after their commands are removed.
The installation signer is responsible for adding new signatures/profiles.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import plistlib
import stat
import struct
import zipfile
from pathlib import Path, PurePosixPath

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_DYLIB = 6
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
DYLIB_NAME = "SolvgramGiftControls.dylib"
DYLIB_LOAD_PATH = "@executable_path/Frameworks/" + DYLIB_NAME


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_macho(data: bytes) -> bool:
    return len(data) >= 4 and struct.unpack_from("<I", data)[0] == MH_MAGIC_64


def commands(data: bytes):
    if len(data) < 32 or not is_macho(data):
        raise ValueError("Expected a thin little-endian 64-bit Mach-O")
    header = struct.unpack_from("<8I", data)
    count, size = header[4:6]
    end = 32 + size
    if end > len(data):
        raise ValueError("Mach-O commands extend past file")
    result = []
    pos = 32
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError("Truncated Mach-O command")
        cmd, cmd_size = struct.unpack_from("<II", data, pos)
        if cmd_size < 8 or cmd_size % 8 or pos + cmd_size > end:
            raise ValueError("Invalid Mach-O command size")
        result.append((cmd, pos, data[pos : pos + cmd_size]))
        pos += cmd_size
    if pos != end:
        raise ValueError("Mach-O command count/size mismatch")
    return header, result


def first_section_offset(data: bytes) -> int:
    _, cmds = commands(data)
    offsets = []
    for cmd, _, raw in cmds:
        if cmd != LC_SEGMENT_64:
            continue
        if len(raw) < 72:
            raise ValueError("Truncated segment")
        nsects = struct.unpack_from("<I", raw, 64)[0]
        if len(raw) != 72 + 80 * nsects:
            raise ValueError("Malformed segment sections")
        for i in range(nsects):
            off = struct.unpack_from("<I", raw, 72 + 80 * i + 48)[0]
            size = struct.unpack_from("<Q", raw, 72 + 80 * i + 40)[0]
            flags = struct.unpack_from("<I", raw, 72 + 80 * i + 64)[0]
            # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL have no bytes.
            if off and size and flags & 0xFF not in (1, 0xC, 0x12):
                if off + size > len(data):
                    raise ValueError("Section extends past file")
                offsets.append(off)
    if not offsets:
        raise ValueError("No file-backed Mach-O section")
    return min(offsets)


def dylib_path(raw: bytes) -> str:
    off = struct.unpack_from("<I", raw, 8)[0]
    if not 24 <= off < len(raw):
        raise ValueError("Malformed dylib load command")
    end = raw.find(b"\0", off)
    if end < 0:
        raise ValueError("Unterminated dylib path")
    return raw[off:end].decode("utf-8")


def rewrite_commands(data: bytes, inject: bool = False) -> tuple[bytes, dict]:
    header, cmds = commands(data)
    old_end = 32 + header[5]
    kept = []
    removed = []
    already_loaded = False
    for cmd, pos, raw in cmds:
        if cmd == LC_CODE_SIGNATURE:
            if len(raw) != 16:
                raise ValueError("Malformed signature command")
            offset, size = struct.unpack_from("<II", raw, 8)
            if offset + size > len(data):
                raise ValueError("Code signature extends past file")
            removed.append({"offset": offset, "size": size})
        else:
            if cmd == LC_LOAD_DYLIB and dylib_path(raw) == DYLIB_LOAD_PATH:
                already_loaded = True
            kept.append(raw)
    if inject and not already_loaded:
        name = DYLIB_LOAD_PATH.encode("utf-8") + b"\0"
        size = (24 + len(name) + 7) & ~7
        raw = struct.pack("<6I", LC_LOAD_DYLIB, size, 24, 0, 0x10000, 0x10000)
        kept.append(raw + name + b"\0" * (size - 24 - len(name)))
    new_commands = b"".join(kept)
    new_end = 32 + len(new_commands)
    if new_end > first_section_offset(data):
        raise ValueError("Insufficient header padding; refusing to move sections")
    if new_end > old_end and any(data[old_end:new_end]):
        raise ValueError("Header padding contains data; refusing to overwrite")
    out = bytearray(data)
    struct.pack_into("<II", out, 16, len(kept), len(new_commands))
    out[32:new_end] = new_commands
    if new_end < old_end:
        out[new_end:old_end] = b"\0" * (old_end - new_end)
    # Crucial invariant: no payload sections, dyld fixups or Swift relative
    # references have changed as a side effect of repackaging.
    boundary = max(old_end, new_end)
    if out[boundary:] != data[boundary:]:
        raise AssertionError("Unexpected change outside the load-command area")
    result = bytes(out)
    commands(result)
    return result, {"removed_signature_commands": removed,
                    "injected_load_path": DYLIB_LOAD_PATH if inject else None,
                    "old_commands_end": old_end, "new_commands_end": new_end,
                    "size_bytes": len(result)}


def deployment(data: bytes) -> tuple[int | None, int | None]:
    _, cmds = commands(data)
    for cmd, _, raw in cmds:
        if cmd == LC_BUILD_VERSION:
            return struct.unpack_from("<II", raw, 8)
        if cmd == LC_VERSION_MIN_IPHONEOS:
            return 2, struct.unpack_from("<I", raw, 8)[0]
    return None, None


def version_number(value: str) -> int:
    parts = [int(p) for p in value.split(".")]
    return (parts[0] << 16) | ((parts[1] if len(parts) > 1 else 0) << 8) | (parts[2] if len(parts) > 2 else 0)


def safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts and "\\" not in name


def signature_resource(name: str) -> bool:
    parts = PurePosixPath(name).parts
    return "_CodeSignature" in parts or (parts and parts[-1] == "embedded.mobileprovision")


def locate_app(archive: zipfile.ZipFile) -> tuple[str, dict, str]:
    names = archive.namelist()
    candidates = [n for n in names if n.startswith("Payload/")
                  and len(PurePosixPath(n).parts) == 3
                  and n.endswith(".app/Info.plist")]
    if len(candidates) != 1:
        raise ValueError("Expected exactly one top-level app Info.plist")
    info_name = candidates[0]
    info = plistlib.loads(archive.read(info_name))
    app = str(PurePosixPath(info_name).parent)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or PurePosixPath(executable).name != executable:
        raise ValueError("Invalid app executable name")
    main = app + "/" + executable
    if main not in names:
        raise ValueError("App executable is missing")
    return app, info, main


def verify_ipa(path: Path) -> dict:
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if len(names) != len(set(names)) or not all(safe_name(n) for n in names):
            raise ValueError("Duplicate or unsafe archive member")
        if z.testzip() is not None:
            raise ValueError("Archive CRC failure")
        app, info, main = locate_app(z)
        dependency = app + "/Frameworks/" + DYLIB_NAME
        if dependency not in names:
            raise ValueError("Injected dependency is missing")
        if any(signature_resource(n) for n in names):
            raise ValueError("Old code signature/provisioning resources remain")
        main_bytes = z.read(main)
        main_header, main_cmds = commands(main_bytes)
        if main_header[1] != CPU_TYPE_ARM64 or main_header[3] != MH_EXECUTE:
            raise ValueError("Main executable is not ARM64 MH_EXECUTE")
        loads = [dylib_path(raw) for cmd, _, raw in main_cmds if cmd == LC_LOAD_DYLIB]
        if loads.count(DYLIB_LOAD_PATH) != 1:
            raise ValueError("Injected load command must occur exactly once")
        library = z.read(dependency)
        library_header, _ = commands(library)
        if library_header[1] != CPU_TYPE_ARM64 or library_header[3] != MH_DYLIB:
            raise ValueError("Injected library is not ARM64 MH_DYLIB")
        platform, minimum = deployment(library)
        if platform != 2:
            raise ValueError("Injected library must target iOS devices")
        if minimum is None or minimum > version_number(info["MinimumOSVersion"]):
            raise ValueError("Injected library raises the app deployment target")
        macho_count = 0
        for entry in z.infolist():
            if entry.is_dir():
                continue
            with z.open(entry) as f:
                magic = f.read(4)
            if len(magic) == 4 and struct.unpack("<I", magic)[0] == MH_MAGIC_64:
                data = z.read(entry)
                _, cmds = commands(data)
                if any(cmd == LC_CODE_SIGNATURE for cmd, _, _ in cmds):
                    raise ValueError("Old signature command remains in " + entry.filename)
                if not (entry.external_attr >> 16) & stat.S_IXUSR:
                    raise ValueError("Mach-O lost executable mode: " + entry.filename)
                macho_count += 1
        return {"app": app, "bundle_id": info.get("CFBundleIdentifier"),
                "version": info.get("CFBundleShortVersionString"),
                "build": info.get("CFBundleVersion"), "mach_o_files": macho_count,
                "members": len(names), "library_platform": platform,
                "library_minimum_os": minimum, "unsigned": True,
                "structural_validation_only": True}


def build_ipa(input_path: Path, dylib: Path, output: Path, replacements: dict[str, Path]) -> dict:
    if input_path.resolve() == output.resolve():
        raise ValueError("Output must differ from original IPA")
    if output.exists():
        raise ValueError("Output already exists; choose a new path")
    library = dylib.read_bytes()
    lib_header, _ = commands(library)
    if lib_header[1] != CPU_TYPE_ARM64 or lib_header[3] != MH_DYLIB:
        raise ValueError("Expected a thin ARM64 dylib")
    library, library_change = rewrite_commands(library)
    source_hash = sha256(input_path.read_bytes())
    report = {"input": str(input_path.resolve()), "input_sha256": source_hash,
              "output": str(output.resolve()), "replaced": [], "rewritten_mach_o": [],
              "removed_resources": [], "injected_library": library_change}
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(input_path) as source, zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as dest:
            dest.comment = source.comment
            names = source.namelist()
            if len(names) != len(set(names)) or not all(safe_name(n) for n in names):
                raise ValueError("Duplicate or unsafe archive member")
            if not set(replacements).issubset(names):
                raise ValueError("Replacement target must already exist in the IPA")
            app, info, main = locate_app(source)
            library_member = app + "/Frameworks/" + DYLIB_NAME
            if library_member in names:
                raise ValueError("Injected library already exists")
            for entry in source.infolist():
                name = entry.filename
                if signature_resource(name):
                    report["removed_resources"].append(name)
                    continue
                data = source.read(entry)
                if name in replacements:
                    updated = replacements[name].read_bytes()
                    if not is_macho(data) or not is_macho(updated):
                        raise ValueError("Only Mach-O replacements are allowed")
                    before_header, _ = commands(data)
                    after_header, _ = commands(updated)
                    if before_header[1:4] != after_header[1:4]:
                        raise ValueError("Replacement architecture/type mismatch")
                    report["replaced"].append({"member": name, "original_sha256": sha256(data), "patched_sha256": sha256(updated)})
                    data = updated
                if is_macho(data):
                    before = data
                    data, change = rewrite_commands(data, inject=name == main)
                    report["rewritten_mach_o"].append({"member": name, "before_sha256": sha256(before), "after_sha256": sha256(data), **change})
                metadata = copy.copy(entry)
                # ZipFile recomputes CRC, size and compression metadata. The
                # original UNIX mode/symlink type and timestamps are retained.
                dest.writestr(metadata, data)
            new_entry = zipfile.ZipInfo(library_member, source.getinfo(main).date_time)
            new_entry.create_system = 3
            new_entry.external_attr = (stat.S_IFREG | 0o755) << 16
            new_entry.compress_type = zipfile.ZIP_DEFLATED
            dest.writestr(new_entry, library)
        report["verification"] = verify_ipa(output)
        if sha256(input_path.read_bytes()) != source_hash:
            raise AssertionError("Original IPA changed")
        report["output_sha256"] = sha256(output.read_bytes())
        return report
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--dylib", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--replace", action="append", default=[], metavar="ARCHIVE_MEMBER=LOCAL_FILE")
    parser.add_argument("--verify", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.verify:
        if any((args.input, args.dylib, args.output, args.replace)):
            parser.error("--verify is exclusive with packaging arguments")
        result = verify_ipa(args.verify)
    else:
        if not all((args.input, args.dylib, args.output)):
            parser.error("--input, --dylib and --output are required")
        replacements = {}
        for item in args.replace:
            name, separator, path = item.partition("=")
            if not separator or not safe_name(name) or name in replacements:
                parser.error("Invalid or duplicate --replace")
            replacements[name] = Path(path)
        result = build_ipa(args.input, args.dylib, args.output, replacements)
    serialized = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.report:
        args.report.write_text(serialized)
    print(serialized)


if __name__ == "__main__":
    main()
