"""Version-pinned, reversible badge patch for Solvgram 1.2 (100063).

Works on copies of the unencrypted ARM64 framework binaries. This does not
remove signatures, alter a server account, or change the original IPA.
Core recognizes the requested local badge ID; UI renders a target-only label.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

TARGET = 7100373090
CORE_CAVE = 0x4000
UI_POINTER_CAVE = 0x8000
UI_LENGTH_CAVE = 0x8100
UI_STRING = 0x8800
OWNER_TEXT = "настоящий владелец".encode("utf-8")


def word(value: int) -> bytes:
    return struct.pack("<I", value)


def branch(at: int, to: int, link: bool = False) -> int:
    delta = to - at
    assert delta % 4 == 0 and -(1 << 27) <= delta < (1 << 27)
    return (0x94000000 if link else 0x14000000) | ((delta >> 2) & 0x03FFFFFF)


def conditional(at: int, to: int, condition: int) -> int:
    delta = to - at
    assert delta % 4 == 0 and -(1 << 20) <= delta < (1 << 20)
    return 0x54000000 | (((delta >> 2) & 0x7FFFF) << 5) | condition


def movz(reg: int, imm: int, shift: int = 0, bits: int = 64) -> int:
    assert shift % 16 == 0 and 0 <= imm <= 0xFFFF
    return (0xD2800000 if bits == 64 else 0x52800000) | ((shift // 16) << 21) | (imm << 5) | reg


def movk(reg: int, imm: int, shift: int = 0) -> int:
    return 0xF2800000 | ((shift // 16) << 21) | (imm << 5) | reg


def ldr(reg: int, base: int, offset: int) -> int:
    assert offset % 8 == 0 and 0 <= offset // 8 <= 0xFFF
    return 0xF9400000 | ((offset // 8) << 10) | (base << 5) | reg


def add(reg: int, base: int, offset: int) -> int:
    assert 0 <= offset <= 0xFFF
    return 0x91000000 | (offset << 10) | (base << 5) | reg


def adr(at: int, reg: int, to: int) -> int:
    delta = to - at
    assert -(1 << 20) <= delta < (1 << 20)
    return 0x10000000 | ((delta & 3) << 29) | (((delta >> 2) & 0x7FFFF) << 5) | reg


def cmp(reg: int, other: int) -> int:
    return 0xEB00001F | (other << 16) | (reg << 5)


def constant(reg: int, value: int) -> list[int]:
    return [movz(reg, value & 0xFFFF), movk(reg, (value >> 16) & 0xFFFF, 16), movk(reg, (value >> 32) & 0xFFFF, 32)]


class Code:
    def __init__(self, start: int):
        self.start = start
        self.words: list[int] = []

    @property
    def pc(self) -> int:
        return self.start + len(self.words) * 4

    def emit(self, *instructions: int):
        self.words.extend(instructions)

    def b(self, target: int, link: bool = False):
        self.emit(branch(self.pc, target, link))

    def conditional(self, target: int, condition: int):
        self.emit(conditional(self.pc, target, condition))

    @property
    def data(self) -> bytes:
        return b"".join(word(x) for x in self.words)


def core_code() -> Code:
    c = Code(CORE_CAVE)
    c.emit(*constant(8, TARGET), cmp(0, 8))
    skip_index = len(c.words)
    c.emit(0)  # b.ne fallback
    # Exact native `.single(false)` path at 0x933508, with a true byte.
    c.b(0x933F08, True)  # Signal<Bool, NoError> metadata accessor
    c.emit(0xAA0003F4, movz(8, 1, bits=32))  # mov x20,x0; mov w8,#1
    c.emit(0x39000000 | (0xF << 10) | (31 << 5) | 8)  # strb w8,[sp,#0xf]
    c.emit(add(0, 31, 0xF))
    c.b(0xA8BC2C, True)  # Signal.single(value), using Swift metadata in x20
    c.emit(0xAA0003F3)  # mov x19,x0 (retain returned Signal for native epilogue)
    c.b(0x933520)
    fallback = c.pc
    c.emit(0xF100041F)  # original cmp x0,#1
    c.b(0x9333CC)  # original b.lt handles negative/zero; fallthrough handles positive IDs
    c.words[skip_index] = conditional(c.start + skip_index * 4, fallback, 1)
    return c


def ui_id(c: Code):
    # x19 is this routine's spill frame base, not the hardware stack pointer.
    # PeerInfoScreenData.peer (at +0x38) is in its `.user` case on this path.
    c.emit(ldr(8, 19, 0xA8), ldr(8, 8, 0x38), ldr(8, 8, 0x18))
    c.emit(*constant(9, TARGET), cmp(8, 9))


def ui_pointer_code() -> Code:
    c = Code(UI_POINTER_CAVE)
    ui_id(c)
    skip_index = len(c.words)
    c.emit(0)
    c.emit(adr(c.pc, 8, UI_STRING))
    c.b(0x893ADC)  # common native `sub pointer,#0x20; orr highbit`
    original = c.pc
    # Original ASCII label address in the same framework, also ASLR-relative.
    delta = ((0x5B34D90 & ~0xFFF) - (c.pc & ~0xFFF)) >> 12
    assert -(1 << 20) <= delta < (1 << 20)
    c.emit(0x90000008 | ((delta & 3) << 29) | (((delta >> 2) & 0x7FFFF) << 5))
    c.emit(add(8, 8, 0xD90))
    c.b(0x893ADC)
    c.words[skip_index] = conditional(c.start + skip_index * 4, original, 1)
    return c


def ui_length_code() -> Code:
    c = Code(UI_LENGTH_CAVE)
    ui_id(c)
    skip_index = len(c.words)
    c.emit(0)
    c.emit(movz(8, len(OWNER_TEXT)), movk(8, 0x1000, 48))  # immortal non-ASCII UTF-8
    c.b(0x893B30)
    original = c.pc
    c.emit(movz(8, 19), movk(8, 0xD000, 48))  # original immortal ASCII literal
    c.b(0x893B30)
    c.words[skip_index] = conditional(c.start + skip_index * 4, original, 1)
    return c


def asserted_write(data: bytearray, offset: int, replacement: bytes, expected: bytes):
    actual = bytes(data[offset:offset + len(expected)])
    if actual != expected:
        raise ValueError(f"Input mismatch at {offset:#x}: expected {expected.hex()}, got {actual.hex()}")
    data[offset:offset + len(replacement)] = replacement


def patch(core_path: Path, ui_path: Path, out_dir: Path) -> dict:
    core = bytearray(core_path.read_bytes())
    ui = bytearray(ui_path.read_bytes())
    input_core_sha = hashlib.sha256(core).hexdigest()
    input_ui_sha = hashlib.sha256(ui).hexdigest()

    # Version guards: exact native entry/false path, UI literal and call site.
    assert core[0x9333B0:0x9333B4] == word(0xD10143FF)  # sub sp,sp,#0x50
    assert core[0x933510:0x933514] == word(0x39003FFF)  # strb wzr,[sp,#0xf]
    assert ui[0x5B34D90:0x5B34D90+20] == b"Creator of Solvgram\0"
    # Native, non-resilient metadata field-offset vectors from this exact build.
    assert struct.unpack_from("<Q", core, 0xE2ADA8 + 10 * 8)[0] == 0x10  # TelegramUser.id
    assert struct.unpack_from("<6Q", ui, 0x6FB48F0 + 10 * 8) == (0x10, 0x2C, 0x31, 0x38, 0x40, 0x48)

    c = core_code()
    p = ui_pointer_code()
    n = ui_length_code()
    asserted_write(core, c.start, c.data, bytes(len(c.data)))
    asserted_write(core, 0x9333C8, word(branch(0x9333C8, c.start)), word(0xF100041F))
    asserted_write(ui, p.start, p.data, bytes(len(p.data)))
    asserted_write(ui, n.start, n.data, bytes(len(n.data)))
    asserted_write(ui, UI_STRING, OWNER_TEXT + b"\0", bytes(len(OWNER_TEXT)+1))
    asserted_write(ui, 0x893AD4, word(branch(0x893AD4, p.start)), bytes.fromhex("089502b0"))
    asserted_write(ui, 0x893B28, word(branch(0x893B28, n.start)), word(movz(8, 19)))

    out_dir.mkdir(parents=True, exist_ok=True)
    cp = out_dir / core_path.name
    up = out_dir / ui_path.name
    cp.write_bytes(core)
    up.write_bytes(ui)
    report = {
        "target_user_id": TARGET,
        "label": OWNER_TEXT.decode(),
        "core": {"input_sha256": input_core_sha, "output_sha256": hashlib.sha256(core).hexdigest(), "output": str(cp)},
        "ui": {"input_sha256": input_ui_sha, "output_sha256": hashlib.sha256(ui).hexdigest(), "output": str(up)},
        "changed_code": [{"framework": "core", "va": hex(c.start), "size": len(c.data)}, {"framework": "ui", "va": hex(p.start), "size": len(p.data)}, {"framework": "ui", "va": hex(n.start), "size": len(n.data)}],
        "verification": "Static instruction/offset verification only; runtime/device verification remains required.",
    }
    (out_dir / "badge_patch.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", type=Path, default=Path("inspect_ipa/TelegramCoreFramework"))
    parser.add_argument("--ui", type=Path, default=Path("inspect_ipa/TelegramUIFramework"))
    parser.add_argument("--output", type=Path, default=Path("reverse/badge/patched"))
    args = parser.parse_args()
    print(json.dumps(patch(args.core, args.ui, args.output), ensure_ascii=False, indent=2))
