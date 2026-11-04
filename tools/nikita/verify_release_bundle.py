#!/usr/bin/env python3
"""Verify the exact downloaded release bundle without Xcode or signing keys."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import zipfile
import zlib

from validate_ipa import validate

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK_IDS = ("MtProtoKit", "SwiftSignalKit", "Postbox", "TelegramCore", "TelegramUI")
BUNDLE_ID = "personal.nikita.messenger"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_sidecar(path):
    sidecar = path.with_name(path.name + ".sha256")
    record = sidecar.read_text(encoding="ascii")
    match = re.fullmatch(r"([0-9a-f]{64})  " + re.escape(path.name) + r"\n", record)
    require(match is not None, "Invalid checksum sidecar: " + sidecar.name)
    actual = sha256_file(path)
    require(match.group(1) == actual, "Checksum mismatch: " + path.name)
    return actual


def executable_name(info, location):
    name = info.get("CFBundleExecutable")
    require(isinstance(name, str) and name not in ("", ".", "..") and "/" not in name and "\\" not in name, "Invalid executable name: " + location)
    return name


def verify_macho(archive, filename, expected_type):
    with archive.open(filename) as source:
        header = source.read(32)
        require(len(header) == 32, "Truncated Mach-O header: " + filename)
        magic, cpu, subtype, file_type, count, size, flags, reserved = struct.unpack("<8I", header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C, "Expected thin arm64 Mach-O: " + filename)
        require(file_type == expected_type, "Unexpected Mach-O file type: " + filename)
        require(0 < count <= 10000 and 0 < size <= 32 * 1024 * 1024, "Invalid Mach-O load-command bounds: " + filename)
        commands = source.read(size)
        require(len(commands) == size, "Truncated Mach-O load commands: " + filename)
        offset, platform, cryptids = 0, None, []
        for _ in range(count):
            require(offset + 8 <= size, "Missing Mach-O load command: " + filename)
            command, length = struct.unpack_from("<II", commands, offset)
            require(length >= 8 and length % 4 == 0 and offset + length <= size, "Invalid Mach-O load command: " + filename)
            if command == 0x32:  # LC_BUILD_VERSION
                require(length >= 24 and platform is None, "Invalid or repeated platform command: " + filename)
                platform = struct.unpack_from("<I", commands, offset + 8)[0]
            elif command in (0x21, 0x2C):  # LC_ENCRYPTION_INFO[_64]
                require(length >= (24 if command == 0x2C else 20), "Truncated encryption command: " + filename)
                cryptids.append(struct.unpack_from("<I", commands, offset + 16)[0])
            offset += length
        require(offset == size, "Mach-O command count/size mismatch: " + filename)
        require(platform == 2, "Expected iPhoneOS device platform, not Simulator: " + filename)
        require(all(value == 0 for value in cryptids), "Encrypted binary cannot be re-signed: " + filename)
    digest = hashlib.sha256()
    with archive.open(filename) as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return dict(path=filename, sha256=digest.hexdigest(), architecture="arm64", platform="iPhoneOS", encrypted=False, encryption_commands=len(cryptids))


def verify_png(data, size, filename):
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Invalid PNG signature: " + filename)
    offset, header, compressed, ended, palette = 8, None, [], False, False
    while offset < len(data):
        require(offset + 12 <= len(data), "Truncated PNG chunk: " + filename)
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data), "Invalid PNG chunk length: " + filename)
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        require(zlib.crc32(kind + payload) & 0xFFFFFFFF == crc, "PNG chunk CRC mismatch: " + filename)
        if header is None:
            require(kind == b"IHDR" and length == 13, "Missing PNG image header: " + filename)
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IHDR":
            raise ValueError("Repeated PNG header: " + filename)
        if kind == b"PLTE":
            palette = True
        elif kind == b"IDAT":
            compressed.append(payload)
        elif kind == b"IEND":
            require(length == 0 and end == len(data), "Invalid PNG end chunk: " + filename)
            ended = True
            break
        offset = end
    require(header is not None and ended and compressed, "Incomplete PNG: " + filename)
    width, height, depth, color, compression, filtering, interlace = header
    require((width, height) == (size, size), "Unexpected icon dimensions: " + filename)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    allowed_depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
    require(color in channels and depth in allowed_depths[color] and compression == 0 and filtering == 0 and interlace == 0, "Unsupported icon PNG encoding: " + filename)
    require(color != 3 or palette, "Indexed icon lacks a palette: " + filename)
    row_bytes = (width * channels[color] * depth + 7) // 8
    expected = height * (row_bytes + 1)
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(b"".join(compressed), expected + 1)
    require(len(pixels) == expected and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail, "Invalid PNG pixel stream: " + filename)
    require(all(pixels[row * (row_bytes + 1)] <= 4 for row in range(height)), "Invalid PNG row filter: " + filename)
    return dict(path=filename, size=[width, height], sha256=hashlib.sha256(data).hexdigest())


def verify(directory, *, expected_sha, expected_build, expected_version="14.5.0", root=ROOT):
    directory, root = Path(directory), Path(root)
    require(re.fullmatch(r"[0-9a-f]{40}", expected_sha) is not None, "Expected a full source commit SHA")
    require(str(expected_build).isdigit() and int(expected_build) > 0, "Expected a positive workflow build number")
    require(json.loads((root / "versions.json").read_text())["app"] == expected_version, "Checked-out source version differs from requested release")
    choices = json.loads((root / "tools/nikita/assets/icons/manifest.json").read_text())
    icons = [item["name"] for item in choices]
    require(len(icons) == 8 and len(set(icons)) == 8, "Expected eight unique source alternate icons")
    ipa, metadata_path = directory / "CodeGram.ipa", directory / "Build.json"
    ipa_digest = verify_sidecar(ipa)
    metadata_digest = verify_sidecar(metadata_path)
    metadata = json.loads(metadata_path.read_text())
    require(metadata.get("source_commit") == expected_sha, "Build.json source SHA differs from this workflow")
    require(metadata.get("version") == expected_version and str(metadata.get("build_number")) == str(expected_build), "Build.json version/build differs from this workflow")
    require(metadata.get("compiled") is True, "Build.json does not describe a compiled artifact")
    require(metadata.get("sha256") == ipa_digest, "Build.json IPA checksum differs from downloaded bytes")
    require(metadata.get("alternate_icons") == icons, "Build.json alternate icons differ from checked-out source")
    # Reuse the existing release validator, including ZIP CRC, main device
    # Mach-O, identity/version/build, both icon registries and image dimensions.
    details = validate(ipa, expected_version=expected_version, expected_build=expected_build, required_alternate_icons=icons)
    for key in ("name", "bundle_id", "minimum_os", "version", "build_number"):
        require(metadata.get(key) == details[key], "Build.json differs from actual app Info.plist: " + key)
    binaries, images = [], []
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "IPA contains duplicate ZIP entry names")
        location = next(name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2)
        bundle = location.rsplit("/", 1)[0] + "/"
        info = plistlib.loads(archive.read(location))
        require(info.get("CFBundlePackageType") == "APPL", "Main bundle is not an application")
        require("iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), "Main Info.plist is not an iPhoneOS bundle")
        binaries.append(verify_macho(archive, bundle + executable_name(info, location), 2))
        framework_plists = [name for name in names if name.startswith(bundle + "Frameworks/") and name.endswith(".framework/Info.plist") and name[len(bundle + "Frameworks/"):].count("/") == 1]
        expected_ids = {BUNDLE_ID + "." + name for name in FRAMEWORK_IDS}
        actual_ids = set()
        for framework_path in framework_plists:
            framework = plistlib.loads(archive.read(framework_path))
            identifier = framework.get("CFBundleIdentifier")
            require(identifier in expected_ids and identifier not in actual_ids, "Unexpected or repeated embedded framework: " + str(identifier))
            actual_ids.add(identifier)
            require(framework.get("CFBundlePackageType") == "FMWK", "Embedded bundle is not a framework: " + framework_path)
            require(framework.get("CFBundleShortVersionString") == expected_version and str(framework.get("CFBundleVersion")) == str(expected_build), "Framework version/build differs from this workflow: " + framework_path)
            require("iPhoneOS" in framework.get("CFBundleSupportedPlatforms", []), "Framework Info.plist is not an iPhoneOS bundle: " + framework_path)
            binary = framework_path.rsplit("/", 1)[0] + "/" + executable_name(framework, framework_path)
            binaries.append(verify_macho(archive, binary, 6))
        require(actual_ids == expected_ids and len(framework_plists) == 5, "Expected all five compiled Telegram frameworks")
        for registry in ("CFBundleIcons", "CFBundleIcons~ipad"):
            declared = info.get(registry, {}).get("CFBundleAlternateIcons", {})
            for icon in icons:
                files = declared[icon].get("CFBundleIconFiles")
                expected_files = [icon] if registry == "CFBundleIcons" else [icon + "Ipad", icon + "LargeIpad"]
                require(files == expected_files, "Alternate icon file registry differs: " + registry + "/" + icon)
        for icon in icons:
            for suffix, size in (("@2x", 120), ("@3x", 180), ("Preview", 256)):
                filename = bundle + icon + suffix + ".png"
                images.append(verify_png(archive.read(filename), size, filename))
    return dict(source_commit=expected_sha, version=expected_version, build_number=str(expected_build), ipa_sha256=ipa_digest, build_json_sha256=metadata_digest, zip_crc="passed", compiled_binaries=binaries, alternate_icons=icons, verified_images=images, runtime_tested=metadata.get("runtime_tested") is True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--expected-version", default="14.5.0")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = verify(args.directory, expected_sha=args.expected_sha, expected_build=args.expected_build, expected_version=args.expected_version)
    except (ValueError, KeyError, OSError, EOFError, zipfile.BadZipFile, struct.error, zlib.error) as error:
        parser.exit(1, "Release bundle verification failed: " + str(error) + "\n")
    output = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
