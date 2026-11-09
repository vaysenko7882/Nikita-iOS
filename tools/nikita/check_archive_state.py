#!/usr/bin/env python3
"""Exercise archive-state persistence with the repository's real Postbox codec."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def declaration(path, start, following):
    source = (ROOT / path).read_text()
    return source[source.index(start):source.index(following)]


def main():
    with tempfile.TemporaryDirectory(prefix="nikita-archive-state-") as directory:
        temporary = Path(directory)
        module = temporary / "MurMurHash32"
        module.mkdir()
        header = ROOT / "submodules/MurMurHash32/PublicHeaders/MurMurHash32/MurMurHash32.h"
        (module / "module.modulemap").write_text(
            "module MurMurHash32 { header " + json.dumps(str(header)) + " export * }\n")
        objective_c = temporary / "murmur.o"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fmodules", "-c",
            str(ROOT / "submodules/MurMurHash32/Sources/MurMurHash32.m"),
            "-I", str(header.parents[1]), "-o", str(objective_c)], check=True)

        state = declaration("submodules/TelegramCore/Sources/Nikita/NikitaArchiveSync.swift",
            "struct NikitaRemoteArchiveState:", "\nstruct NikitaRemoteArchiveEvent:")
        index = declaration("submodules/TelegramCore/Sources/Settings/DeletedMessageArchiveSettings.swift",
            "public struct DeletedMessageArchiveSettings:", "\nfunc deletedMessageArchiveSettings(")
        message_id = declaration("submodules/Postbox/Sources/Message.swift",
            "public struct MessageId:", "\npublic struct MessageIndex:")
        attribute_protocol = declaration("submodules/Postbox/Sources/Message.swift",
            "public protocol MessageAttribute:", "\npublic struct MessageGroupInfo:")
        archive_attributes = declaration("submodules/TelegramCore/Sources/SyncCore/SyncCore_ArchivedMessageAttribute.swift",
            "// Consumed by the seed merge", "\npublic extension Message {")
        declarations = temporary / "ProductionArchiveState.swift"
        resource = (ROOT / "submodules/TelegramCore/Sources/Nikita/NikitaArchiveMediaResource.swift").read_text().replace("import Postbox\n", "")
        resource_protocol = (ROOT / "submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramMediaResource.swift").read_text().replace("import Postbox\n", "")
        declarations.write_text("import Foundation\n" + state + "\n" + index + "\n" +
            resource_protocol + "\n" + resource + "\n" + message_id + "\n" +
            attribute_protocol + "\n" + archive_attributes)

        # These unrelated Postbox dependency types are not exercised by this
        # persistence test. The encoder, decoder, buffers, PreferencesEntry,
        # state/index, MessageId, MessageAttribute and archive attributes are
        # production sources. Only unrelated dependency types are stubbed.
        support = temporary / "CodecSupport.swift"
        support.write_text('''import Foundation
public enum CachedMediaRepresentationKeepDuration {}
public struct PeerId: Hashable, Comparable, Codable, CustomStringConvertible {
    let rawValue: Int64
    init(_ value: Int64) { self.rawValue = value }
    func toInt64() -> Int64 { return self.rawValue }
    public var description: String { return String(self.rawValue) }
    public static func <(lhs: PeerId, rhs: PeerId) -> Bool { return lhs.rawValue < rhs.rawValue }
}
public struct MediaId {}
public struct StoryId {}
func postboxLog(_ message: String) {}
func mdb_cmp_memn(_ left: UnsafeRawPointer, _ leftCount: Int,
    _ right: UnsafeRawPointer, _ rightCount: Int) -> Int32 {
    let result = memcmp(left, right, min(leftCount, rightCount))
    if result != 0 { return result }
    return leftCount == rightCount ? 0 : (leftCount < rightCount ? -1 : 1)
}
''')
        sources = [ROOT / "submodules/Postbox/Sources/Coding.swift",
            ROOT / "submodules/Postbox/Sources/MediaResource.swift",
            ROOT / "submodules/Postbox/Sources/PreferencesEntry.swift"]
        for part in ("Encoder", "Decoder"):
            sources.extend(sorted((ROOT / "submodules/Postbox/Sources/Utils" / part).glob("*.swift")))
        executable = temporary / "archive-state-check"
        subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-Osize", "-whole-module-optimization", "-g", "-warnings-as-errors", "-parse-as-library",
            "-I", str(module), *map(str, sources), str(support), str(declarations),
            str(ROOT / "submodules/TelegramCore/Sources/Nikita/DeletedMessageArchiveBatch.swift"),
            str(ROOT / "tools/nikita/tests/ArchiveStateCheck.swift"), str(objective_c),
            "-framework", "Foundation", "-o", str(executable)], check=True)

        # Keep the known-broken decode in a separate process: a precondition
        # failure cannot be caught with Swift do/catch or try?.
        legacy = subprocess.run([str(executable), "--legacy-crash"], capture_output=True, text=True,
            env={**os.environ, "SWIFT_BACKTRACE": "enable=no"}, timeout=30)
        # Some managed macOS runners prohibit Swift's crash backtrace helper.
        # Require that encoding finished and that the decode raised a fatal
        # signal, rather than depending on an optional symbolized backtrace.
        if ("legacy-state-encoded; entering Dictionary decoding" not in legacy.stdout or
                legacy.returncode not in (-4, -5, -6)):
            raise RuntimeError("Expected a fatal signal from legacy Dictionary decoding; got " +
                str(legacy.returncode) + ":\n" + legacy.stderr[-6000:])
        subprocess.run([str(executable)], check=True, timeout=30)
        print("Reproduced legacy allKeys crash; fixed state and legacy migration passed using the real Postbox codec.")


if __name__ == "__main__":
    main()

