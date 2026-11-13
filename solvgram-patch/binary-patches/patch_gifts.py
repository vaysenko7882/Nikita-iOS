#!/usr/bin/env python3
"""Exact-version Solvgram 1.2 gift instrumentation and local attribute renderer.

Never edits the input file. Header padding 0x7000..0x77ff is reserved for
these trampolines; badge instrumentation uses a separate cave. The four
runtime slots live in the existing zero-filled __DATA segment tail.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

SEND_ENTRY = 0x949BF0
SEND_CONTINUE = SEND_ENTRY + 4
COST_CALL = 0x94A450
COST_CONTINUE = COST_CALL + 4
STARS_SET = 0x9427EC
STARS_GET = 0x9420B8
RENDER_CALL = 0x9438A0
RENDER_FALLBACK = 0x943A60
SEND_CAVE = 0x7000
COST_CAVE = 0x7040
CAVE_END = 0x7800
RUNTIME_SLOTS = 0xF06000
ACCOUNT_SLOT = RUNTIME_SLOTS
PRODUCT_SLOT = RUNTIME_SLOTS + 8
COST_SLOT = RUNTIME_SLOTS + 16
ACCOUNT_ID_SLOT = RUNTIME_SLOTS + 24


def u32(word: int) -> bytes:
    return struct.pack('<I', word & 0xffffffff)


def branch(source: int, target: int, *, link: bool = False) -> bytes:
    delta = target - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('ARM64 branch is out of range or unaligned')
    return u32((0x94000000 if link else 0x14000000) | ((delta // 4) & 0x3ffffff))


def adrp(reg: int, pc: int, target: int) -> bytes:
    pages = ((target & ~0xfff) - (pc & ~0xfff)) // 4096
    if not -(1 << 20) <= pages < (1 << 20):
        raise ValueError('ARM64 ADRP is out of range')
    bits = pages & 0x1fffff
    return u32(0x90000000 | ((bits & 3) << 29) | ((bits >> 2) << 5) | reg)


def mem64(*, load: bool, reg: int, base: int, offset: int) -> bytes:
    if offset % 8 or not 0 <= offset // 8 < 4096:
        raise ValueError('Invalid scaled ARM64 load/store offset')
    return u32((0xf9400000 if load else 0xf9000000) | ((offset // 8) << 10) | (base << 5) | reg)


def patchset() -> list[dict]:
    # x8/x9 are caller-saved scratch registers and have no incoming meaning in
    # this reference-returning Swift method. x0..x7, Swift self x20, LR and SP
    # are preserved until the original stack allocation is performed.
    send = b''.join([
        adrp(8, SEND_CAVE, RUNTIME_SLOTS),
        mem64(load=True, reg=9, base=20, offset=0x10),
        mem64(load=False, reg=9, base=8, offset=0),
        mem64(load=False, reg=0, base=8, offset=8),
        bytes.fromhex('ff4302d1'),  # original sub sp,sp,#0x90
        branch(SEND_CAVE + 20, SEND_CONTINUE),
    ])
    # The patched BL sets LR to COST_CONTINUE. Tail-branching from the cave to
    # the original setter leaves that LR intact; the setter returns directly
    # to the native continuation. x20 is the per-gift cost at this call site.
    # Recover Account from this request's async context, rather than the last
    # globally captured send entry. The current 94a30c frame points to wrapper
    # 952840's frame, whose parent is helper946ca4's frame. That helper stores
    # its Account x4 at +0x3c0; the current frame stores giftId x5 at +0x3c8.
    # Account.peerId is +0x100. Verify it against the Stars accountID before
    # publishing the pointer; a mismatch disables native preview for the task.
    cost_words = [
        adrp(8, COST_CAVE, RUNTIME_SLOTS),
        mem64(load=True, reg=9, base=22, offset=0),
        mem64(load=True, reg=9, base=9, offset=0),
        mem64(load=True, reg=9, base=9, offset=0x3c0),
        mem64(load=False, reg=9, base=8, offset=0),
        mem64(load=True, reg=9, base=9, offset=0x100),
        u32(0xeb01013f),  # cmp x9,x1
        u32(0x54000040), # b.eq +8
        mem64(load=False, reg=31, base=8, offset=0),
        mem64(load=True, reg=9, base=22, offset=0x3c8),
        mem64(load=False, reg=9, base=8, offset=8),
        mem64(load=False, reg=20, base=8, offset=16),
        mem64(load=False, reg=1, base=8, offset=24),
        branch(COST_CAVE + 13 * 4, STARS_SET),
    ]
    cost = b''.join(cost_words)
    assert SEND_CAVE + len(send) <= COST_CAVE
    assert COST_CAVE + len(cost) <= CAVE_END
    return [
        {'name': 'capture selected product and native Account', 'offset': SEND_CAVE,
         'expected': bytes(len(send)), 'replacement': send},
        {'name': 'capture exact per-request Account, product, cost and Stars account', 'offset': COST_CAVE,
         'expected': bytes(len(cost)), 'replacement': cost},
        {'name': 'redirect native send entry', 'offset': SEND_ENTRY,
         'expected': bytes.fromhex('ff4302d1'),
         'replacement': branch(SEND_ENTRY, SEND_CAVE)},
        {'name': 'instrument existing local Stars deduction', 'offset': COST_CALL,
         'expected': branch(COST_CALL, STARS_SET, link=True),
         'replacement': branch(COST_CALL, COST_CAVE, link=True)},
        {'name': 'render Solvgram attributes from catalog indices', 'offset': RENDER_CALL,
         'expected': bytes.fromhex('6afcff97'),
         'replacement': bytes.fromhex('010080d2')},
    ]


def inspect_layout(data: bytes) -> None:
    if len(data) < 0xE00000 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x100000c):
        raise ValueError('Expected the unencrypted ARM64 TelegramCoreFramework from Solvgram 1.2')
    ncmds = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    data_segment = None
    text_segment = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd == 0x19:
            name, vmaddr, vmsize, fileoff, filesize, _, initprot, _, _ = struct.unpack_from('<16sQQQQIIII', data, offset + 8)
            name = name.rstrip(b'\0')
            if name == b'__DATA':
                data_segment = (vmaddr, vmsize, fileoff, filesize, initprot)
            elif name == b'__TEXT':
                text_segment = (vmaddr, vmsize, fileoff, filesize, initprot)
        offset += size
    if not text_segment or text_segment[0] != 0 or text_segment[2] != 0 or not text_segment[4] & 4:
        raise ValueError('Unexpected __TEXT layout or executable protection')
    if not data_segment:
        raise ValueError('Missing __DATA segment')
    va, size, _, filesize, protection = data_segment
    if not (va + filesize <= RUNTIME_SLOTS and RUNTIME_SLOTS + 32 <= va + size and protection & 2):
        raise ValueError('Runtime slots are not in the writable, zero-filled __DATA tail')
    # The branch after the replaced slug constructor is critical: it must still
    # select the pre-existing fallback signal. This guard tolerates badge code.
    # Exact async-frame links and Account/product captures used by cost cave.
    guards = {
        0x946cc4: bytes.fromhex('c4e201f9'),  # str x4,[x22,#0x3c0]
        0x94a340: bytes.fromhex('c5e601f9'),  # str x5,[x22,#0x3c8]
        0x9528a8: bytes.fromhex('162400a9'),  # stp x22,x9,[x0]
    }
    for address, expected in guards.items():
        if data[address:address + 4] != expected:
            raise ValueError(f'Unexpected native async context layout at 0x{address:x}')
    if data[RENDER_CALL + 4:RENDER_CALL + 8] != bytes.fromhex('e10d00b4'):
        raise ValueError('Unexpected attribute renderer continuation')


def apply(data: bytes) -> tuple[bytes, list[dict]]:
    inspect_layout(data)
    updated = bytearray(data)
    changes = patchset()
    for entry in changes:
        a = entry['offset']; expected = entry['expected']; replacement = entry['replacement']
        actual = data[a:a + len(expected)]
        if actual not in (expected, replacement):
            raise ValueError(f"Patch guard failed for {entry['name']} at 0x{a:x}: {actual.hex()}")
        updated[a:a + len(replacement)] = replacement
    return bytes(updated), changes


def verify() -> dict:
    # Emulation covers both a zero slide and a realistic nonzero image slide.
    # All code under test is the emitted machine code, not a mirrored Python
    # implementation. Native helper bodies are replaced by a RET at their
    # entry only so we can check the trampoline's exact call/return contract.
    dependency_dir = Path(__file__).resolve().parents[2] / 'reverse-deps'
    if dependency_dir.is_dir():
        sys.path.insert(0, str(dependency_dir))
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
    from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X8, UC_ARM64_REG_X9, UC_ARM64_REG_X20, UC_ARM64_REG_X30, UC_ARM64_REG_SP, UC_ARM64_REG_PC
    # Unicorn's x29/x30 constants are outside the sequential x0..x28 block.
    from unicorn.arm64_const import UC_ARM64_REG_X29
    regs = [UC_ARM64_REG_X0 + i for i in range(29)] + [UC_ARM64_REG_X29, UC_ARM64_REG_X30]
    verified = []
    for slide in (0, 0x180000000):
        for case in ('send_entry', 'cost_setter', 'cost_account_mismatch', 'attribute_fallback'):
            uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
            uc.mem_map(slide, 0x1000000)
            stack = slide + 0x2000000
            uc.mem_map(stack, 0x10000)
            for e in patchset():
                uc.mem_write(slide + e['offset'], e['replacement'])
            uc.mem_write(slide + RENDER_CALL + 4, bytes.fromhex('e10d00b4'))
            initial = {r: 0x100000000000000 + i * 0x10001 for i, r in enumerate(regs)}
            engine = slide + 0xE00000
            account = 0x123456789ABC
            product = 0x0040123456789ABC
            initial[UC_ARM64_REG_X0] = product
            initial[UC_ARM64_REG_X20] = engine
            for r, value in initial.items():
                uc.reg_write(r, value)
            original_sp = stack + 0x8000
            uc.reg_write(UC_ARM64_REG_SP, original_sp)
            if case == 'send_entry':
                uc.mem_write(engine + 0x10, struct.pack('<Q', account))
                start = slide + SEND_ENTRY; stop = slide + SEND_CONTINUE
            elif case in ('cost_setter', 'cost_account_mismatch'):
                initial[regs[0]] = 999900
                initial[regs[1]] = 7100373090
                initial[UC_ARM64_REG_X20] = 100
                from unicorn.arm64_const import UC_ARM64_REG_X22
                frame = slide + 0xE10000
                wrapper = slide + 0xE11000
                grandparent = slide + 0xE12000
                real_account = slide + 0xE13000
                initial[UC_ARM64_REG_X22] = frame
                uc.mem_write(frame, struct.pack('<Q', wrapper))
                uc.mem_write(wrapper, struct.pack('<Q', grandparent))
                uc.mem_write(grandparent + 0x3c0, struct.pack('<Q', real_account))
                uc.mem_write(frame + 0x3c8, struct.pack('<Q', product))
                uc.mem_write(real_account + 0x100, struct.pack('<Q', 7100373090 if case == 'cost_setter' else 12345))
                # Seed stale global values: this request must overwrite them.
                uc.mem_write(slide + RUNTIME_SLOTS, struct.pack('<QQQQ', 0xdeadbeef, 4444, 55, 6666))
                for r, value in initial.items():uc.reg_write(r, value)
                uc.mem_write(slide + STARS_SET, bytes.fromhex('c0035fd6'))
                start = slide + COST_CALL; stop = slide + COST_CONTINUE
            else:
                start = slide + RENDER_CALL; stop = slide + RENDER_FALLBACK
            visited = []
            def on_code(emu, address, size, userdata):
                visited.append(address)
                if address == stop:
                    emu.emu_stop()
            uc.hook_add(UC_HOOK_CODE, on_code)
            uc.emu_start(start, slide + 0x1000000, count=32)
            assert uc.reg_read(UC_ARM64_REG_PC) == stop, (case, visited)
            ignored = {UC_ARM64_REG_X8, UC_ARM64_REG_X9}
            if case == 'send_entry':
                assert struct.unpack('<QQ', uc.mem_read(slide + RUNTIME_SLOTS, 16)) == (account, product)
                assert uc.reg_read(UC_ARM64_REG_SP) == original_sp - 0x90
            elif case in ('cost_setter', 'cost_account_mismatch'):
                expected_account = real_account if case == 'cost_setter' else 0
                assert struct.unpack('<QQ', uc.mem_read(slide + ACCOUNT_SLOT, 16)) == (expected_account, product)
                assert struct.unpack('<QQ', uc.mem_read(slide + COST_SLOT, 16)) == (100, 7100373090)
                assert slide + STARS_SET in visited
                assert uc.reg_read(UC_ARM64_REG_X30) == stop
                assert uc.reg_read(UC_ARM64_REG_SP) == original_sp
                ignored.add(UC_ARM64_REG_X30)
            else:
                assert uc.reg_read(regs[1]) == 0
                assert uc.reg_read(UC_ARM64_REG_SP) == original_sp
                ignored = {regs[1]}
            for r, value in initial.items():
                if r not in ignored:
                    assert uc.reg_read(r) == value, (case, r, hex(uc.reg_read(r)), hex(value))
            verified.append({'case': case, 'slide': hex(slide), 'instructions': len(visited) - 1})
    return {'passed': True, 'checks': verified}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, nargs='?')
    parser.add_argument('output', type=Path, nargs='?')
    parser.add_argument('--verify', action='store_true', help='emulate all trampolines before writing')
    args = parser.parse_args()
    result = {}
    if args.verify:
        result['emulation'] = verify()
    if args.input or args.output:
        if not args.input or not args.output:
            parser.error('Both input and output are required')
        if args.input.resolve() == args.output.resolve():
            parser.error('Refusing to modify the original input')
        before = args.input.read_bytes(); after, changes = apply(before)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(after)
        result.update({'input_sha256': hashlib.sha256(before).hexdigest(),
                       'output_sha256': hashlib.sha256(after).hexdigest(),
                       'output': str(args.output.resolve()),
                       'patches': [{'name': e['name'], 'offset': hex(e['offset']),
                                    'before': e['expected'].hex(), 'after': e['replacement'].hex()}
                                   for e in changes]})
    elif not args.verify:
        parser.error('Supply input/output paths or --verify')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
