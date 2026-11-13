"""Execute emitted ARM64 badge branches in Unicorn, with native calls stubbed.

This validates machine instructions, control flow, memory offsets, and returned
literal flags. It is not a replacement for an iPhone runtime test.
"""
import struct

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X8, UC_ARM64_REG_X19, UC_ARM64_REG_X20, UC_ARM64_REG_X22, UC_ARM64_REG_SP, UC_ARM64_REG_PC, UC_ARM64_REG_LR

from patch_badge import TARGET, UI_STRING, OWNER_TEXT, core_code, ui_pointer_code, ui_length_code, word


def emulator(pages):
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    for page, size in pages:
        uc.mem_map(page, size)
    return uc


def core_case(user_id):
    code = core_code()
    uc = emulator([(0x4000, 0x1000), (0x933000, 0x1000), (0xA8B000, 0x2000), (0x1000000, 0x10000)])
    uc.mem_write(code.start, code.data)
    uc.mem_write(0x9333CC, word(0x540009EB))  # original b.lt 0x933508
    uc.reg_write(UC_ARM64_REG_X0, user_id & ((1 << 64) - 1))
    uc.reg_write(UC_ARM64_REG_SP, 0x1008000)
    calls = []
    stopped = []

    def hook(uc, addr, size, data):
        if addr == 0x933F08:
            calls.append("metadata")
            uc.reg_write(UC_ARM64_REG_X0, 0x11223344)
            uc.reg_write(UC_ARM64_REG_PC, uc.reg_read(UC_ARM64_REG_LR))
        elif addr == 0xA8BC2C:
            assert uc.reg_read(UC_ARM64_REG_X20) == 0x11223344
            assert bytes(uc.mem_read(uc.reg_read(UC_ARM64_REG_X0), 1)) == b"\x01"
            calls.append("single-true")
            uc.reg_write(UC_ARM64_REG_X0, 0x88776655)
            uc.reg_write(UC_ARM64_REG_PC, uc.reg_read(UC_ARM64_REG_LR))
        elif addr in (0x9333D0, 0x933508, 0x933520):
            stopped.append(addr)
            uc.emu_stop()

    uc.hook_add(UC_HOOK_CODE, hook)
    uc.emu_start(code.start, 0, count=100)
    if user_id == TARGET:
        assert stopped == [0x933520]
        assert calls == ["metadata", "single-true"]
        assert uc.reg_read(UC_ARM64_REG_X19) == 0x88776655
    else:
        assert stopped == ([0x933508] if user_id < 1 else [0x9333D0])
        assert calls == []
        assert uc.reg_read(UC_ARM64_REG_X0) == user_id & ((1 << 64) - 1)


def ui_case(user_id, factory, exit_address, expected):
    code = factory()
    uc = emulator([(0x8000, 0x1000), (0x893000, 0x1000), (0x1000000, 0x10000)])
    uc.mem_write(code.start, code.data)
    frame = 0x1001000
    data = 0x1002000
    user = 0x1003000
    uc.reg_write(UC_ARM64_REG_X19, frame)
    uc.reg_write(UC_ARM64_REG_X22, 0x123456789ABC)
    uc.mem_write(frame + 0xA8, struct.pack("<Q", data))
    uc.mem_write(data + 0x38, struct.pack("<Q", user))
    uc.mem_write(user + 0x18, struct.pack("<Q", user_id))
    stopped = []

    def hook(uc, addr, size, ignored):
        if addr == exit_address:
            stopped.append(addr)
            uc.emu_stop()

    uc.hook_add(UC_HOOK_CODE, hook)
    uc.emu_start(code.start, 0, count=100)
    assert stopped == [exit_address]
    assert uc.reg_read(UC_ARM64_REG_X8) == expected
    assert uc.reg_read(UC_ARM64_REG_X22) == 0x123456789ABC
    assert uc.reg_read(UC_ARM64_REG_X19) == frame


if __name__ == "__main__":
    for value in (-1, 0, 1, TARGET - 1, TARGET, TARGET + 1, 2**50):
        core_case(value)
    for value in (1, TARGET - 1, TARGET, TARGET + 1, 2**50):
        ui_case(value, ui_pointer_code, 0x893ADC, UI_STRING if value == TARGET else 0x5B34D90)
        ui_case(value, ui_length_code, 0x893B30, (0x1000000000000000 | len(OWNER_TEXT)) if value == TARGET else 0xD000000000000013)
    print("Passed 17 ARM64 execution cases: exact target, neighboring IDs, zero/negative IDs, and large ID; pointer and UTF-8 count selection.")
