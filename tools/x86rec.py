#!/usr/bin/env python3
"""Static recompiler: 32-bit x86 (JadeEmpire.exe) -> Odin source.

Model (docs/recompiler.md):
- Guest state is the global `x86.cpu`; guest memory is one flat 4 GiB region,
  so a guest address is an offset (`x86.rd32(a)`).
- A guest function is an Odin procedure. `call` pushes the guest return
  address and makes a host call; `ret` adjusts esp and makes a host return.
  A jump out of the function is a tail call: host call, then host return.
- Inside a function, control flow is `for { switch pc { ... } }` over
  basic-block labels, as in the BoF4 recompiler.
- Flags are computed only when a later instruction reads them (backward
  liveness over the function CFG). Liveness crosses function boundaries:
  compiled code never passes flags, but the CRT's hand-written math helpers
  do (the acos path returns ZF from a helper and branches on it in the next
  callee), so a call uses the flags its target reads at entry, a return
  keeps the flags any caller reads after the call, and a tail jump does both.
  Indirect calls and jumps pass no flags.

Usage:
  x86rec.py <JadeEmpire.exe> <ghidra_funcs.txt> <out_dir>
"""

import hashlib
import os
import pickle
import struct
import sys
import re
from collections import defaultdict

import pefile
from capstone import Cs, CS_AC_READ, CS_AC_WRITE, CS_ARCH_X86, CS_MODE_32
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_OP_REG

TEXT_LO, TEXT_HI = 0x401000, 0x6E1000
DATA_LO, DATA_HI = 0x6E1000, 0x895000
OEP = 0x6B4923
# Instructions per generated package. Packages are separate LLVM modules
# under -use-separate-modules, which keeps compile time and memory bounded.
PACKAGE_INSNS = 40000
# Functions with more labels are compiled unoptimized. LLVM's dominator and
# branch-probability work is superlinear in one function's blocks, and the two
# such functions (the C++ EH funclets lumped at 0x6c1790, the HRESULT name
# lookup 0x69d936) are cold yet held the build on one thread for over a minute.
# WHY: docs/recompiler.md §1
COLD_LABELS = 2000

# Instructions whose immediate is a count of frames at the game's 30 fps
# (ClampFPS): death-panel delay 0x42b750, a 5-frame update throttle 0x4d5094,
# creature trail and periodic-check intervals 0x4eaa30, 0x4f0800. The lift
# emits x86.frames(imm) instead, the count at the current frame rate.
# WHY: docs/rendering.md §5
FRAME_COUNTS = {0x42B776, 0x4D5094, 0x4EAA3C, 0x4EAA43, 0x4F080B, 0x4F0826}

CF, PF, AF, ZF, SF, OF = 1, 2, 4, 8, 16, 32
ALL = 63

SIZE_T = {1: "u8", 2: "u16", 4: "u32", 8: "u64"}
SIGN = {1: "0x80", 2: "0x8000", 4: "0x80000000"}
STYPE = {1: "i8", 2: "i16", 4: "i32"}
R32 = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]
R16 = {"ax": "eax", "cx": "ecx", "dx": "edx", "bx": "ebx", "sp": "esp", "bp": "ebp", "si": "esi", "di": "edi"}
R8L = {"al": "eax", "cl": "ecx", "dl": "edx", "bl": "ebx"}
R8H = {"ah": "eax", "ch": "ecx", "dh": "edx", "bh": "ebx"}

# Condition code -> (flags read, expression over c.* flags).
COND = {
    "o": (OF, "c.of"), "no": (OF, "!c.of"),
    "b": (CF, "c.cf"), "ae": (CF, "!c.cf"),
    "e": (ZF, "c.zf"), "ne": (ZF, "!c.zf"),
    "be": (CF | ZF, "(c.cf || c.zf)"), "a": (CF | ZF, "(!c.cf && !c.zf)"),
    "s": (SF, "c.sf"), "ns": (SF, "!c.sf"),
    "p": (PF, "c.pf"), "np": (PF, "!c.pf"),
    "l": (SF | OF, "(c.sf != c.of)"), "ge": (SF | OF, "(c.sf == c.of)"),
    "le": (ZF | SF | OF, "(c.zf || c.sf != c.of)"), "g": (ZF | SF | OF, "(!c.zf && c.sf == c.of)"),
}
JCC = {"j" + k: k for k in COND}
SETCC = {"set" + k: k for k in COND}

PREFIXES = {0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3}


def hexu(v):
    return "0x%08x" % (v & 0xFFFFFFFF)


def lit(v, size):
    return "%s(0x%x)" % (SIZE_T[size], v & ((1 << (8 * size)) - 1))


class Unsupported(Exception):
    pass


# ---------------------------------------------------------------- image

# Guest byte patches applied before decoding: (va, original bytes, new bytes).
# WHY: docs/recompiler.md §9
PATCHES = [
    # New Game's hideload box: duration 1.5 and 0.25 become -0.999, so the
    # timer dur + 1.0 is about 0.001 and closes the box on its first update.
    (0x5699d9, "0000c03f", "77be7fbf"),
    (0x569a04, "0000803e", "77be7fbf"),
    # CXbInput's per-axis stick deadzone, -6535..6535 on each of left X/Y and
    # right X/Y, becomes 0: the port applies a radial one (win32/pad.odin).
    (0x668481, "79e6", "0000"), (0x668487, "8719", "0000"),
    (0x6684d5, "79e6", "0000"), (0x6684dc, "8719", "0000"),
    (0x668521, "79e6", "0000"), (0x668527, "8719", "0000"),
    (0x66856d, "79e6", "0000"), (0x668574, "8719", "0000"),
    # CPanelCustomVideo's row label strrefs, nine at 0x75b868, are read from
    # the port's table at 0x00a00000 instead, 28 rows: the game's nine, then
    # the port's video settings (port/src/native/settings.odin, VIDEO_ROWS_N).
    (0x54ee97, "8b14bd68b87500", "8b14bd0000a000"),
    (0x54d4b0, "3b0c8568b87500", "3b0c850000a000"),
    (0x54d849, "3b04ad68b87500", "3b04ad0000a000"),
    (0x54d4bc, "83f809", "83f81c"), (0x54f293, "83ff09", "83ff1c"),
    # The selection handler gives rows 5 to 7 the value arrows, not row 8
    # (Brightness, a slider): cmp edi,7; jne becomes cmp edi,8; je, so the
    # port's rows get them too.
    (0x54e4aa, "83ff070f85ae000000", "83ff080f84ae000000"),
    # CPanelOptionsCont's rows, five of {strref, default, min, max} at
    # 0x703448, are built from the port's table at 0x00a00100, eighteen
    # rows: the game's five, then the port's pad settings (CONTROL_ROWS_N).
    # Their description strrefs at 0x6ff1fc move to 0x00a00280 likewise. Stepping
    # and the game's config still use its own five.
    (0x574051, "6a05", "6a12"), (0x574064, "6a05", "6a12"),
    (0x57406f, "be48347000", "be0001a000"),
    (0x574181, "81fe48347000", "81fe0001a000"),
    (0x574296, "817c241c48347000", "817c241c0001a000"),
    (0x5742e6, "83f805", "83f812"),
    (0x57015f, "8b04bdfcf16f00", "8b04bd8002a000"),
    # CEffectLODManager's budget, sized for the Xbox: the prune 0x50f3e0
    # destroys the oldest effects while the weighted count [0x76cadc] is over
    # 10, and the gate 0x50f080 allows optional spawns only while count * 0.1
    # is at most 0.5. The cap becomes 40 and the gate's factor 0.025 (an
    # existing read-only constant), so optional spawns run to 20.
    (0x50f3e0, "833ddcca76000a", "833ddcca760028"),
    (0x50f446, "833ddcca76000a", "833ddcca760028"),
    (0x50f09e, "d80d382f6e00", "d80d60346e00"),
    # DoEvade's bounds, the dots of the dodge direction with the facing and
    # its right against +-cos 45 (doubles 0x6e53c8, 0x6e53c0, shared), read
    # from the port's front, back and two roll bounds at 0x00a00310
    # instead (native/dodge.odin): +-cos 30 for the flips, +-sin 30 for the
    # rolls, so every direction past the flips rolls.
    (0x4c3418, "dc15c8536e00", "dc151003a000"),
    (0x4c354f, "dc1dc0536e00", "dc1d1803a000"),
    (0x4c369d, "dc15c8536e00", "dc152003a000"),
    (0x4c36ee, "dc1dc0536e00", "dc1d2803a000"),
    # The save message's redraw loops after a save, in the main loop
    # (0x4a4ee0) and the save screen's callback (0x556500), run once instead
    # of 17 times: each pass presents a frame, about 280 ms per save.
    (0x4a4ed2, "bf11000000", "bf01000000"),
    (0x5564e7, "be11000000", "be01000000"),
]


class Image:
    def __init__(self, path):
        pe = pefile.PE(path)
        self.base = pe.OPTIONAL_HEADER.ImageBase
        data = bytearray(pe.get_memory_mapped_image())
        for va, old, new in PATCHES:
            o = va - self.base
            assert data[o:o + len(old) // 2].hex() == old, hex(va)
            data[o:o + len(new) // 2] = bytes.fromhex(new)
        self.data = bytes(data)
        self.md = Cs(CS_ARCH_X86, CS_MODE_32)
        self.md.detail = True
        self.cache = {}
        self.iat = {}
        for d in pe.DIRECTORY_ENTRY_IMPORT:
            for imp in d.imports:
                name = imp.name.decode() if imp.name else "ord%d" % imp.ordinal
                self.iat[imp.address] = "%s!%s" % (d.dll.decode().lower(), name)

    def u32(self, va):
        o = va - self.base
        if o < 0 or o + 4 > len(self.data):
            return None
        return struct.unpack_from("<I", self.data, o)[0]

    def insn(self, pc):
        """Decoded instruction at pc, or None if it does not decode."""
        if pc in self.cache:
            return self.cache[pc]
        o = pc - self.base
        ins = next(self.md.disasm(self.data[o:o + 16], pc), None)
        self.cache[pc] = ins
        return ins


# Mnemonics that never occur in this compiler's output; seeing one means the
# bytes are data, not code.
BOGUS = {"in", "out", "insb", "insd", "outsb", "outsd", "rep outsd", "iretd", "retf", "into",
         "das", "daa", "aaa", "aas", "aam", "aad", "les", "lds", "ljmp", "lcall", "sldt", "salc",
         "hlt", "cli", "sti", "int", "int1", "arpl", "bound", "pushaw", "popaw"}


# ---------------------------------------------------------------- control flow

def control(img, ins):
    """(kind, target) for a control transfer, (None, None) otherwise.
    kind: jmp | jcc | call | ret | ijmp | icall | loop"""
    m = ins.mnemonic
    if m in ("ret", "retn"):
        return "ret", None
    if m == "jmp" or m in JCC or m in ("jecxz", "loop", "loope", "loopne", "call"):
        op = ins.operands[0]
        if op.type == X86_OP_IMM:
            kind = "jmp" if m == "jmp" else "call" if m == "call" else "jcc"
            return kind, op.imm & 0xFFFFFFFF
        return ("icall" if m == "call" else "ijmp"), None
    return None, None


def switch_table(img, ins, prev):
    """Entries of `jmp [idx*4 + table]`, or None. prev: the instruction before
    ins in the same block, or None."""
    op = ins.operands[0]
    if op.type != X86_OP_MEM:
        return None
    mem = op.mem
    if mem.base != 0 or mem.index == 0 or mem.scale != 4:
        return None
    ents = []
    tbl = mem.disp & 0xFFFFFFFF
    if (prev is not None and prev.mnemonic == "neg" and prev.operands[0].type == X86_OP_REG
            and prev.operands[0].reg == mem.index):
        # `neg idx; jmp [idx*4 + table]` indexes at or below the table (CRT
        # memmove backward tail, index -7..0): scan down from slot 0.
        for k in range(4096):
            v = img.u32(tbl - 4 * k)
            if v is None or not (TEXT_LO <= v < TEXT_HI):
                break
            ents.append(v)
        return ents
    for k in range(4096):
        v = img.u32(tbl + 4 * k)
        if v is None or not (TEXT_LO <= v < TEXT_HI):
            # An index that never takes low values leaves leading slots that
            # overlap other bytes (CRT memcpy: index 1..3 after the jmp).
            if not ents and k < 3:
                continue
            break
        ents.append(v)
    return ents


class Func:
    def __init__(self, start, end):
        self.start = start            # region [start, end)
        self.end = end
        self.entries = {start}        # addresses other code can enter at
        self.insns = {}               # pc -> capstone insn
        self.labels = set()
        self.succ = defaultdict(list)  # pc -> intra successors
        self.tables = {}              # pc of jmp -> entries
        self.out = set()              # tail-call targets outside the region
        self.bad = set()

    def inside(self, a):
        return self.start <= a < self.end


def decode_func(img, f):
    """Collect the instructions reachable from f.entries inside the region."""
    f.insns.clear(); f.labels = set(f.entries); f.succ.clear(); f.tables.clear(); f.out.clear(); f.bad.clear()
    work = sorted(f.entries)
    seen = set()
    while work:
        pc = work.pop()
        prev = None
        while True:
            if pc in seen:
                break
            if not f.inside(pc):
                f.out.add(pc)
                break
            ins = img.insn(pc)
            if ins is None or ins.mnemonic in BOGUS:
                f.bad.add(pc)
                f.insns[pc] = ins
                seen.add(pc)
                break
            seen.add(pc)
            f.insns[pc] = ins
            nxt = pc + ins.size
            kind, t = control(img, ins)
            if kind in ("jmp", "jcc"):
                if f.inside(t):
                    f.labels.add(t); work.append(t); f.succ[pc].append(t)
                else:
                    f.out.add(t)
                if kind == "jmp":
                    break
                f.succ[pc].append(nxt)
                if not f.inside(nxt):
                    f.out.add(nxt)
                    break
                f.labels.add(nxt)
            elif kind == "ijmp":
                ents = switch_table(img, ins, prev)
                if ents:
                    f.tables[pc] = ents
                    for e in ents:
                        if f.inside(e):
                            f.labels.add(e); work.append(e); f.succ[pc].append(e)
                        else:
                            f.out.add(e)
                break
            elif kind == "ret":
                break
            elif ins.mnemonic in ("int3", "ud2"):
                break
            else:
                if kind in ("call",):
                    pass
                if nxt not in f.insns and not f.inside(nxt):
                    f.out.add(nxt)
                    break
                if kind is None or kind in ("call", "icall"):
                    f.succ[pc].append(nxt)
            prev = ins
            pc = nxt
    split_overlaps(f)


def split_overlaps(f):
    """Overlapping instruction streams (a label one byte into an instruction,
    e.g. 0x464c45 inside `cmp [esi+0x9c], edi` at 0x464c44) interleave in
    address order. The emitter walks address order and falls through between
    cases, so at every break in that order the true successor and the
    out-of-order instruction both become labels; the emitter then jumps
    instead of falling through."""
    pcs = sorted(f.insns)
    for p, q in zip(pcs, pcs[1:]):
        ins = f.insns[p]
        if ins is None or p in f.bad:
            continue
        nxt = p + ins.size
        if nxt != q:
            f.labels.add(q)
            if nxt in f.insns:
                f.labels.add(nxt)


def data_pointers(img):
    ptrs = set()
    for va in range(DATA_LO, DATA_HI - 3, 4):
        v = img.u32(va)
        if TEXT_LO <= v < TEXT_HI:
            ptrs.add(v)
    return ptrs


def clean_path(img, pc, limit=4000):
    """Straight-line instructions from pc up to a terminator, or None when the
    path hits bogus bytes or leaves .text."""
    path = []
    for _ in range(limit):
        if not (TEXT_LO <= pc < TEXT_HI):
            return None
        ins = img.insn(pc)
        if ins is None or ins.mnemonic in BOGUS:
            return None
        path.append(ins)
        kind, _ = control(img, ins)
        if kind in ("ret", "jmp", "ijmp") or ins.mnemonic == "int3":
            return path
        pc += ins.size
    return None


def build_funcs(img, ghidra):
    """Partition .text into regions at primary entries, decode each, then add
    secondary entries (data pointers, tail-jump targets) until stable."""
    primary = {a for a in ghidra if TEXT_LO <= a < TEXT_HI} | {OEP}
    # Direct call targets found by a first pass become primary entries.
    for _ in range(4):
        starts = sorted(primary)
        funcs = [Func(s, starts[k + 1] if k + 1 < len(starts) else TEXT_HI) for k, s in enumerate(starts)]
        calls = set()
        for f in funcs:
            decode_func(img, f)
            for pc, ins in f.insns.items():
                if ins is None:
                    continue
                kind, t = control(img, ins)
                if kind == "call" and TEXT_LO <= t < TEXT_HI:
                    calls.add(t)
        new = calls - primary
        if not new:
            break
        primary |= new
    starts = sorted(primary)
    funcs = [Func(s, starts[k + 1] if k + 1 < len(starts) else TEXT_HI) for k, s in enumerate(starts)]
    import bisect

    def owner(a):
        k = bisect.bisect_right(starts, a) - 1
        return funcs[k] if k >= 0 else None

    for f in funcs:
        decode_func(img, f)

    def imm_pointers(fs):
        # Code addresses as instruction immediates (`push offset fn` for
        # atexit, `mov [esi], offset vtable_thunk`); jump/call targets excluded.
        out = set()
        for f in fs:
            for ins in f.insns.values():
                if ins is None or control(img, ins)[0] is not None:
                    continue
                for op in ins.operands:
                    if op.type == X86_OP_IMM and TEXT_LO <= (op.imm & 0xFFFFFFFF) < TEXT_HI:
                        out.add(op.imm & 0xFFFFFFFF)
        return out

    def overlaps(f, p):
        return any(q < p < q + i.size for q in range(p - 15, p) for i in [f.insns.get(q)] if i)

    # Pointer candidates (data words, immediates) are accepted on an
    # instruction boundary of decoded code, or when they decode cleanly in
    # undecoded bytes. Tail-jump targets are always accepted.
    rejected = set()
    cands = data_pointers(img) | imm_pointers(funcs)
    forced = set()
    while cands or forced:
        changed = set()
        # Ascending order, and each accepted path is claimed at once, so two
        # candidates in one batch cannot both enter overlapping decodes.
        for p in sorted(cands | forced):
            f = owner(p)
            if f is None or p in f.entries:
                continue
            ok = p in forced or (f.insns.get(p) is not None)
            if not ok and not overlaps(f, p):
                path = clean_path(img, p)
                # A path that straddles decoded instruction starts is a
                # misaligned decode of known code, not a new entry.
                if path is not None and not any(
                    i.address + k in f.insns for i in path for k in range(1, i.size)
                ):
                    ok = True
                    for ins in path:
                        if f.inside(ins.address):
                            f.insns.setdefault(ins.address, ins)
            if ok:
                f.entries.add(p)
                changed.add(f)
                rejected.discard(p)
            else:
                rejected.add(p)
        for f in changed:
            decode_func(img, f)
        forced = set()
        for f in funcs:
            for t in f.out:
                g = owner(t)
                if g is not None and t not in g.entries:
                    forced.add(t)
        cands = imm_pointers(changed)
    funcs = [f for f in funcs if f.insns]
    return funcs, len(rejected)


# ---------------------------------------------------------------- flags

def shift_count(ins):
    op = ins.operands[1] if len(ins.operands) > 1 else None
    if op is None:
        return 1
    if op.type == X86_OP_IMM:
        return op.imm & 31
    return None  # cl


def flag_effect(ins):
    """(uses, defs) flag masks of one instruction."""
    m = ins.mnemonic
    base = m.split()[-1]
    if m in JCC:
        return COND[JCC[m]][0], 0
    if m in SETCC:
        return COND[SETCC[m]][0], 0
    if base in ("add", "sub", "cmp", "neg", "and", "or", "xor", "test", "imul", "mul", "div", "idiv", "popfd", "xadd"):
        return 0, ALL
    if base in ("adc", "sbb"):
        return CF, ALL
    if base in ("inc", "dec"):
        return 0, ALL & ~CF
    if base in ("shl", "sal", "shr", "sar", "shld", "shrd"):
        n = shift_count(ins) if base not in ("shld", "shrd") else (ins.operands[2].imm & 31 if ins.operands[2].type == X86_OP_IMM else None)
        # A count in cl may be 0, which leaves every flag unchanged: the flags
        # are a may-def, so they neither read nor kill (live-in = live-out).
        if n == 0 or n is None:
            return 0, 0
        return 0, ALL
    if base in ("rol", "ror"):
        n = shift_count(ins)
        if n == 0 or n is None:
            return 0, 0
        return 0, CF | OF
    if base in ("rcl", "rcr"):
        n = shift_count(ins)
        if n == 0:
            return 0, 0
        return CF, (0 if n is None else CF | OF)
    if base in ("bt", "bts", "btr", "btc"):
        return 0, CF
    if base == "sahf":
        return 0, ALL & ~OF
    if base == "lahf":
        return ALL & ~OF, 0
    if base == "pushfd":
        return ALL, 0
    if base in ("cmpsb", "cmpsw", "cmpsd", "scasb", "scasw", "scasd") and ins.operands:
        return (ALL if m.startswith("rep") else 0), ALL
    if base in ("fucomi", "fcomi", "fucomip", "fcomip", "ucomiss", "comiss", "ucomisd", "comisd"):
        return 0, ALL
    if base in ("clc", "stc"):
        return 0, CF
    if base == "cmc":
        return CF, CF
    if base in ("call",):
        return 0, ALL
    return 0, 0


def exits(f, p, ins):
    """Targets outside f that control leaves to after p (tail calls)."""
    kind, t = control(None, ins)
    if kind in ("jmp", "jcc") and not f.inside(t):
        yield t
    for e in f.tables.get(p, ()):
        if not f.inside(e):
            yield e
    nxt = p + ins.size
    if kind not in ("jmp", "ijmp", "ret") and ins.mnemonic not in ("int3", "ud2") and not f.inside(nxt):
        yield nxt


def flow(f, effect):
    """Per instruction of f in address order: (pc, kind, target, exits, use,
    def), with effect(f, p, ins) -> (use, def)."""
    out = []
    for p in sorted(p for p, i in f.insns.items() if i is not None):
        ins = f.insns[p]
        kind, t = control(None, ins)
        out.append((p, kind, t, tuple(exits(f, p, ins))) + tuple(effect(f, p, ins)))
    return out


def liveness(f, fl, entry_live, ret_live, unknown, keeps, hidden):
    """(live_in, live_out) bits of each instruction. fl: flow(f); entry_live:
    entry address -> bits read at entry; ret_live: f.start -> bits live at
    ret; unknown: bits read by a transfer to an address that is no entry;
    keeps(t): bits a tail transfer to t leaves as they were, so those live at
    f's ret are live at the transfer; hidden(t): bits of entry_live[t] that
    are no read of the caller's value."""
    order = [x[0] for x in fl]
    live_in = {p: 0 for p in order}
    eff, extra = {}, {}
    rl = ret_live.get(f.start, 0)
    for p, kind, t, ex, u, d in fl:
        if kind == "call":
            u |= entry_live.get(t, unknown) & ~hidden(t)
        x = rl if kind == "ret" else 0
        for t in ex:
            x |= entry_live.get(t, unknown) & ~hidden(t) | (rl & keeps(t))
        eff[p], extra[p] = (u, d), x
    for _ in range(len(order) + 2):
        changed = False
        for p in reversed(order):
            out = extra[p]
            for s in f.succ.get(p, ()):
                out |= live_in.get(s, 0)
            u, d = eff[p]
            v = u | (out & ~d)
            if v != live_in[p]:
                live_in[p] = v
                changed = True
        if not changed:
            break
    else:
        raise RuntimeError("liveness did not converge in %08x" % f.start)
    live_out = {}
    for p in order:
        out = extra[p]
        for s in f.succ.get(p, ()):
            out |= live_in.get(s, 0)
        live_out[p] = out
    return live_in, live_out


def reg_liveness(funcs, effect, unknown=0, keeps=lambda t: 0, ret_init=None, hidden=lambda t: 0):
    """Interprocedural fixpoint of liveness(). Returns (entry_live, ret_live,
    live_out by f.start). ret_init: f.start -> bits live at ret whatever the
    known callers read."""
    owner = {e: f for f in funcs for e in f.entries}
    entry_live = {e: 0 for e in owner}
    ret_live = dict(ret_init or {})
    lives = {}
    deps = defaultdict(set)  # function -> functions to revisit when it changes
    fls = {f.start: flow(f, effect) for f in funcs}
    for f in funcs:
        for p, kind, t, ex, _, _ in fls[f.start]:
            for g in ([owner.get(t)] if kind == "call" else []) + [owner.get(x) for x in ex]:
                if g is not None:
                    deps[g.start].add(f)   # f reads g's entry bits
                    deps[f.start].add(g)   # g's returns serve f's call/tail
    work, queued = list(funcs), {f.start for f in funcs}
    for _ in range(64 * len(funcs) + 1):
        if not work:
            break
        f = work.pop()
        queued.discard(f.start)
        live_in, live_out = liveness(f, fls[f.start], entry_live, ret_live, unknown, keeps, hidden)
        lives[f.start] = live_out
        touched = set()
        for e in f.entries:
            v = live_in.get(e, 0)
            if v != entry_live[e]:
                entry_live[e] = v
                touched.add(f.start)
        for p, kind, t, ex, _, _ in fls[f.start]:
            outs = [(t, live_out[p])] if kind == "call" else []
            outs += [(x, ret_live.get(f.start, 0)) for x in ex]
            for t, v in outs:
                g = owner.get(t)
                v &= ~keeps(t)
                if g is not None and v & ~ret_live.get(g.start, 0):
                    ret_live[g.start] = ret_live.get(g.start, 0) | v
                    touched.add(g.start)
                    if g.start not in queued:
                        work.append(g); queued.add(g.start)
        for k in touched:
            for g in deps[k]:
                if g.start not in queued:
                    work.append(g); queued.add(g.start)
    else:
        raise RuntimeError("liveness did not converge")
    return entry_live, ret_live, lives


def flag_liveness(funcs):
    """Sets f.live (flags live after each pc); returns (entry_live, ret_live)."""
    entry_live, ret_live, lives = reg_liveness(funcs, lambda f, p, ins: flag_effect(ins))
    for f in funcs:
        f.live = lives.get(f.start, {})
    return entry_live, ret_live


def check_indirect_calls(img, funcs):
    """Indirect calls are modeled as passing no flags back. Fail if any code
    after one reads a flag before writing it (docs/recompiler.md §3)."""
    for f in funcs:
        for p, ins in f.insns.items():
            if ins is not None and control(img, ins)[0] == "icall" and f.live.get(p, 0):
                raise RuntimeError("flags %x read after indirect call at %08x" % (f.live[p], p))


# ---------------------------------------------------------------- registers

# Register liveness decides which promoted registers a call or return must
# store to x86.cpu, and which a call must reload. A direct call stores what
# the callee reads at entry and reloads what it, or anything it calls, may
# write; a return stores what a caller reads after it. Bits follow R32.
# WHY: docs/recompiler.md §2
ALL_GPR = 0xFF
GPR_BIT = {}  # register name -> (bit, whether it names all 32 bits)
for _k, _r in enumerate(R32):
    GPR_BIT[_r] = (1 << _k, True)
for _n, _r in list(R16.items()) + list(R8L.items()) + list(R8H.items()):
    GPR_BIT[_n] = (1 << R32.index(_r), False)
# Writes that may leave the old value in place, so the destination is a use.
MAY_WRITE = ("bsf", "bsr", "cmpxchg")
# Writes whose result does not depend on the register's old value: `xor r, r`,
# `sub r, r`, `sbb r, r` (0 or -1 from CF), `and r, 0`, `or r, -1`. Values are
# the immediate of the immediate forms.
SELF_IDIOM = {"xor": None, "sub": None, "sbb": None, "and": 0, "or": 0xFFFFFFFF}
# Accesses capstone does not report.
GPR_FIX = {"cmpxchg": (1, 1), "xlatb": (1 | 8, 1), "enter": (16 | 32, 16 | 32)}


_gpr_effect = {}  # address -> gpr_effect


def gpr_effect(ins):
    """(use, def, mod) GPR bits: read, always overwritten, possibly written."""
    v = _gpr_effect.get(ins.address)
    if v is not None:
        return v
    r, w = ins.regs_access()
    w = {ins.reg_name(x) for x in w}
    # capstone leaves some operand reads out (`test [m], al`): an operand
    # register it does not list as written is read.
    r = {ins.reg_name(x) for x in r}
    for op in ins.operands:
        if op.type == X86_OP_REG and ins.reg_name(op.reg) not in w:
            r.add(ins.reg_name(op.reg))
        elif op.type == X86_OP_MEM:
            r.update(ins.reg_name(x) for x in (op.mem.base, op.mem.index) if x)
    m = ins.mnemonic
    base = m.split()[-1]
    may = m.startswith(("rep", "cmov")) or base in MAY_WRITE
    use = kill = mod = 0
    for n in r:
        b = GPR_BIT.get(n)
        if b:
            use |= b[0]
    for n in w:
        b = GPR_BIT.get(n)
        if b:
            mod |= b[0]
            if b[1] and not may:
                kill |= b[0]
            else:
                use |= b[0]
    ops = ins.operands
    if base in SELF_IDIOM and len(ops) == 2 and ops[0].type == X86_OP_REG and (
            ops[1].type == X86_OP_REG and ops[1].reg == ops[0].reg and base in ("xor", "sub", "sbb")
            or ops[1].type == X86_OP_IMM and SELF_IDIOM[base] == ops[1].imm & 0xFFFFFFFF):
        b = GPR_BIT.get(ins.reg_name(ops[0].reg))
        if b and b[1]:
            use &= ~b[0]
    fu, fm = GPR_FIX.get(base, (0, 0))
    v = _gpr_effect[ins.address] = (use | fu, kill, mod | fm)
    return v


def check_gpr_effect(ins, st):
    """Fail if the lifted lines st of ins name a GPR gpr_effect misses."""
    u, _, m = gpr_effect(ins)
    for l in st:
        for r in REG_REF.findall(l):
            if r in R32 and not GPR_BIT[r][0] & (u | m):
                raise RuntimeError("%08x %s %s: lift names %s" % (ins.address, ins.mnemonic, ins.op_str, r))


def unknown_jump(f, p, kind):
    return kind == "icall" or kind == "ijmp" and p not in f.tables


def gpr_mod(funcs):
    """f.start -> GPR bits f, or anything it calls or tail-jumps to, may write."""
    owner = {e: f for f in funcs for e in f.entries}
    mod, callers = {}, defaultdict(set)
    for f in funcs:
        m = 0
        for p, ins in f.insns.items():
            if ins is None:
                continue
            m |= gpr_effect(ins)[2]
            kind, t = control(None, ins)
            if unknown_jump(f, p, kind):
                m = ALL_GPR
            for t in ([t] if kind == "call" else []) + list(exits(f, p, ins)):
                g = owner.get(t)
                if g is None:
                    m = ALL_GPR
                elif g is not f:
                    callers[g.start].add(f.start)
        mod[f.start] = m
    work = list(mod)
    for _ in range(9 * len(funcs) + 1):
        if not work:
            break
        g = work.pop()
        for a in callers[g]:
            v = mod[a] | mod[g]
            if v != mod[a]:
                mod[a] = v
                work.append(a)
    else:
        raise RuntimeError("register mod sets did not converge")
    return mod


def taken_entries(img, funcs):
    """Entries other code may reach without a direct call or jump, so a caller
    the analysis does not see may read any register after they return: the
    program entry, any entry whose address is a 32-bit word anywhere in the
    image (function pointers, vtables, immediates), and any entry no direct
    transfer reaches."""
    entries = {e for f in funcs for e in f.entries}
    hit = set()
    for k in range(4):
        n = (len(img.data) - k) // 4
        hit |= entries.intersection(struct.unpack_from("<%dI" % n, img.data, k))
    direct = set()
    for f in funcs:
        for p, ins in f.insns.items():
            if ins is None:
                continue
            kind, t = control(None, ins)
            if kind in ("call", "jmp", "jcc"):
                direct.add(t)
            direct.update(exits(f, p, ins))
    return hit | {OEP} | (entries - direct)


def gpr_liveness(img, funcs, mod, transp):
    """(entry_live, ret_live, functions with a taken entry) in GPR bits;
    entry_live by entry address, ret_live by f.start. mod: gpr_mod(funcs);
    transp: entry -> bits it is transparent in."""
    owner = {e: f for f in funcs for e in f.entries}
    taken = taken_entries(img, funcs)

    def keeps(t):
        g = owner.get(t)
        return 0 if g is None else ALL_GPR & ~mod[g.start] | transp.get(t, 0)

    def effect(f, p, ins):
        u, d, _ = gpr_effect(ins)
        kind, t = control(None, ins)
        if kind == "call":
            return u, ALL_GPR & ~keeps(t)
        if unknown_jump(f, p, kind):
            return ALL_GPR, 0
        return u, d

    ret_init = {f.start: ALL_GPR for f in funcs if f.entries & taken}
    entry_live, ret_live, _ = reg_liveness(funcs, effect, ALL_GPR, keeps, ret_init,
                                           lambda t: transp.get(t, 0))
    return entry_live, ret_live, len(ret_init)


# ---------------------------------------------------------------- saved registers

# A register an entry saves and restores, reading its entry value only to save
# it, is transparent: a direct call to that entry neither stores nor reloads
# it. An abstract interpretation per entry follows each entry value through
# registers and stack slots at known esp offsets. WHY: docs/recompiler.md §2
ESP, EBP = R32.index("esp"), R32.index("ebp")
SAVED = ALL_GPR & ~(1 << ESP)
NONE = (None, 0)  # (exact value, entry values it may hold) of an unknown word
INLINE_MAX = 32   # instructions of a straight-line callee interpreted in place
ARG_POP_MAX = 64  # bytes of arguments an indirect callee may pop
# Registers a host function may read or write: the guest ABI's scratch ones.
# Host code changes no other register; control.odin restores the whole cpu.
HOST_REGS = 0x7  # eax, ecx, edx
HLE_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "port", "src", "win32")
FIXED_STEP = {"pushfd": -4, "popfd": 4, "pushal": -32, "popal": 32, "pushad": -32, "popad": 32}


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >> 31 else v


def reg_index(ins, op):
    """R32 index of a 32-bit register operand, else None."""
    if op.type != X86_OP_REG:
        return None
    n = ins.reg_name(op.reg)
    return R32.index(n) if n in R32 else None


def esp_step(ins):
    """How ins moves esp, calls and returns aside: an int delta, ("reg", k, d)
    for esp = R32[k] + d, ("leave",), or None when unknown."""
    m, ops = ins.mnemonic, ins.operands
    if m == "push":
        return -ops[0].size
    if m == "pop":
        return None if reg_index(ins, ops[0]) == ESP else ops[0].size
    if m in FIXED_STEP:
        return FIXED_STEP[m]
    if m == "leave":
        return ("leave",)
    if not gpr_effect(ins)[2] & (1 << ESP):
        return 0
    if not ops or reg_index(ins, ops[0]) != ESP:
        return None
    if m in ("add", "sub") and ops[1].type == X86_OP_IMM:
        return s32(ops[1].imm) * (1 if m == "add" else -1)
    if m == "mov" and reg_index(ins, ops[1]) is not None:
        return ("reg", reg_index(ins, ops[1]), 0)
    if m == "lea" and ops[1].mem.index == 0 and ops[1].mem.segment == 0 and ops[1].mem.base:
        k = R32.index(ins.reg_name(ops[1].mem.base))
        return ("reg", k, s32(ops[1].mem.disp))
    return None


def host_pops(img, src=HLE_SRC):
    """IAT slot -> bytes of arguments its HLE proc pops, for procs whose
    every `ret(n, v)` in port/src/win32 has the same literal n. A proc with
    no such ret, or with differing ones, is left out."""
    table, bodies = {}, {}
    for name in sorted(os.listdir(src)):
        if not name.endswith(".odin"):
            continue
        lines = open(os.path.join(src, name)).read().split("\n")
        for m in re.finditer(r'\{"([a-z0-9_.]+![^"]+)", *([A-Za-z0-9_]+)\}', "\n".join(lines)):
            table[m.group(1)] = m.group(2)
        cur = None
        for line in lines:
            m = re.match(r"([A-Za-z0-9_]+) :: proc\(\)", line)
            if m:
                cur = m.group(1)
                bodies[cur] = []
            if cur is not None:
                bodies[cur].append(line)
                if line == "}" or m and line.rstrip().endswith("}"):
                    cur = None
    pops = {}
    for a, imp in img.iat.items():
        body = "\n".join(bodies.get(table.get(imp), ()))
        ns = set(re.findall(r"\bret\(([^,]+),", body))
        if len(ns) == 1 and ns.copy().pop().strip().isdigit():
            pops[a] = 4 * int(ns.pop())
    return pops


def host_slot(ins, op, o, regs, host):
    """IAT slot a call operand reaches when host_pops() knows it, else None:
    `call [slot]`, or `call r` with r loaded from one."""
    if op.type == X86_OP_MEM:
        mem = op.mem
        a = mem.disp & 0xFFFFFFFF if not (mem.base or mem.index or mem.segment) else None
    else:
        k = reg_index(ins, op)
        v = word(regs, o, k)[0] if k is not None else None
        a = v[1] if v is not None and v[0] == "M" else None
    return a if a in host else None


def word(regs, o, k):
    """Value of register k, esp as its stack offset."""
    if k == ESP:
        return (("S", o), 0) if o is not None else NONE
    return regs[k]


def mem_slot(ins, op, o, regs):
    """Stack offset a memory operand addresses, or None when not known."""
    mem = op.mem
    if mem.index or mem.segment or not mem.base:
        return None
    v = word(regs, o, R32.index(ins.reg_name(mem.base)))[0]
    return v[1] + s32(mem.disp) if v is not None and v[0] == "S" else None


def drop_slots(slots, a, size):
    """Taint of the slots [a, a + size) overlaps; removes them."""
    t = 0
    for k in [k for k in slots if a < k + 4 and k < a + size]:
        t |= slots.pop(k)[1]
    return t


def restored(regs):
    return sum(1 << k for k in range(8) if regs[k][0] == ("E", k))


def escaped(regs, slots):
    """Entry values the caller sees again on leaving with esp at its entry
    value: copies in other registers, `mov eax, ecx`, or in the caller's
    stack words. A register whose value escapes this way is read, not only
    saved, so it cannot be transparent."""
    t = 0
    for k in range(8):
        if k != ESP and regs[k][0] != ("E", k):
            t |= regs[k][1]
    for a, v in slots.items():
        if a >= 0:
            t |= v[1]
    return t


class Frames:
    """Inputs of the per-entry analysis: callee facts by entry address."""

    def __init__(self, owner, entry0, mod, pops, taken, host):
        self.owner = owner
        self.entry0 = entry0                       # GPR bits read at entry
        self.mod = mod                             # by f.start
        self.pops = dict(pops)                     # entry -> ret imm, or None
        self.transp = {e: SAVED for e in owner}    # entry -> transparent bits
        self.taken = taken                         # entries indirect transfers reach
        self.ind_seen = self.ind_kill = HOST_REGS  # of indirect transfers
        self.inline = {}                           # entry -> straight_line() body
        self.inline_step = {}                      # entry -> its esp delta, or None
        self.noreturn = set()                      # no_return() entries
        self.host = host                           # IAT slot -> host_pops()

    def seen(self, t):
        """Registers entry t may read or change, its transparent ones aside;
        t None: an indirect transfer, to a taken entry or the host."""
        if t is None:
            return self.ind_seen
        g = self.owner.get(t)
        if g is None:
            return ALL_GPR
        return (self.entry0[t] | self.mod[g.start]) & ~self.transp[t]

    def kill(self, t):
        """Registers a call to t, or an indirect one for None, may change."""
        if t is None:
            return self.ind_kill
        g = self.owner.get(t)
        return ALL_GPR if g is None else self.mod[g.start] & ~self.transp[t]

    def add_taken(self, e):
        """Folds taken entry e into the indirect sets; True if they grew."""
        s = self.ind_seen | self.seen(e) & SAVED
        k = self.ind_kill | self.kill(e) & SAVED
        grew = (s, k) != (self.ind_seen, self.ind_kill)
        self.ind_seen, self.ind_kill = s, k
        return grew


def no_return(funcs, owner):
    """Entries from which no path reaches a ret or an unknown indirect jump:
    every path ends at an instruction without successors (int3, ud2) or
    leaves only by tail jumps to, or calls of, such entries. Greatest
    fixpoint, so mutually tail-jumping entries qualify together."""
    nr = set(owner)
    for _ in range(len(owner) + 1):
        drop = {e for e in nr if not ends_without_return(owner[e], e, owner, nr)}
        if not drop:
            return nr
        nr -= drop
    raise RuntimeError("no-return entries did not converge")


def ends_without_return(f, e, owner, nr):
    seen, work = {e}, [e]
    for _ in range(len(f.insns) + 1):
        if not work:
            return True
        p = work.pop()
        ins = f.insns.get(p)
        if ins is None:
            return False
        kind, t = control(None, ins)
        if kind == "ret" or kind == "ijmp" and unknown_jump(f, p, kind):
            return False
        if any(x not in nr for x in exits(f, p, ins)):
            return False
        if kind == "call" and t in nr:
            continue
        for s in f.succ.get(p, ()):
            if s not in seen:
                seen.add(s)
                work.append(s)
    raise RuntimeError("no-return walk did not converge at %08x" % e)


def straight_line(f):
    """Instructions of f from its start to its ret when that path has no
    branch, call or second entry and at most INLINE_MAX of them, else None."""
    if f.entries != {f.start}:
        return None
    body, p = [], f.start
    for _ in range(INLINE_MAX):
        ins = f.insns.get(p)
        if ins is None:
            return None
        body.append(ins)
        kind, _ = control(None, ins)
        if kind == "ret":
            return body
        succ = f.succ.get(p, ())
        if kind is not None or len(succ) != 1 or ins.mnemonic.startswith("rep") or ins.mnemonic in FIXED_STEP:
            return None
        p = next(iter(succ))
    return None


def inline_delta(body):
    """esp change of a call to body, or None when not a constant."""
    d = 0
    for ins in body[:-1]:
        st = esp_step(ins)
        if not isinstance(st, int):
            return None
        d += st
    ret = body[-1].operands
    return d + (ret[0].imm if ret else 0)


def step_inline(body, ret_pc, o, regs, slots):
    """(esp offset, regs, slots, entry values read) after a call to a
    straight-line body, interpreted in place. Its ret must pop ret_pc."""
    if o is None:
        return None, [NONE] * 8, {}, all_taint(slots) | sum(v[1] for v in regs)
    slots = dict(slots)
    drop_slots(slots, o - 4, 4)
    slots[o - 4] = (("A", ret_pc), 0)
    o, leak = o - 4, 0
    for ins in body[:-1]:
        o, regs, slots, lk = step_plain(ins, o, regs, slots)
        leak |= lk
        if o is None:
            return None, regs, slots, leak | all_taint(slots)
    if slots.get(o, NONE)[0] != ("A", ret_pc):
        return None, regs, slots, leak | all_taint(slots) | sum(v[1] for v in regs)
    del slots[o]
    ret = body[-1].operands
    return o + 4 + (ret[0].imm if ret else 0), regs, slots, leak


def ret_pops(funcs, owner):
    """f.start -> bytes past the return address its returns pop, or None when
    they, or those of functions it tail-jumps to, disagree or are unknown."""
    pops, tails = {}, {}
    for f in funcs:
        v, t = set(), set()
        for p, ins in f.insns.items():
            if ins is None:
                continue
            kind, _ = control(None, ins)
            if kind == "ret":
                v.add(ins.operands[0].imm if ins.operands else 0)
            elif kind == "ijmp" and unknown_jump(f, p, kind):
                v.add(None)
            for x in exits(f, p, ins):
                g = owner.get(x)
                if g is None:
                    v.add(None)
                else:
                    t.add(g.start)
        pops[f.start], tails[f.start] = v, t
    for _ in range(len(funcs) + 1):
        changed = False
        for k, t in tails.items():
            for g in t:
                if not pops[g] <= pops[k]:
                    pops[k] |= pops[g]
                    changed = True
        if not changed:
            break
    else:
        raise RuntimeError("return pops did not converge")
    return {k: next(iter(v)) if len(v) == 1 else None for k, v in pops.items()}


def back_offsets(f, ctx):
    """pc -> esp offset before pc, where known esp steps lead from pc to a
    return or tail jump, given that f leaves esp at each as it found it."""
    pcs = sorted(p for p, i in f.insns.items() if i is not None)
    off, step = {}, {}
    for p in pcs:
        ins = f.insns[p]
        kind, t = control(None, ins)
        if kind == "call" and t in ctx.noreturn:
            s = None
        elif kind == "call":
            s = ctx.inline_step[t] if t in ctx.inline else ctx.pops.get(t)
        elif kind == "icall":
            s = ctx.host.get(host_slot(ins, ins.operands[0], None, [NONE] * 8, ctx.host))
        else:
            s = esp_step(ins)
            s = s if isinstance(s, int) else None
        step[p] = s
        ex = tuple(x for x in exits(f, p, ins) if x not in ctx.noreturn)
        if kind == "ret" or ex and kind in ("jmp", "jcc", "ijmp"):
            off[p] = 0
        elif ex and s is not None:
            off[p] = -s
    for _ in range(len(pcs) + 1):
        changed = False
        for p in reversed(pcs):
            if p in off or step[p] is None:
                continue
            vs = {off[s] for s in f.succ.get(p, ()) if s in off}
            if len(vs) == 1:
                off[p] = vs.pop() - step[p]
                changed = True
        if not changed:
            break
    return off


def step_plain(ins, o, regs, slots):
    """(esp offset, regs, slots, entry values read) after an instruction
    that is no call or return."""
    m, ops = ins.mnemonic, ins.operands
    if m == "lea" and not ops[1].mem.index and not ops[1].mem.disp and ops[1].mem.base == ops[0].reg:
        return o, regs, slots, 0  # `lea r, [r]`: a multi-byte nop
    use, _, md = gpr_effect(ins)
    slots = dict(slots)
    dst = reg_index(ins, ops[0]) if ops else None
    src = reg_index(ins, ops[-1]) if ops and m in ("push", "mov") else None
    to_slot = mem_slot(ins, ops[0], o, regs) if ops and ops[0].type == X86_OP_MEM else None
    if src is not None and not (m == "push" and o is not None or m == "mov" and (dst is not None or to_slot is not None)):
        src = None  # stores an entry value where it is not followed
    leak = 0
    for k in range(8):
        if use >> k & 1 and k != src:
            leak |= word(regs, o, k)[1]
    loaded = NONE
    for op in ops:
        if op.type != X86_OP_MEM or m == "lea" or not op.access & CS_AC_READ:
            continue
        a = mem_slot(ins, op, o, regs)
        if a is None:
            continue
        hit = 0
        for k, v in slots.items():
            if a < k + 4 and k < a + op.size:
                hit |= v[1]
        if m in ("push", "mov") and op.size == 4 and (m == "push" or dst is not None):
            loaded = slots.get(a, (None, hit))
        else:
            leak |= hit
    st = esp_step(ins)
    new = [NONE if md >> k & 1 and k != ESP else regs[k] for k in range(8)]
    if st is None:
        o2 = None
    elif isinstance(st, int):
        o2 = None if o is None else o + st
    elif st[0] == "reg":
        v = word(regs, o, st[1])[0]
        o2 = v[1] + st[2] if v is not None and v[0] == "S" else None
    else:  # leave
        v = regs[EBP][0]
        o2 = v[1] + 4 if v is not None and v[0] == "S" else None
        new[EBP] = slots.get(v[1], NONE) if o2 is not None else (None, all_taint(slots))
    if st is None and m in ("add", "sub") and dst == ESP and o is not None:
        v = word(regs, o, reg_index(ins, ops[1]))[0] if reg_index(ins, ops[1]) is not None else None
        if v is not None and v[0] == "C":
            o2 = o + s32(v[1]) * (1 if m == "add" else -1)  # `sub esp, eax` with eax known
    if m == "mov" and dst is not None and ops[1].type == X86_OP_IMM:
        new[dst] = (("C", ops[1].imm & 0xFFFFFFFF), 0)
    elif m == "mov" and dst is not None and src is None and absolute(ops[1]):
        new[dst] = (("M", ops[1].mem.disp & 0xFFFFFFFF), 0)  # host_slot() resolves IAT loads
    elif m == "mov" and dst is not None:
        new[dst] = word(regs, o, src) if src is not None else loaded
    elif m == "lea" and dst is not None:
        a = mem_slot(ins, ops[1], o, regs)
        new[dst] = (("S", a), 0) if a is not None else NONE
    elif m == "pop" and dst is not None:
        new[dst] = slots.get(o, NONE) if o is not None else (None, all_taint(slots))
    for op in ops:
        if op.type == X86_OP_MEM and op.access & CS_AC_WRITE:
            a = mem_slot(ins, op, o, regs) if m != "pop" else None
            if m == "pop":
                leak |= all_taint(slots)
                slots = {}
            elif a is not None:
                drop_slots(slots, a, op.size)
    if m == "mov" and to_slot is not None and src is not None:
        slots[to_slot] = word(regs, o, src)
    if m in ("push",) + tuple(k for k in FIXED_STEP if k.startswith("push")) and o is not None:
        drop_slots(slots, o + st, -st)
        if m == "push" and ops[0].size == 4 and ops[0].type == X86_OP_IMM:
            slots[o - 4] = (("C", ops[0].imm & 0xFFFFFFFF), 0)
        elif m == "push" and ops[0].size == 4:
            slots[o - 4] = word(regs, o, src) if src is not None else loaded
    elif m == "push":
        leak |= loaded[1]
    return o2, new, slots, leak


def absolute(op):
    """A dword memory operand at a constant address."""
    mem = op.mem
    return op.type == X86_OP_MEM and op.size == 4 and not (mem.base or mem.index or mem.segment)


def all_taint(slots):
    t = 0
    for v in slots.values():
        t |= v[1]
    return t


def step_call(kind, t, o, regs, slots, ctx, back_next, slot):
    """(esp offset, regs, slots, entry values the callee may read) after a
    call; back_next: back_offsets at the return address; slot: host_slot()
    of an indirect call."""
    direct = kind == "call" and t in ctx.owner
    tgt = t if kind == "call" else None
    seen = HOST_REGS if slot is not None else ctx.seen(tgt)
    leak = 0
    for k in range(8):
        if seen >> k & 1 and k != ESP:
            leak |= regs[k][1]
    kill = HOST_REGS if slot is not None else ctx.kill(tgt)
    regs = [NONE if kill >> k & 1 else regs[k] for k in range(8)]
    if o is not None:
        slots = {k: v for k, v in slots.items() if k >= o}
    pops = ctx.pops.get(t) if direct else ctx.host.get(slot)
    if o is not None and pops is not None:
        o2 = o + pops
    elif o is not None and back_next is not None and 0 <= back_next - o <= ARG_POP_MAX and (back_next - o) % 4 == 0:
        o2 = back_next
    else:
        o2 = None
    return o2, regs, slots, leak


def check_exits(ex, o, regs, slots, ctx):
    """(failed bits, balanced) of tail jumps to ex in the given state; an
    exit None is an indirect one."""
    fail, bal = 0, True
    for x in ex:
        if x in ctx.noreturn:
            continue
        if x is not None and x not in ctx.owner or o != 0:
            return SAVED, False
        seen = ctx.seen(x)
        for k in range(8):
            if seen >> k & 1 and k != ESP:
                fail |= regs[k][1]
        fail |= SAVED & ~(restored(regs) & ~seen) | escaped(regs, slots)
        bal = bal and ctx.pops.get(x) is not None
    return fail, bal


def frame_step(f, p, ins, st, ctx, back):
    """(state after ins or None, failed bits, balanced)."""
    o, regs, slots = st
    kind, t = control(None, ins)
    if kind == "ret":
        return None, (SAVED if o != 0 else SAVED & ~restored(regs) | escaped(regs, slots)), o == 0
    if kind == "ijmp" and unknown_jump(f, p, kind):
        o2, regs2, slots2, leak = step_plain(ins, o, regs, slots)
        fail, _ = check_exits((None,), o2, regs2, slots2, ctx)
        return None, leak | fail, False
    if kind == "call" and t in ctx.noreturn:
        return None, 0, True
    if kind == "call" and t in ctx.inline:
        o2, regs2, slots2, leak = step_inline(ctx.inline[t], p + ins.size, o, regs, slots)
    elif kind in ("call", "icall"):
        slot = host_slot(ins, ins.operands[0], o, regs, ctx.host) if kind == "icall" else None
        o2, regs2, slots2, leak = step_call(kind, t, o, regs, slots, ctx, back.get(p + ins.size), slot)
    else:
        o2, regs2, slots2, leak = step_plain(ins, o, regs, slots)
    for s in f.succ.get(p, ()):
        b = back.get(s)
        if o2 is not None and b is not None and b != o2:
            return None, SAVED, False
    fail, bal = check_exits(tuple(exits(f, p, ins)), o2, regs2, slots2, ctx)
    return (o2, regs2, slots2), leak | fail, bal


def join_frames(a, b):
    def join(x, y):
        return (x[0] if x[0] == y[0] else None, x[1] | y[1])
    slots = {}
    for k in a[2].keys() | b[2].keys():
        v = join(a[2].get(k, NONE), b[2].get(k, NONE))
        if v != NONE:
            slots[k] = v
    return (a[0] if a[0] == b[0] else None, [join(x, y) for x, y in zip(a[1], b[1])], slots)


def saved_at(f, e, ctx, back):
    """(transparent bits, balanced) of entry e of f."""
    regs = [(("E", k), 1 << k) for k in range(8)]
    regs[ESP] = NONE
    states = {e: (0, regs, {})}
    work, fail, bal = [e], 0, True
    for _ in range(64 * len(f.insns) + 64):
        if not work:
            break
        p = work.pop()
        ins = f.insns.get(p)
        if ins is None:
            return 0, False
        out, ff, b = frame_step(f, p, ins, states[p], ctx, back)
        fail, bal = fail | ff, bal and b
        if fail == SAVED and not bal:
            return 0, False
        if out is None:
            continue
        for s in f.succ.get(p, ()):
            old = states.get(s)
            new = out if old is None else join_frames(old, out)
            if new != old:
                states[s] = new
                work.append(s)
    else:
        raise RuntimeError("frame analysis did not converge at %08x" % e)
    return SAVED & ~fail, bal


def transparency(funcs, entry0, mod, taken, host):
    """Entry -> GPR bits it is transparent in: a greatest fixpoint, since a
    call keeps a register's entry value only if the callee is transparent.
    taken: taken_entries(); host: host_pops()."""
    owner = {e: f for f in funcs for e in f.entries}
    rp = ret_pops(funcs, owner)
    init = {e: rp[f.start] for e, f in owner.items()}
    ctx = Frames(owner, entry0, mod, init, taken, host)
    ctx.noreturn = no_return(funcs, owner)
    for f in funcs:
        body = straight_line(f)
        if body is not None:
            ctx.inline[f.start], ctx.inline_step[f.start] = body, inline_delta(body)
    for e in taken:
        ctx.add_taken(e)
    users = defaultdict(set)  # entry -> f.start of functions calling or tail-jumping to it
    indirect = set()          # f.start of functions with an indirect transfer
    for f in funcs:
        for p, ins in f.insns.items():
            if ins is None:
                continue
            kind, t = control(None, ins)
            if kind == "icall" or unknown_jump(f, p, kind):
                indirect.add(f.start)
            for x in ([t] if kind == "call" else []) + list(exits(f, p, ins)):
                if x in owner:
                    users[x].add(f.start)
    byaddr = {f.start: f for f in funcs}
    work, queued = [f.start for f in funcs], {f.start for f in funcs}
    for _ in range(64 * len(funcs) + 1):
        if not work:
            break
        k = work.pop()
        queued.discard(k)
        f = byaddr[k]
        back = back_offsets(f, ctx)
        for e in f.entries:
            tr, bal = saved_at(f, e, ctx, back)
            tr &= ctx.transp[e]
            pops = ctx.pops[e] if bal else None
            if tr == ctx.transp[e] and pops == ctx.pops[e]:
                continue
            ctx.transp[e], ctx.pops[e] = tr, pops
            again = users[e] | (indirect if e in taken and ctx.add_taken(e) else set())
            for u in again:
                if u not in queued:
                    work.append(u)
                    queued.add(u)
    else:
        raise RuntimeError("transparency did not converge")
    return ctx.transp


# ---------------------------------------------------------------- operands

class Lift:
    """Odin statements for one instruction."""

    def __init__(self, img, ins, live, fs=None):
        self.img = img
        self.i = ins
        self.live = live
        self.fs = fs  # X87 run cache, or None for direct c.fpu access
        self.s = []
        self.frame_count = False  # FRAME_COUNTS immediate emitted (see imm)

    def imm(self, op, size):
        """Literal of immediate op; scaled by x86.frames when the
        instruction is in FRAME_COUNTS."""
        if self.i.address in FRAME_COUNTS:
            self.frame_count = True
            return "x86.frames(%s)" % lit(op.imm, size)
        return lit(op.imm, size)

    def reg(self, r):
        return self.i.reg_name(r)

    def ea(self, op):
        mem = op.mem
        parts = []
        if mem.segment != 0:
            seg = self.reg(mem.segment)
            if seg == "fs":
                parts.append("c.fs_base")
            elif seg not in ("ds", "es", "ss", "cs"):
                raise Unsupported("segment " + seg)
        if mem.base != 0:
            parts.append(self.r32(self.reg(mem.base)))
        if mem.index != 0:
            ix = self.r32(self.reg(mem.index))
            parts.append(ix if mem.scale == 1 else "%s * %d" % (ix, mem.scale))
        d = mem.disp & 0xFFFFFFFF
        if not parts:
            return hexu(d)
        e = " + ".join(parts)
        if d:
            e += " + 0x%x" % d if d < 0x80000000 else " - 0x%x" % ((-d) & 0xFFFFFFFF)
        return e

    def r32(self, name):
        if name not in R32:
            raise Unsupported("address reg " + name)
        return "c." + name

    def read(self, op, ea=None):
        size = op.size
        if op.type == X86_OP_REG:
            n = self.reg(op.reg)
            if n in R32:
                return "c." + n
            if n in R16:
                return "u16(c.%s)" % R16[n]
            if n in R8L:
                return "u8(c.%s)" % R8L[n]
            if n in R8H:
                return "u8(c.%s >> 8)" % R8H[n]
            raise Unsupported("reg " + n)
        if op.type == X86_OP_IMM:
            return self.imm(op, size)
        if op.type == X86_OP_MEM:
            return "x86.rd%d(%s)" % (size * 8, ea or self.ea(op))
        raise Unsupported("operand")

    def write(self, op, val, ea=None):
        if op.type == X86_OP_REG:
            n = self.reg(op.reg)
            if n in R32:
                return "c.%s = %s" % (n, val)
            if n in R16:
                r = R16[n]
                return "c.%s = (c.%s & 0xffff0000) | u32(%s)" % (r, r, val)
            if n in R8L:
                r = R8L[n]
                return "c.%s = (c.%s & 0xffffff00) | u32(%s)" % (r, r, val)
            if n in R8H:
                r = R8H[n]
                return "c.%s = (c.%s & 0xffff00ff) | (u32(%s) << 8)" % (r, r, val)
            raise Unsupported("reg " + n)
        if op.type == X86_OP_MEM:
            return "x86.wr%d(%s, %s)" % (op.size * 8, ea or self.ea(op), val)
        raise Unsupported("write operand")

    def rmw(self, op):
        """(read expr, writer fn) for a read-modify-write operand; computes EA once."""
        if op.type == X86_OP_MEM:
            self.s.append("ea := u32(%s)" % self.ea(op))
            return self.read(op, "ea"), (lambda v: self.write(op, v, "ea"))
        return self.read(op), (lambda v: self.write(op, v))

    # -- flags

    def flags_arith(self, kind, size, a, b, r, live, cin=None):
        """Store the live flags of an add/sub-family result."""
        T, sg = SIZE_T[size], SIGN[size]
        out = []
        if live & CF:
            if kind == "add":
                out.append("c.cf = %s < %s" % (r, a))
            elif kind == "sub":
                out.append("c.cf = %s < %s" % (a, b))
            elif kind == "adc":
                out.append("c.cf = %s ? %s <= %s : %s < %s" % (cin, r, a, r, a))
            elif kind == "sbb":
                out.append("c.cf = %s ? %s <= %s : %s < %s" % (cin, a, b, a, b))
            elif kind == "neg":
                out.append("c.cf = %s != 0" % a)
        if live & OF:
            if kind in ("add", "adc"):
                out.append("c.of = (~(%s ~ %s) & (%s ~ %s) & %s) != 0" % (a, b, a, r, sg))
            elif kind in ("sub", "sbb"):
                out.append("c.of = ((%s ~ %s) & (%s ~ %s) & %s) != 0" % (a, b, a, r, sg))
            elif kind == "neg":
                out.append("c.of = %s == %s" % (a, sg))
            elif kind == "inc":
                out.append("c.of = %s == %s" % (r, sg))
            elif kind == "dec":
                out.append("c.of = %s == %s - 1" % (r, sg))
        if live & AF:
            if kind == "neg":
                out.append("c.af = (%s & 0xf) != 0" % a)
            elif kind in ("inc", "dec"):
                out.append("c.af = (%s & 0xf) == %s" % (r, "0" if kind == "inc" else "0xf"))
            else:
                out.append("c.af = ((%s ~ %s ~ %s) & 0x10) != 0" % (a, b, r))
        out += self.flags_result(size, r, live)
        return out

    def flags_result(self, size, r, live):
        out = []
        if live & ZF:
            out.append("c.zf = %s == 0" % r)
        if live & SF:
            out.append("c.sf = (%s & %s) != 0" % (r, SIGN[size]))
        if live & PF:
            out.append("c.pf = x86.parity(u8(%s))" % r)
        return out

    def flags_logic(self, size, r, live):
        out = []
        if live & CF:
            out.append("c.cf = false")
        if live & OF:
            out.append("c.of = false")
        if live & AF:
            out.append("c.af = false")
        return out + self.flags_result(size, r, live)


# Fusable flag producers: their result or operands give the condition directly.
FUSE_ARITH = {"cmp", "sub"}
FUSE_LOGIC = {"test", "and", "or", "xor"}


def fused_cond(kind, cc, size, a, b, r):
    """Condition expression for flags of `kind` consumed by cc, or None."""
    st = STYPE.get(size)
    if kind == "arith":
        m = {"e": "%s == %s" % (a, b), "ne": "%s != %s" % (a, b),
             "b": "%s < %s" % (a, b), "ae": "%s >= %s" % (a, b),
             "be": "%s <= %s" % (a, b), "a": "%s > %s" % (a, b),
             "l": "%s(%s) < %s(%s)" % (st, a, st, b), "ge": "%s(%s) >= %s(%s)" % (st, a, st, b),
             "le": "%s(%s) <= %s(%s)" % (st, a, st, b), "g": "%s(%s) > %s(%s)" % (st, a, st, b),
             "s": "%s(%s) < 0" % (st, r), "ns": "%s(%s) >= 0" % (st, r)}
        return m.get(cc)
    m = {"e": "%s == 0" % r, "ne": "%s != 0" % r,
         "s": "%s(%s) < 0" % (st, r), "ns": "%s(%s) >= 0" % (st, r),
         "l": "%s(%s) < 0" % (st, r), "ge": "%s(%s) >= 0" % (st, r),
         "le": "%s(%s) <= 0" % (st, r), "g": "%s(%s) > 0" % (st, r),
         "b": "false", "ae": "true", "be": "%s == 0" % r, "a": "%s != 0" % r,
         "p": "x86.parity(u8(%s))" % r, "np": "!x86.parity(u8(%s))" % r}
    return m.get(cc)


# ---------------------------------------------------------------- x87

FARITH = ["fadd", "fmul", "fcom", "fcomp", "fsub", "fsubr", "fdiv", "fdivr"]


def fop(kind, a, b):
    return {"fadd": "%s + %s", "fmul": "%s * %s", "fsub": "%s - %s", "fsubr": "%s - %s",
            "fdiv": "%s / %s", "fdivr": "%s / %s"}[kind] % ((b, a) if kind in ("fsubr", "fdivr") else (a, b))


# x87 stack cache. The registers live in c.fpu, a global, and every guest
# store (wr32 and the like) may alias it as far as LLVM can tell, so each
# st(i), set_st and fpush reloaded top, the control word and the register.
# Within a run of instructions in one basic block, top moves by a known
# amount, so the run keeps the registers it touches in proc locals x87_0..7
# (physical register (x87t + j) & 7, x87t = top at the run's start) and writes
# back the changed registers, tags and top when the run ends: before any
# control transfer or call, at the block's end, and before an instruction
# that reads the whole x87 state (fxam, fprem, fnsave, frstor, fninit).
# fstsw reads only the status word and top, so it takes top from the run.
# WHY: docs/recompiler.md §4
class X87:
    def __init__(self):
        self.used = set()  # proc locals to declare
        self.reset()

    def reset(self):
        self.active = False
        self.dt = 0        # top minus x87t, mod 8
        self.val = {}      # j -> dirty, for each register held in x87_j
        self.tag = {}      # j -> True empty / False full, set by fpop / fpush
        self.single = False  # x87s holds the precision control test

    def begin(self, s):
        if not self.active:
            s.append("x87t = c.fpu.top")
            self.used.add("x87t: u32")
            self.active = True

    def key(self, i):
        return (self.dt + i) & 7

    def name(self, j):
        self.used.add("x87_%d: f64" % j)
        return "x87_%d" % j

    def st(self, s, i):
        self.begin(s)
        j = self.key(i)
        if j not in self.val:
            s.append("%s = x86.st_phys(x87t + %d)" % (self.name(j), j))
            self.val[j] = False
        return self.name(j)

    def set(self, s, i, expr, raw):
        self.begin(s)
        j = self.key(i)
        if not raw:
            if not self.single:
                s.append("x87s = c.fpu.cw & x86.PC_MASK == 0")
                self.used.add("x87s: bool")
                self.single = True
            expr = "x86.round_pc(x87s, %s)" % expr
        s.append("%s = %s" % (self.name(j), expr))
        self.val[j] = True

    def push(self, s, expr):
        self.begin(s)
        self.dt = (self.dt - 1) & 7
        j = self.key(0)
        s.append("%s = %s" % (self.name(j), expr))
        self.val[j] = True
        self.tag[j] = False

    def pop(self, s):
        self.begin(s)
        self.tag[self.key(0)] = True
        self.dt = (self.dt + 1) & 7

    def xch(self, s, i):
        a, b = self.st(s, 0), self.st(s, i)
        if a != b:
            s.append("%s, %s = %s, %s" % (a, b, b, a))
            self.val[self.key(0)] = self.val[self.key(i)] = True

    def sw(self):
        """fstsw's value: the status word with the run's top."""
        if not self.active:
            return "x86.fstsw()"
        return "(c.fpu.sw & ~u16(0x3800)) | u16(((x87t + %d) & 7) << 11)" % self.dt

    def flush(self, s):
        if not self.active:
            return
        # A register the run leaves empty keeps no value worth writing: the
        # guest cannot read it without first loading it again.
        for j in sorted(self.val):
            if self.val[j] and not self.tag.get(j, False):
                s.append("x86.set_st_phys(x87t + %d, %s)" % (j, self.name(j)))
        full = sum(1 << j for j, e in self.tag.items() if not e)
        empty = sum(1 << j for j, e in self.tag.items() if e)
        if self.tag:
            s.append("c.fpu.tag = (c.fpu.tag &~ x86.rot8(%s, x87t)) | x86.rot8(%s, x87t)"
                     % (hex(full | empty), hex(empty)))
        if self.dt:
            s.append("c.fpu.top = (x87t + %d) & 7" % self.dt)
        self.reset()


class X87Direct:
    """The same interface over c.fpu itself, for code outside a cached run."""

    def st(self, s, i):
        return "x86.st(%d)" % i

    def set(self, s, i, expr, raw):
        s.append("x86.%s(%d, %s)" % ("set_st_raw" if raw else "set_st", i, expr))

    def push(self, s, expr):
        s.append("x86.fpush(%s)" % expr)

    def pop(self, s):
        s.append("x86.fpop()")

    def xch(self, s, i):
        s.append("x86.fxch(%d)" % i)

    def sw(self):
        return "x86.fstsw()"

    def flush(self, s):
        pass


X87_DIRECT = X87Direct()


def lift_x87(L, ins):
    """x87 instructions, decoded from the opcode bytes (D8-DF + ModRM)."""
    b = bytes(ins.bytes)
    k = 0
    while b[k] in PREFIXES:
        k += 1
    op, modrm = b[k], b[k + 1]
    reg, rm = (modrm >> 3) & 7, modrm & 7
    s = L.s
    fs = L.fs or X87_DIRECT
    mem = modrm < 0xC0
    ea = None
    if mem:
        mops = [o for o in ins.operands if o.type == X86_OP_MEM]
        ea = L.ea(mops[0])

    def st(i):
        return fs.st(s, i)

    def set_st(i, expr):
        fs.set(s, i, expr, False)

    def set_raw(i, expr):
        fs.set(s, i, expr, True)

    def push(expr):
        fs.push(s, expr)

    def pop():
        fs.pop(s)

    def whole():
        """The instruction reads or writes the whole x87 state: write back first."""
        fs.flush(s)

    def ld(kind):
        return {"m32": "f64(transmute(f32)x86.rd32(%s))" % ea, "m64": "transmute(f64)x86.rd64(%s)" % ea,
                "i16": "f64(i16(x86.rd16(%s)))" % ea, "i32": "f64(i32(x86.rd32(%s)))" % ea,
                "i64": "f64(i64(x86.rd64(%s)))" % ea, "m80": "x86.ld80(%s)" % ea}[kind]

    def fcom(i, pops):
        s.append("x86.fcom(%s, %s)" % (st(0), st(i)))
        for _ in range(pops):
            pop()

    def arith(kind, src):
        if kind in ("fcom", "fcomp"):
            s.append("x86.fcom(%s, %s)" % (st(0), src))
            if kind == "fcomp":
                pop()
            return
        set_st(0, fop(kind, st(0), src))

    if op in (0xD8, 0xDC) and mem:
        arith(FARITH[reg], ld("m32" if op == 0xD8 else "m64"))
    elif op == 0xD8:
        arith(FARITH[reg], st(rm))
    elif op in (0xDA, 0xDE) and mem:
        src = ld("i32" if op == 0xDA else "i16")
        names = ["fadd", "fmul", "fcom", "fcomp", "fsub", "fsubr", "fdiv", "fdivr"]
        arith(names[reg], src)
    elif op in (0xDC, 0xDE):
        # st(i) = st(i) op st(0); register forms swap sub/subr and div/divr.
        if op == 0xDE and modrm == 0xD9:
            fcom(1, 2)
            return
        if reg in (2, 3):
            fcom(rm, 1 if reg == 3 or op == 0xDE else 0)
            return
        st0, sti = st(0), st(rm)
        expr = {0: "%s + %s" % (sti, st0), 1: "%s * %s" % (sti, st0), 4: "%s - %s" % (st0, sti),
                5: "%s - %s" % (sti, st0), 6: "%s / %s" % (st0, sti), 7: "%s / %s" % (sti, st0)}[reg]
        set_st(rm, expr)
        if op == 0xDE:
            pop()
    elif op == 0xD9 and mem:
        if reg == 0:
            push(ld("m32"))
        elif reg in (2, 3):
            s.append("x86.wr32(%s, transmute(u32)f32(%s))" % (ea, st(0)))
            if reg == 3:
                pop()
        elif reg == 5:
            s.append("x86.fldcw(x86.rd16(%s))" % ea)
            if L.fs:
                L.fs.single = False
        elif reg == 7:
            s.append("x86.wr16(%s, c.fpu.cw)" % ea)
        else:
            raise Unsupported("fldenv/fstenv")
    elif op == 0xD9:
        if reg == 0:
            push(st(rm))
        elif reg == 1:
            fs.xch(s, rm)
        elif modrm == 0xD0:
            pass
        elif modrm == 0xE0:
            set_st(0, "-%s" % st(0))
        elif modrm == 0xE1:
            set_st(0, "abs(%s)" % st(0))
        elif modrm == 0xE4:
            s.append("x86.fcom(%s, 0)" % st(0))
        elif modrm == 0xE5:
            whole()
            s.append("x86.fxam()")
        elif modrm in FCONST:
            push(FCONST[modrm])
        elif modrm == 0xF0:
            set_st(0, "math.pow(2, %s) - 1" % st(0))
        elif modrm == 0xF1:
            set_st(1, "%s * math.log2(%s)" % (st(1), st(0)))
            pop()
        elif modrm == 0xF2:
            set_st(0, "math.tan(%s)" % st(0))
            push("1")
        elif modrm == 0xF3:
            set_st(1, "math.atan2(%s, %s)" % (st(1), st(0)))
            pop()
        elif modrm in (0xF5, 0xF8):
            whole()
            s.append("x86.fprem()")
        elif modrm == 0xFA:
            set_st(0, "math.sqrt(%s)" % st(0))
        elif modrm == 0xFB:
            # fsincos: st(0) = sin, then cos pushed; the push lands in another
            # register, so it goes first and both read the old st(0).
            v = st(0)
            push("math.cos(%s)" % v)
            set_st(1, "math.sin(%s)" % v)
        elif modrm == 0xFC:
            set_st(0, "x86.round_cw(%s)" % st(0))
        elif modrm == 0xFD:
            set_st(0, "%s * math.pow(2, math.trunc(%s))" % (st(0), st(1)))
        elif modrm == 0xFE:
            set_st(0, "math.sin(%s)" % st(0))
        elif modrm == 0xFF:
            set_st(0, "math.cos(%s)" % st(0))
        else:
            raise Unsupported("x87 d9 %02x" % modrm)
    elif op == 0xDB and mem:
        if reg == 0:
            push(ld("i32"))
        elif reg in (2, 3):
            s.append("x86.wr32(%s, u32(x86.fist32(%s)))" % (ea, st(0)))
            if reg == 3:
                pop()
        elif reg == 1:
            s.append("x86.wr32(%s, u32(x86.fist32_trunc(%s)))" % (ea, st(0)))
            pop()
        elif reg == 5:
            push(ld("m80"))
        elif reg == 7:
            s.append("x86.st80(%s, %s)" % (ea, st(0)))
            pop()
        else:
            raise Unsupported("x87 db mem")
    elif op == 0xDB:
        if modrm == 0xE2:
            s.append("c.fpu.sw &= 0x7f00")
        elif modrm == 0xE3:
            whole()
            s.append("x86.fninit()")
        elif 0xE8 <= modrm < 0xF8:
            s.append("x86.fcomi(%s, %s)" % (st(0), st(rm)))
        else:
            raise Unsupported("x87 db %02x" % modrm)
    elif op == 0xDD and mem:
        if reg == 0:
            push(ld("m64"))
        elif reg in (2, 3):
            s.append("x86.wr64(%s, transmute(u64)%s)" % (ea, st(0)))
            if reg == 3:
                pop()
        elif reg == 1:
            s.append("x86.wr64(%s, u64(x86.fist64_trunc(%s)))" % (ea, st(0)))
            pop()
        elif reg == 7:
            s.append("x86.wr16(%s, %s)" % (ea, fs.sw()))
        elif reg == 6:
            whole()
            s.append("x86.fnsave(%s)" % ea)
        elif reg == 4:
            whole()
            s.append("x86.frstor(%s)" % ea)
        else:
            raise Unsupported("x87 dd mem")
    elif op == 0xDD:
        if reg == 0:
            pass  # ffree
        elif reg in (2, 3):
            set_raw(rm, st(0))
            if reg == 3:
                pop()
        elif reg in (4, 5):
            fcom(rm, 1 if reg == 5 else 0)
        else:
            raise Unsupported("x87 dd %02x" % modrm)
    elif op == 0xDA:
        if modrm == 0xE9:
            fcom(1, 2)
        else:
            raise Unsupported("fcmov")
    elif op == 0xDF and mem:
        if reg == 0:
            push(ld("i16"))
        elif reg in (2, 3):
            s.append("x86.wr16(%s, u16(x86.fist16(%s)))" % (ea, st(0)))
            if reg == 3:
                pop()
        elif reg == 5:
            push(ld("i64"))
        elif reg == 7:
            s.append("x86.wr64(%s, u64(x86.fist64(%s)))" % (ea, st(0)))
            pop()
        else:
            raise Unsupported("fbld/fbstp")
    elif op == 0xDF:
        if modrm == 0xE0:
            s.append("c.eax = (c.eax & 0xffff0000) | u32(%s)" % fs.sw())
        elif 0xE8 <= modrm < 0xF8:
            s.append("x86.fcomi(%s, %s)" % (st(0), st(rm)))
            pop()
        else:
            raise Unsupported("x87 df %02x" % modrm)
    else:
        raise Unsupported("x87 %02x" % op)


FCONST = {0xE8: "1", 0xE9: "math.LN10 / math.LN2", 0xEA: "1 / math.LN2", 0xEB: "math.PI",
          0xEC: "math.LN2 / math.LN10", 0xED: "math.LN2", 0xEE: "0"}


# ---------------------------------------------------------------- SSE

SSE_MXCSR = ("stmxcsr", "ldmxcsr")


def is_sse(L, ins):
    if ins.mnemonic in SSE_MXCSR:
        return True
    for op in ins.operands:
        if op.type == X86_OP_REG:
            n = L.reg(op.reg)
            if n.startswith("xmm"):
                return True
            if n.startswith("mm"):
                raise Unsupported("mmx")
    return False


def lift_sse(L, ins):
    """SSE/SSE2 subset over c.xmm (x86.Xmm raw unions)."""
    s = L.s
    m = ins.mnemonic
    ops = ins.operands

    def xr(op):
        return "c.xmm[%s]" % L.reg(op.reg)[3:]

    def isx(op):
        return op.type == X86_OP_REG and L.reg(op.reg).startswith("xmm")

    def v128(op):
        return xr(op) if isx(op) else "x86.rd128(%s)" % L.ea(op)

    def lane(op, field, k=0):
        # Scalar lane k of an xmm, or a scalar memory operand.
        if isx(op):
            return "%s.%s[%d]" % (xr(op), field, k)
        if field == "f":
            return "transmute(f32)x86.rd32(%s)" % L.ea(op)
        if field == "d":
            return "transmute(f64)x86.rd64(%s)" % L.ea(op)
        if field == "q":
            return "x86.rd64(%s)" % L.ea(op)
        return "x86.rd32(%s)" % L.ea(op)

    def store_lane(op, field, val):
        if isx(op):
            s.append("%s.%s[0] = %s" % (xr(op), field, val))
        else:
            n = {"f": 32, "u": 32, "d": 64, "q": 64}[field]
            cast = "transmute(u%d)" % n if field in "fd" else ""
            s.append("x86.wr%d(%s, %s(%s))" % (n, L.ea(op), cast, val))

    d, a = (ops + [None, None])[:2]
    if m in ("movaps", "movups", "movapd", "movupd", "movdqa", "movdqu"):
        if isx(d):
            s.append("%s = %s" % (xr(d), v128(a)))
        else:
            s.append("x86.wr128(%s, %s)" % (L.ea(d), xr(a)))
    elif m in ("movss", "movsd"):
        f = "f" if m == "movss" else "d"
        if isx(d) and isx(a):
            s.append("%s.%s[0] = %s.%s[0]" % (xr(d), f, xr(a), f))
        elif isx(d):
            s.append("{ v := %s; %s = {}; %s.%s[0] = v }" % (lane(a, f), xr(d), xr(d), f))
        else:
            store_lane(d, f, lane(a, f))
    elif m == "movd":
        if isx(d):
            s.append("{ v := %s; %s = {}; %s.u[0] = v }" % (L.read(a), xr(d), xr(d)))
        else:
            s.append(L.write(d, "%s.u[0]" % xr(a)))
    elif m == "movq":
        if isx(d):
            s.append("{ v := %s; %s = {}; %s.q[0] = v }" % (lane(a, "q"), xr(d), xr(d)))
        else:
            store_lane(d, "q", "%s.q[0]" % xr(a))
    elif m in ("movlpd", "movlps"):
        if isx(d):
            s.append("%s.q[0] = %s" % (xr(d), lane(a, "q")))
        else:
            store_lane(d, "q", "%s.q[0]" % xr(a))
    elif m in ("movhpd", "movhps"):
        if isx(d):
            s.append("%s.q[1] = x86.rd64(%s)" % (xr(d), L.ea(a)))
        else:
            s.append("x86.wr64(%s, %s.q[1])" % (L.ea(d), xr(a)))
    elif m[:-2] in ("add", "sub", "mul", "div", "min", "max") and m[-2:] in ("ss", "sd", "ps", "pd"):
        op = m[:-2]
        f = "f" if m[-1] == "s" else "d"
        n = 1 if m[-2] == "s" else (4 if f == "f" else 2)
        s.append("{ b := %s" % (v128(a) if n > 1 else "%s" % lane(a, f)))
        for k in range(n):
            x = "%s.%s[%d]" % (xr(d), f, k)
            y = "b.%s[%d]" % (f, k) if n > 1 else "b"
            if op in ("min", "max"):
                # x86 returns the second operand when either is NaN or both are zero.
                cmp = "<" if op == "min" else ">"
                s.append("%s = %s %s %s ? %s : %s" % (x, x, cmp, y, x, y))
            else:
                s.append("%s %s= %s" % (x, {"add": "+", "sub": "-", "mul": "*", "div": "/"}[op], y))
        s.append("}")
    elif m in ("sqrtss", "sqrtsd"):
        f = "f" if m == "sqrtss" else "d"
        s.append("%s.%s[0] = math.sqrt(%s)" % (xr(d), f, lane(a, f)))
    elif m == "rcpss":
        s.append("%s.f[0] = 1 / (%s)" % (xr(d), lane(a, "f")))
    elif m in ("psubd", "paddd", "psubq", "paddq", "pcmpeqd"):
        w = "u" if m[-1] == "d" else "q"
        n = 4 if w == "u" else 2
        s.append("{ b := %s" % v128(a))
        for k in range(n):
            x = "%s.%s[%d]" % (xr(d), w, k)
            if m == "pcmpeqd":
                s.append("%s = %s == b.u[%d] ? 0xffffffff : 0" % (x, x, k))
            else:
                s.append("%s %s= b.%s[%d]" % (x, "-" if m.startswith("psub") else "+", w, k))
        s.append("}")
    elif m == "pinsrw":
        s.append("%s.w[%d] = u16(%s)" % (xr(d), ops[2].imm & 7, L.read(a) if a.type == X86_OP_REG else "x86.rd16(%s)" % L.ea(a)))
    elif m == "rsqrtss":
        s.append("%s.f[0] = x86.rsqrt(%s)" % (xr(d), lane(a, "f")))
    elif m in ("andps", "andpd", "pand", "orps", "orpd", "por", "xorps", "xorpd", "pxor", "andnps", "andnpd", "pandn"):
        base = m.rstrip("sd").rstrip("p") if not m.startswith("p") else m[1:]
        base = {"and": "&", "or": "|", "xor": "~", "andn": "andn"}[base]
        if base == "~" and isx(a) and L.reg(a.reg) == L.reg(d.reg):
            s.append("%s = {}" % xr(d))
        else:
            s.append("{ b := %s" % v128(a))
            for k in range(2):
                x = "%s.q[%d]" % (xr(d), k)
                if base == "andn":
                    s.append("%s = ~%s & b.q[%d]" % (x, x, k))
                else:
                    s.append("%s %s= b.q[%d]" % (x, base, k))
            s.append("}")
    elif m in ("ucomiss", "comiss", "ucomisd", "comisd"):
        f = "f" if m.endswith("ss") else "d"
        s.append("x86.fcomi(f64(%s.%s[0]), f64(%s))" % (xr(d), f, lane(a, f)))
    elif m in ("cvtsi2ss", "cvtsi2sd"):
        f = "f" if m.endswith("ss") else "d"
        s.append("%s.%s[0] = %s(i32(%s))" % (xr(d), f, "f32" if f == "f" else "f64", L.read(a)))
    elif m in ("cvttss2si", "cvttsd2si"):
        f = "f" if m.startswith("cvtts") and m[5] == "s" else "d"
        s.append(L.write(d, "x86.cvtt_i32(f64(%s))" % lane(a, f)))
    elif m in ("cvtss2sd", "cvtsd2ss"):
        if m == "cvtss2sd":
            s.append("%s.d[0] = f64(%s)" % (xr(d), lane(a, "f")))
        else:
            s.append("%s.f[0] = f32(%s)" % (xr(d), lane(a, "d")))
    elif m == "shufps":
        s.append("%s = x86.shufps(%s, %s, %d)" % (xr(d), xr(d), v128(a), ops[2].imm & 0xFF))
    elif m == "pshufd":
        s.append("%s = x86.pshufd(%s, %d)" % (xr(d), v128(a), ops[2].imm & 0xFF))
    elif m == "unpcklps":
        s.append("{ x, y := %s, %s; %s.u = {x.u[0], y.u[0], x.u[1], y.u[1]} }" % (xr(d), v128(a), xr(d)))
    elif m == "pextrw":
        s.append(L.write(d, "u32(%s.w[%d])" % (xr(a), ops[2].imm & 7)))
    elif m in ("psllq", "psrlq"):
        fn = "x86.shl64" if m == "psllq" else "x86.shr64"
        cnt = str(a.imm & 0xFF) if a.type == X86_OP_IMM else "u32(min(%s.q[0], 64))" % v128(a)
        s.append("{ n := u32(%s)" % cnt)
        for k in range(2):
            s.append("%s.q[%d] = %s(%s.q[%d], n)" % (xr(d), k, fn, xr(d), k))
        s.append("}")
    elif m.startswith("cmp") and m.endswith("pd"):
        preds = {"eq": 0, "lt": 1, "le": 2, "unord": 3, "neq": 4, "nlt": 5, "nle": 6, "ord": 7}
        p = m[3:-2]
        if p in preds:
            pred = preds[p]
        elif p == "" and len(ops) == 3:
            pred = ops[2].imm & 7
        else:
            raise Unsupported(m)
        s.append("%s = x86.cmppd(%s, %s, %d)" % (xr(d), xr(d), v128(a), pred))
    elif m == "stmxcsr":
        s.append("x86.wr32(%s, c.mxcsr)" % L.ea(d))
    elif m == "ldmxcsr":
        s.append("c.mxcsr = x86.rd32(%s)" % L.ea(d))
    else:
        raise Unsupported(m)


# ---------------------------------------------------------------- integer ops

def lift(img, ins, live, fuse_next=None, fs=None):
    """Statements for a non-control instruction. fuse_next: (cc, sink) when
    the next instruction consumes this one's flags; sink(cond) receives the
    fused condition expression. fs: the function's X87 run cache."""
    L = Lift(img, ins, live, fs)
    s = lift_body(L, ins, fuse_next)
    assert L.frame_count == (ins.address in FRAME_COUNTS), hex(ins.address)
    return s


def lift_body(L, ins, fuse_next):
    s, live = L.s, L.live
    m = ins.mnemonic
    ops = ins.operands
    rep = None
    if m.startswith(("rep ", "repe ", "repne ")):
        rep, m = m.split()
    base = m

    if 0xD8 <= _opbyte(ins) <= 0xDF:
        lift_x87(L, ins)
        return s
    if is_sse(L, ins):
        lift_sse(L, ins)
        return s

    if base == "mov":
        s.append(L.write(ops[0], L.read(ops[1])))
    elif base in ("movzx", "movsx"):
        src = L.read(ops[1])
        if base == "movsx":
            src = "%s(%s(%s))" % (SIZE_T[ops[0].size], STYPE[ops[1].size], src)
        else:
            src = "%s(%s)" % (SIZE_T[ops[0].size], src)
        s.append(L.write(ops[0], src))
    elif base == "lea":
        s.append(L.write(ops[0], L.ea(ops[1]) if ops[0].size == 4 else "u16(%s)" % L.ea(ops[1])))
    elif base == "push":
        sz = ops[0].size if ops[0].type != X86_OP_IMM else 4
        v = L.read(ops[0]) if ops[0].type != X86_OP_IMM else lit(ops[0].imm, 4)
        if sz == 2:
            s.append("v := %s" % v); s.append("c.esp -= 2"); s.append("x86.wr16(c.esp, v)")
        else:
            s.append("v := %s" % v); s.append("c.esp -= 4"); s.append("x86.wr32(c.esp, v)")
    elif base == "pop":
        sz = ops[0].size
        s.append("v := x86.rd%d(c.esp)" % (sz * 8)); s.append("c.esp += %d" % sz)
        s.append(L.write(ops[0], "v"))
    elif base == "xchg":
        a, wa = L.rmw(ops[0])
        s.append("t := %s" % a)
        s.append(wa(L.read(ops[1])))
        s.append(L.write(ops[1], "t"))
    elif base in ("add", "sub", "adc", "sbb", "cmp"):
        size = ops[0].size
        T = SIZE_T[size]
        a, wa = L.rmw(ops[0])
        s.append("a := %s" % a)
        s.append("b := %s" % (L.read(ops[1]) if ops[1].type != X86_OP_IMM else L.imm(ops[1], size)))
        if base in ("adc", "sbb"):
            s.append("cin := c.cf")
            s.append("r := a %s b %s %s(cin ? 1 : 0)" % ("+" if base == "adc" else "-", "+" if base == "adc" else "-", T))
        else:
            s.append("r := a %s b" % ("+" if base == "add" else "-"))
        if base != "cmp":
            s.append(wa("r"))
        kind = {"cmp": "sub"}.get(base, base)
        lv = live
        if fuse_next and base in FUSE_ARITH:
            cc, sink, after = fuse_next
            e = fused_cond("arith", cc, size, "a", "b", "r")
            if e:
                sink(e)
                lv = after
        s.extend(L.flags_arith(kind, size, "a", "b", "r", lv, "cin"))
    elif base in ("and", "or", "xor", "test"):
        size = ops[0].size
        if base == "xor" and ops[1].type == X86_OP_REG and ops[0].type == X86_OP_REG and ops[0].reg == ops[1].reg:
            s.append(L.write(ops[0], lit(0, size)))
            s.append("r := %s" % lit(0, size))
        else:
            a, wa = L.rmw(ops[0])
            b = L.read(ops[1]) if ops[1].type != X86_OP_IMM else lit(ops[1].imm, size)
            op = {"and": "&", "test": "&", "or": "|", "xor": "~"}[base]
            s.append("r := %s %s %s" % (a, op, b))
            if base != "test":
                s.append(wa("r"))
        lv = live
        if fuse_next:
            cc, sink, after = fuse_next
            e = fused_cond("logic", cc, size, None, None, "r")
            if e:
                sink(e)
                lv = after
        s.extend(L.flags_logic(size, "r", lv))
    elif base in ("inc", "dec"):
        size = ops[0].size
        a, wa = L.rmw(ops[0])
        s.append("a := %s" % a)
        s.append("r := a %s 1" % ("+" if base == "inc" else "-"))
        s.append(wa("r"))
        s.extend(L.flags_arith(base, size, "a", "1", "r", live))
    elif base == "neg":
        size = ops[0].size
        a, wa = L.rmw(ops[0])
        s.append("a := %s" % a); s.append("r := 0 - a"); s.append(wa("r"))
        s.extend(L.flags_arith("neg", size, "a", "0", "r", live))
    elif base == "not":
        a, wa = L.rmw(ops[0])
        s.append(wa("~%s" % a))
    elif base in ("shl", "sal", "shr", "sar", "rol", "ror", "rcl", "rcr"):
        size = ops[0].size
        T, bits = SIZE_T[size], size * 8
        a, wa = L.rmw(ops[0])
        n = shift_count(ins)
        if n == 0:
            return s
        s.append("a := %s" % a)
        s.append("n := %s" % (("u32(%d)" % n) if n is not None else "c.ecx & 31"))
        body = []
        if base in ("shl", "sal"):
            body.append("r := a << n")
            if live & CF:
                body.append("c.cf = (a >> (%d - n)) & 1 != 0" % bits)
            if live & OF:
                body.append("c.of = ((r ~ a) & %s) != 0" % SIGN[size])
        elif base == "shr":
            body.append("r := a >> n")
            if live & CF:
                body.append("c.cf = (a >> (n - 1)) & 1 != 0")
            if live & OF:
                body.append("c.of = (a & %s) != 0" % SIGN[size])
        elif base == "sar":
            body.append("r := %s(%s(a) >> n)" % (T, STYPE[size]))
            if live & CF:
                body.append("c.cf = (%s(a) >> (n - 1)) & 1 != 0" % STYPE[size])
            if live & OF:
                body.append("c.of = false")
        elif base in ("rol", "ror"):
            body.append("r := x86.%s%d(a, n)" % (base, bits))
            if live & CF:
                body.append("c.cf = %s" % ("r & 1 != 0" if base == "rol" else "(r & %s) != 0" % SIGN[size]))
            if live & OF:
                body.append("c.of = ((r ~ a) & %s) != 0" % SIGN[size])
        else:
            body.append("r := x86.%s%d(a, n)" % (base, bits))
        body.append(wa("r"))
        if base in ("shl", "sal", "shr", "sar"):
            body += L.flags_result(size, "r", live)
            if live & AF:
                body.append("c.af = false")
        if n is None:
            s.append("if n != 0 {")
            s.extend(body)
            s.append("}")
        else:
            s.extend(body)
    elif base in ("shld", "shrd"):
        a, wa = L.rmw(ops[0])
        s.append("a := %s" % a); s.append("b := %s" % L.read(ops[1]))
        s.append("n := %s" % (("u32(%d)" % (ops[2].imm & 31)) if ops[2].type == X86_OP_IMM else "c.ecx & 31"))
        s.append("if n != 0 {")
        if base == "shld":
            s.append("r := (a << n) | (b >> (32 - n))")
            s.append("c.cf = (a >> (32 - n)) & 1 != 0")
        else:
            s.append("r := (a >> n) | (b << (32 - n))")
            s.append("c.cf = (a >> (n - 1)) & 1 != 0")
        s.append(wa("r"))
        s.extend(L.flags_result(4, "r", ALL)); s.append("c.of = false")
        s.append("}")
    elif base == "imul":
        if len(ops) == 1:
            size = ops[0].size
            if size == 1:
                s.append("p := i16(i8(c.eax)) * i16(i8(%s))" % L.read(ops[0]))
                s.append("c.eax = (c.eax & 0xffff0000) | u32(u16(p))")
                s.append("c.cf = p != i16(i8(p))"); s.append("c.of = c.cf")
                return s
            if size == 2:
                s.append("p := i32(i16(c.eax)) * i32(i16(%s))" % L.read(ops[0]))
                s.append("c.eax = (c.eax & 0xffff0000) | (u32(p) & 0xffff)")
                s.append("c.edx = (c.edx & 0xffff0000) | (u32(p) >> 16)")
                s.append("c.cf = p != i32(i16(p))"); s.append("c.of = c.cf")
                return s
            s.append("p := i64(i32(c.eax)) * i64(i32(%s))" % L.read(ops[0]))
            s.append("c.eax = u32(p)"); s.append("c.edx = u32(p >> 32)")
            s.append("c.cf = p != i64(i32(p))"); s.append("c.of = c.cf")
        else:
            size = ops[0].size
            st = STYPE[size]
            def sval(op):
                # Immediates as signed literals: a u32 constant above
                # 0x7fffffff cannot be cast to i32 at compile time.
                if op.type == X86_OP_IMM:
                    v = op.imm & ((1 << (8 * size)) - 1)
                    if v >= 1 << (8 * size - 1):
                        v -= 1 << (8 * size)
                    return "i64(%d)" % v
                return "i64(%s(%s))" % (st, L.read(op))
            x, y = (ops[0], ops[1]) if len(ops) == 2 else (ops[1], ops[2])
            s.append("p := %s * %s" % (sval(x), sval(y)))
            s.append(L.write(ops[0], "%s(p)" % SIZE_T[size]))
            if live & (CF | OF):
                s.append("c.cf = p != i64(%s(p))" % st); s.append("c.of = c.cf")
            s += L.flags_result(size, "%s(p)" % SIZE_T[size], live)
    elif base == "mul":
        if ops[0].size != 4:
            raise Unsupported("mul8/16")
        s.append("p := u64(c.eax) * u64(%s)" % L.read(ops[0]))
        s.append("c.eax = u32(p)"); s.append("c.edx = u32(p >> 32)")
        s.append("c.cf = c.edx != 0"); s.append("c.of = c.cf")
    elif base in ("div", "idiv"):
        if ops[0].size != 4:
            raise Unsupported("div8/16")
        if base == "div":
            s.append("d := u64(%s)" % L.read(ops[0]))
            s.append("n := u64(c.edx) << 32 | u64(c.eax)")
            s.append("c.eax = u32(n / d)"); s.append("c.edx = u32(n %% d)")
        else:
            s.append("d := i64(i32(%s))" % L.read(ops[0]))
            s.append("n := i64(u64(c.edx) << 32 | u64(c.eax))")
            s.append("c.eax = u32(n / d)"); s.append("c.edx = u32(n %% d)")
    elif base == "cdq":
        s.append("c.edx = u32(i32(c.eax) >> 31)")
    elif base == "cwde":
        s.append("c.eax = u32(i32(i16(c.eax)))")
    elif base == "cbw":
        s.append("c.eax = (c.eax & 0xffff0000) | u32(u16(i16(i8(c.eax))))")
    elif base == "leave":
        s.append("c.esp = c.ebp"); s.append("c.ebp = x86.rd32(c.esp)"); s.append("c.esp += 4")
    elif base == "enter":
        if ops[1].imm != 0:
            raise Unsupported("enter level")
        s.append("c.esp -= 4"); s.append("x86.wr32(c.esp, c.ebp)"); s.append("c.ebp = c.esp")
        s.append("c.esp -= %d" % ops[0].imm)
    elif m in SETCC:
        s.append(L.write(ops[0], "u8(1) if %s else u8(0)" % COND[SETCC[m]][1]))
    elif base in ("nop", "wait", "prefetcht0", "prefetchnta"):
        pass
    elif base in ("cld", "std"):
        s.append("c.df = %s" % ("true" if base == "std" else "false"))
    elif base in ("clc", "stc", "cmc"):
        s.append({"clc": "c.cf = false", "stc": "c.cf = true", "cmc": "c.cf = !c.cf"}[base])
    elif base == "sahf":
        s.append("x86.sahf()")
    elif base == "lahf":
        s.append("x86.lahf()")
    elif base == "pushfd":
        s.append("c.esp -= 4"); s.append("x86.wr32(c.esp, x86.get_eflags())")
    elif base == "popfd":
        s.append("x86.set_eflags(x86.rd32(c.esp))"); s.append("c.esp += 4")
    elif base == "pushal":
        s.append("x86.pushad()")
    elif base == "popal":
        s.append("x86.popad()")
    elif base == "cpuid":
        s.append("x86.cpuid()")
    elif base in ("bt", "bts", "btr", "btc"):
        if ops[0].type != X86_OP_REG and ops[1].type != X86_OP_IMM:
            # Memory form with a register offset: signed bit index, so the
            # word addressed is ea + (offset >> 5) * 4.
            if ops[0].size != 4:
                raise Unsupported("bt mem16,reg")
            s.append("n := %s" % L.read(ops[1]))
            s.append("ea := u32(%s) + u32(i32(n) >> 5) * 4" % L.ea(ops[0]))
            s.append("a := x86.rd32(ea)")
            s.append("c.cf = (a >> (n & 31)) & 1 != 0")
            if base != "bt":
                op = {"bts": "a | (1 << (n & 31))", "btr": "a &~ (1 << (n & 31))", "btc": "a ~ (1 << (n & 31))"}[base]
                s.append("x86.wr32(ea, %s)" % op)
            return s
        a, wa = L.rmw(ops[0])
        bits = ops[0].size * 8
        s.append("a := %s" % a)
        s.append("n := u32(%s) & %d" % (L.read(ops[1]) if ops[1].type != X86_OP_IMM else str(ops[1].imm), bits - 1))
        s.append("c.cf = (a >> n) & 1 != 0")
        if base != "bt":
            op = {"bts": "a | (1 << n)", "btr": "a &~ (1 << n)", "btc": "a ~ (1 << n)"}[base]
            s.append(wa(op))
    elif base == "xlatb":
        s.append("c.eax = (c.eax & 0xffffff00) | u32(x86.rd8(c.ebx + (c.eax & 0xff)))")
    elif base in ("movsb", "movsw", "movsd", "stosb", "stosw", "stosd", "lodsb", "lodsw", "lodsd",
                  "cmpsb", "cmpsw", "cmpsd", "scasb", "scasw", "scasd") and (base[-1] in "bwd") and (not ops or ops[0].type == X86_OP_MEM or base.startswith(("lods", "scas", "stos"))):
        size = {"b": 1, "w": 2, "d": 4}[base[-1]]
        fn = base[:-1]
        mode = {"rep": ".Rep", "repe": ".Repe", "repne": ".Repne", None: ".None"}[rep]
        if fn in ("movs", "stos", "lods") and rep == "repe":
            mode = ".Rep"
        s.append("x86.%s(%d, %s)" % (fn, size, mode))
    elif base == "int3":
        s.append("x86.trap(%s)" % hexu(ins.address))
    else:
        raise Unsupported(m)
    return s


def _opbyte(ins):
    b = bytes(ins.bytes)
    k = 0
    while k < len(b) and b[k] in PREFIXES:
        k += 1
    return b[k] if k < len(b) else 0


# Register promotion. The guest registers and flags live in x86.cpu, a global,
# and every guest store may alias it as far as LLVM can tell, so each c.esp in
# a run of pushes and stack stores was a reload. A function therefore keeps the
# ones it names in proc locals g_<reg>, loaded at entry. A sync line (a call of
# anything that may read or write them, or a return) keeps its c.<reg> refs:
# before it the locals the function writes go back to x86.cpu, after it (unless
# it returns) the locals reload. A direct call or a return narrows both to the
# registers its Sync names. WHY: docs/recompiler.md §2
PROMOTED = tuple(R32) + ("cf", "zf", "sf", "of", "pf", "af", "df")
FLAG_NAME = {CF: "cf", PF: "pf", AF: "af", ZF: "zf", SF: "sf", OF: "of"}
# x86 helpers that touch no promoted register; any other call syncs.
PURE_HELPERS = frozenset((
    "rd8", "rd16", "rd32", "rd64", "rd128", "wr8", "wr16", "wr32", "wr64", "wr128",
    "st", "set_st", "set_st_raw", "st_phys", "set_st_phys", "round_pc", "round_single",
    "rot8", "fpush", "fpop", "fstsw", "fcom", "fldcw", "fist32", "fist32_trunc", "fist64",
    "round_cw", "parity", "shr64", "shl64", "ld80", "st80", "pshufd", "cmppd", "shufps",
    "frstor", "fnsave"))
REG_REF = re.compile(r'\bc\.(%s)\b' % "|".join(PROMOTED))
REG_WRITE = re.compile(r'\bc\.(%s)\s*(?:<<|>>|&~|[-+*/%%|&~])?=(?!=)' % "|".join(PROMOTED))
CPU_REG = re.compile(r'\bcpu\.(%s)\b' % "|".join(PROMOTED))
SYNC_CALL = re.compile(r'\bx86\.(\w+)\(|(?<![\w.])[rf]_[0-9a-f]{8}\(|\bnative\.\w+\(')
CALL_LIT = re.compile(r'\bx86\.call(?:_ext)?\((0x[0-9a-f]{8})\)')


def reg_names(gpr, flags):
    """Promoted names of GPR and flag bit sets; esp and df always."""
    return frozenset([r for k, r in enumerate(R32) if gpr >> k & 1] +
                     [n for b, n in FLAG_NAME.items() if flags & b] + ["esp", "df"])


class Sync:
    """Promoted registers each direct call and return must store, and each
    direct call must reload. A call skips registers the callee is transparent
    in; the callee's returns store those it may write, so x86.cpu holds the
    caller's values again, as on the machine."""

    def __init__(self, funcs, flag_entry, flag_ret, gpr_entry, gpr_ret, mod, transp):
        every = frozenset(PROMOTED)
        self.call = {}  # entry -> (store, reload)
        self.ret = {}   # f.start -> store
        for f in funcs:
            restore = 0
            for e in f.entries:
                tr = transp[e]
                restore |= tr
                self.call[e] = (reg_names(gpr_entry[e] & ~tr, flag_entry[e]),
                                reg_names(mod[f.start] & ~tr, ALL) | every - set(R32))
            gpr = gpr_ret.get(f.start, 0) | restore & mod[f.start]
            self.ret[f.start] = reg_names(gpr, flag_ret.get(f.start, 0))


def sync_target(line):
    """Address a sync line calls when that call is all it does, else None."""
    lits = CALL_LIT.findall(line)
    n = 0
    for m in SYNC_CALL.finditer(line):
        g = m.group(1)
        if g in ("call", "call_ext"):
            n += 1
        elif g is not None and g not in PURE_HELPERS:
            return None
    if len(set(lits)) != 1 or n != len(lits):
        return None
    return int(lits[0], 16)


def is_sync(line):
    s = line.strip()
    if s == "return" or s.startswith("return "):
        return True
    for m in SYNC_CALL.finditer(line):
        if m.group(1) is None or m.group(1) not in PURE_HELPERS:
            return True
    return False


def promote_regs(lines, sync_regs):
    """Returns (entry declarations, lines) with promoted registers in locals.
    sync_regs(line) -> (store, reload) names for a sync line, or None for all."""
    sync = [is_sync(l) for l in lines]
    named, written = set(), set()
    for l, s in zip(lines, sync):
        if not s:
            named.update(REG_REF.findall(l))
            written.update(REG_WRITE.findall(l))
    regs = [r for r in PROMOTED if r in named]
    if not regs:
        return [], lines
    every = [r for r in regs if r in written]
    load = ["g_%s = c.%s" % (r, r) for r in regs]
    # Locals that may differ from x86.cpu: those written since the last sync on
    # the straight-line path, or all written ones at a point control can reach
    # from elsewhere (a loop head, a case, the end of a labeled or if block).
    dirty = set()
    opens = []  # per open brace: does its close join paths?
    out = []
    for l, s in zip(lines, sync):
        st = l.strip()
        code = st.split("//")[0]
        rest = code[1:] if code.startswith("}") else code
        closes = (1 if rest is not code else 0) + max(rest.count("}") - rest.count("{"), 0)
        for _ in range(closes):
            if opens.pop():
                dirty = set(every)
        n = rest.count("{") - rest.count("}")
        opens.extend([not rest.startswith("{")] * max(n, 0))
        if (n > 0 or code.startswith("case")) and not rest.startswith(("{", "if ", "B_")):
            dirty = set(every)  # for, else, switch, case: entered from elsewhere
        if not s:
            dirty.update(REG_WRITE.findall(l))
            out.append(REG_REF.sub(r"g_\1", l))
            continue
        ind = l[:len(l) - len(l.lstrip("\t"))]
        # A reload after the line must run after it, so the line cannot open a block.
        assert not st.endswith("{"), "sync line opens a block: %s" % st
        store, reload = sync_regs(st) or (every, regs)
        out.extend(ind + "c.%s = g_%s" % (r, r) for r in every if r in dirty and r in store)
        out.append(l)
        # A register neither stored nor reloaded still differs from x86.cpu.
        dirty = {r for r in dirty if r not in store and r not in reload}
        if not (st == "return" or st.startswith("return ")):
            out.extend(ind + x for r, x in zip(regs, load) if r in reload)
    assert not opens
    return ["g_%s := c.%s" % (r, r) for r in regs], out


# ---------------------------------------------------------------- emission

class Emitter:
    def __init__(self, img, pkg_funcs, sync, names, native, spans):
        self.img = img
        self.local = pkg_funcs   # entry addr -> proc name, for direct calls in this package
        self.native = native     # entry addr -> proc name in package native
        self.spans = spans       # start addr -> (proc name in package native, exit addr)
        self.span_exits = {x for _, x in spans.values()}
        self.uses_native = False
        self.names = names       # entry addr -> readable name, from re/funcnames.txt
        self.sync = sync         # Sync
        self.unsupported = defaultdict(int)
        self.structured = 0   # functions emitted as nested blocks and loops
        self.dispatched = 0   # functions emitted as a pc-dispatch loop

    def call_expr(self, t):
        # A direct call goes through x86.call while any probe is set, so
        # probes see calls inside a package too. WHY: docs/recompiler.md §7
        if t in self.native:
            self.uses_native = True
            return "if x86.probe_n > 0 {x86.call(%s)} else {native.%s()}" % (hexu(t), self.native[t])
        if t in self.local:
            return "if x86.probe_n > 0 {x86.call(%s)} else {%s()}" % (hexu(t), self.local[t])
        return "x86.call_ext(%s)" % hexu(t)

    def target_value(self, L, op):
        if op.type == X86_OP_REG:
            return L.read(op)
        if op.type == X86_OP_MEM:
            return "x86.rd32(%s)" % L.ea(op)
        raise Unsupported("indirect")

    def emit_func(self, f, out):
        img = self.img
        multi = len(f.entries) > 1
        name = body_name(f, self.names) if multi else self.local[f.start]
        if len(f.labels) > COLD_LABELS:
            out.append('@(optimization_mode="none")')
        if multi:
            out.append("%s :: proc(entry: u32) {" % name)
        else:
            out.append("%s :: proc() {" % name)
        out.append("\tc := &x86.cpu")
        decl_at = len(out)
        fs = X87()
        live = f.live
        pcs = sorted(f.insns)
        body = []
        cases = []  # (label, lines); lines hold GOTO / FALL / TABLE markers
        open_case = False
        prev_nxt = None  # address the last emitted instruction falls through to
        k = 0

        def goto(src, t):
            if f.inside(t) and t in f.labels:
                return [GOTO + hexu(t)]
            return [self.call_expr(t), "return"]

        cur = None
        span_used = False

        def span_lines(pc):
            # The native span's hooks open the block at pc.
            nonlocal span_used
            if pc in self.span_exits:
                self.uses_native = True
                body.append("if native.mode == .Check {native.span_end(%s)}" % hexu(pc))
            if pc in self.spans:
                name, x = self.spans[pc]
                assert f.inside(x) and x in f.labels, "span %s exit %s is not a block" % (name, hexu(x))
                self.uses_native = True
                span_used = True
                body.extend(["span_ok = x86.probe_n == 0 && native.%s()" % name,
                             "if span_ok {", "\t" + GOTO + hexu(x), "}"])

        def close():
            if cur is not None:
                cases.append((cur, body[:]))
            body.clear()

        while k < len(pcs):
            pc = pcs[k]
            k += 1
            ins = f.insns[pc]
            if pc in f.labels:
                if open_case:
                    fs.flush(body)
                    # address order is not execution order across overlapping streams
                    body.extend([FALL] if prev_nxt == pc else goto(pc, prev_nxt))
                close()
                cur = pc
                open_case = True
                span_lines(pc)
            elif not open_case:
                continue
            else:
                assert prev_nxt == pc, "unlabeled overlap at %s" % hexu(pc)
            if ins is None or pc in f.bad:
                fs.flush(body)
                body.append("x86.bad_insn(%s)" % hexu(pc))
                body.append("return")
                open_case = False
                continue
            nxt = pc + ins.size
            prev_nxt = nxt
            kind, t = control(img, ins)
            m = ins.mnemonic
            try:
                if kind is None:
                    # Fuse a flag producer with an immediately following consumer.
                    nins = f.insns.get(nxt)
                    fuse = None
                    if (nins is not None and nxt not in f.labels and m in (FUSE_ARITH | FUSE_LOGIC)
                            and (nins.mnemonic in JCC or nins.mnemonic in SETCC)):
                        cc = JCC.get(nins.mnemonic) or SETCC.get(nins.mnemonic)
                        holder = []
                        fuse = (cc, holder.append, live[nxt])
                    st = lift(img, ins, live[pc], fuse, fs)
                    check_gpr_effect(ins, st)
                    if fuse and holder:
                        cond = holder[0]
                        k += 1  # nxt is not a label, so split_overlaps made pcs[k] == nxt
                        prev_nxt = nxt + nins.size
                        if nins.mnemonic in SETCC:
                            L = Lift(img, nins, 0)
                            st.append(L.write(nins.operands[0], "u8(1) if %s else u8(0)" % cond))
                            body.append("{")
                            body.extend("\t" + x for x in st)
                            body.append("}")
                            continue
                        # jcc: flags kept in locals; branch after the block.
                        fs.flush(body)
                        body.append("{")
                        body.extend("\t" + x for x in st)
                        tgt = nins.operands[0].imm & 0xFFFFFFFF
                        body.append("\tif %s {" % cond)
                        body.extend("\t\t" + x for x in goto(nxt, tgt))
                        body.append("\t}")
                        body.append("}")
                        nn = nxt + nins.size
                        if nn not in f.insns or not f.inside(nn):
                            body.extend(goto(nxt, nn))
                            open_case = False
                        continue
                    if len(st) == 1 and ":=" not in st[0]:
                        body.extend(st)
                    elif st:
                        body.append("{")
                        body.extend("\t" + x for x in st)
                        body.append("}")
                    if nxt not in f.insns or f.insns.get(nxt) is None and nxt not in f.labels:
                        if not f.inside(nxt) or nxt not in f.insns:
                            fs.flush(body)
                            body.extend(goto(pc, nxt))
                            open_case = False
                    continue
                fs.flush(body)
                if kind == "jcc":
                    if m == "jecxz":
                        cond = "c.ecx == 0"
                    elif m.startswith("loop"):
                        body.append("c.ecx -= 1")
                        cond = {"loop": "c.ecx != 0", "loope": "c.ecx != 0 && c.zf", "loopne": "c.ecx != 0 && !c.zf"}[m]
                    else:
                        cond = COND[JCC[m]][1]
                    body.append("if %s {" % cond)
                    body.extend("\t" + x for x in goto(pc, t))
                    body.append("}")
                    if nxt not in f.insns or not f.inside(nxt):
                        body.extend(goto(pc, nxt))
                        open_case = False
                elif kind == "jmp":
                    body.extend(goto(pc, t))
                    open_case = False
                elif kind == "ret":
                    n = ins.operands[0].imm if ins.operands else 0
                    body.append("c.esp += %d" % (4 + n))
                    body.append("return")
                    open_case = False
                elif kind in ("call", "icall"):
                    if kind == "call":
                        tgt = self.call_expr(t)
                        body.append("c.esp -= 4")
                        body.append("x86.wr32(c.esp, %s)" % hexu(nxt))
                        body.append(tgt)
                    else:
                        L = Lift(img, ins, 0)
                        v = self.target_value(L, ins.operands[0])
                        body.append("{")
                        body.append("\tt := %s" % v)
                        body.append("\tc.esp -= 4")
                        body.append("\tx86.wr32(c.esp, %s)" % hexu(nxt))
                        body.append("\tx86.call_ext(t)")
                        body.append("}")
                    if nxt not in f.insns or not f.inside(nxt):
                        body.extend(goto(pc, nxt))
                        open_case = False
                elif kind == "ijmp":
                    L = Lift(img, ins, 0)
                    v = self.target_value(L, ins.operands[0])
                    body.append("pc = %s" % v)
                    if pc in f.tables:
                        body.append(TABLE + hexu(pc))
                    else:
                        body.append("x86.call(pc)")
                        body.append("return")
                    open_case = False
            except Unsupported as e:
                fs.flush(body)
                self.unsupported[str(e)] += 1
                body.append("x86.unsupported(%s) // %s %s" % (hexu(pc), ins.mnemonic, ins.op_str))
                body.append("return")
                open_case = False
        if open_case:
            # Ran off the decoded code (should not happen): fail loudly.
            fs.flush(body)
            body.append("x86.bad_insn(%s)" % hexu(pcs[-1]))
            body.append("return")
        close()
        assert not fs.active
        lines = structure(f, cases)
        if lines is None:
            self.dispatched += 1
            lines = dispatch(f, cases)
        else:
            self.structured += 1
        def sync_regs(st):
            if st == "return":
                return self.sync.ret[f.start], ()
            t = sync_target(st)
            return self.sync.call.get(t) if t is not None else None

        gdecl, lines = promote_regs(lines, sync_regs)
        out[decl_at:decl_at] = ["\t" + d for d in sorted(fs.used) + gdecl + (["span_ok: bool"] if span_used else [])]
        out.extend(lines)
        out.append("}")
        out.append("")
        if multi:
            for e in sorted(f.entries):
                out.append("%s :: proc() { %s(%s) }" % (self.local[e], name, hexu(e)))
            out.append("")


# Control flow between basic blocks. emit_func lowers each block to lines
# with markers for its exits; structure() lays the blocks out as nested
# labeled blocks (a forward jump is `break`) and loops (a backward jump is
# `continue`), so jumps are direct branches. A function whose blocks do not
# nest that way (a jump into a loop past its head, an entry inside a loop)
# keeps the pc-dispatch loop, where every jump goes through the switch.
# WHY: docs/recompiler.md §1
GOTO = "\x00goto "     # jump to the block at the address
FALL = "\x00fall"      # last line: falls into the next block in address order
TABLE = "\x00table "   # switch-table jump at the address; pc holds the target
MAX_NEST = 128         # deeper nesting overflows the Odin compiler's stack


def marker(line):
    s = line.lstrip("\t")
    return line[:len(line) - len(s)], s


def dispatch(f, cases):
    out = ["\tpc: u32 = %s" % ("entry" if len(f.entries) > 1 else hexu(f.start)), "\tfor {", "\t\tswitch pc {"]
    for label, lines in cases:
        out.append("\t\tcase %s:" % hexu(label))
        for l in lines:
            ind, s = marker(l)
            if s.startswith(GOTO):
                out += ["\t\t\t" + ind + "pc = " + s[len(GOTO):], "\t\t\t" + ind + "continue"]
            elif s == FALL:
                out.append("\t\t\t" + ind + "fallthrough")
            elif s.startswith(TABLE):
                out.append("\t\t\t" + ind + "continue")
            else:
                out.append("\t\t\t" + l)
    out += ["\t\tcase:", "\t\t\tx86.call(pc)", "\t\t\treturn", "\t\t}", "\t}"]
    return out


def block_edges(f, lines, at):
    """Blocks a block's lines jump to (by index), or None for a jump to an
    address that is not a block."""
    succ = []
    for l in lines:
        _, s = marker(l)
        if s.startswith(GOTO):
            ts = [int(s[len(GOTO):], 16)]
        elif s.startswith(TABLE):
            ts = sorted({e for e in f.tables[int(s[len(TABLE):], 16)] if f.inside(e)})
        else:
            continue
        for t in ts:
            if t not in at:
                return None
            succ.append(at[t])
    return succ


def structure(f, cases):
    """Lines of f's body as nested blocks and loops, or None."""
    if not cases or cases[0][0] != f.start:
        return None
    if len(f.entries) > 1:
        # Block 0 picks the entry; the first block is the function start.
        sw = ["switch entry {"]
        for e in sorted(f.entries - {f.start}):
            sw += ["case %s:" % hexu(e), "\t" + GOTO + hexu(e)]
        cases = [(None, sw + ["}", FALL])] + cases
    at = {label: i for i, (label, _) in enumerate(cases) if label is not None}
    succ = []
    for i, (_, lines) in enumerate(cases):
        s = block_edges(f, lines, at)
        if s is None:
            return None
        succ.append((s, bool(lines) and lines[-1] == FALL))
    # Unreachable blocks are dropped: Odin rejects code after a return.
    live, work = {0}, [0]
    while work:
        i = work.pop()
        s, fall = succ[i]
        for j in s + ([i + 1] if fall else []):
            if j not in live:
                live.add(j); work.append(j)
    keep = sorted(live)
    pos = {i: p for p, i in enumerate(keep)}
    n = len(keep)
    # Constructs [open, close) over block positions: a loop from each
    # backward target to its last source, a block from the first forward
    # source to each forward target.
    loops, blocks = {}, {}
    for i in keep:
        for j in succ[i][0]:
            p, q = pos[i], pos[j]
            if q <= p:
                loops[q] = max(loops.get(q, p + 1), p + 1)
            else:
                blocks[q] = min(blocks.get(q, p), p)
    cons = [["L", o, c] for o, c in loops.items()] + [["B", o, c] for c, o in blocks.items()]
    # Make them nest: a block may open earlier, a loop may close later.
    for _ in range(4 * len(cons) + 1):
        changed = False
        for a in cons:
            for b in cons:
                if a[1] < b[1] < a[2] < b[2]:
                    if b[0] == "B":
                        b[1] = a[1]
                    elif a[0] == "L":
                        a[2] = b[2]
                    else:
                        return None  # a block closes inside a loop it opened before
                    changed = True
        if not changed:
            break
    else:
        return None
    loop_at = {o: ("L_%d" % o) for k, o, c in cons if k == "L"}
    block_at = {c: ("B_%d" % c) for k, o, c in cons if k == "B"}
    opens = defaultdict(list)
    for con in sorted(cons, key=lambda x: (x[1], -x[2], x[0] != "B")):
        opens[con[1]].append(con)

    def jump(ind, p, q):
        return ind + ("continue " + loop_at[q] if q <= p else "break " + block_at[q])

    out, stack, reach = [], [], True
    for p in range(n + 1):
        while stack and stack[-1][2] == p:
            k, o, c = stack.pop()
            if k == "L":
                if reach:
                    out.append("\tbreak " + loop_at[o])
            else:
                reach = True
            out.append("\t}")
        if any(c == p for _, _, c in stack):
            return None
        if p == n:
            break
        for con in opens[p]:
            out.append("\t%s: %s" % ((loop_at[p], "for {") if con[0] == "L" else (block_at[con[2]], "{")))
            stack.append(con)
        if len(stack) > MAX_NEST or not reach:
            return None
        label, lines = cases[keep[p]]
        for l in lines:
            ind, s = marker(l)
            if s.startswith(GOTO):
                out.append("\t" + jump(ind, p, pos[at[int(s[len(GOTO):], 16)]]))
            elif s == FALL:
                pass
            elif s.startswith(TABLE):
                ents = sorted({e for e in f.tables[int(s[len(TABLE):], 16)] if f.inside(e)})
                out.append("\t" + ind + "switch pc {")
                for e in ents:
                    out += ["\t" + ind + "case %s:" % hexu(e), "\t" + jump(ind + "\t", p, pos[at[e]])]
                out += ["\t" + ind + "case:", "\t" + ind + "\tx86.call(pc)", "\t" + ind + "\treturn", "\t" + ind + "}"]
            else:
                out.append("\t" + l)
        reach = succ[keep[p]][1]
    return ["\tpc: u32"] + out


# Proc names keep the entry address, so they stay unique and greppable; a
# function tools/funcnames.py names is prefixed with that name.
# WHY: docs/exe_inventory.md §8
def proc_name(f, e, names):
    if e in names:
        return "%s_%08x" % (names[e], e)
    return ("f_%08x" % e) if len(f.entries) > 1 else ("r_%08x" % f.start)


def body_name(f, names):
    """The shared body of a multi-entry function, behind one wrapper per entry."""
    if f.start in names:
        return "%s_%08x_body" % (names[f.start], f.start)
    return "r_%08x" % f.start


def load_names(path):
    """{address: name} from re/funcnames.txt."""
    names = {}
    for l in open(path):
        if l.startswith("0x"):
            a, n = l.split()[:2]
            assert re.fullmatch(r"[A-Za-z]\w*", n), "not an Odin identifier: " + l
            names[int(a, 16)] = n
    return names


# Inlining. Under -use-separate-modules Odin emits one LLVM module per source
# file of a large package, and #force_inline does not cross modules: an x86
# helper (rd32, set_st, ...) called from generated code stays an out-of-line
# call. Each code.odin therefore ends with a copy of x86's
# #force_inline helpers, extracted from the x86 sources so those stay the
# single definition; x86 names they use are qualified.
# WHY: docs/recompiler.md §2
INLINE_HEAD = re.compile(r'^(\w+) :: #force_inline proc\b')
TOP_DECL = re.compile(r'^(\w+(?:\s*,\s*\w+)*)\s*:')


def inline_helpers(x86_dir):
    decls, helpers = set(), []
    for fn in sorted(os.listdir(x86_dir)):
        if not fn.endswith(".odin"):
            continue
        lines = open(os.path.join(x86_dir, fn)).read().split("\n")
        i = 0
        while i < len(lines):
            m = TOP_DECL.match(lines[i])
            if m:
                decls.update(n.strip() for n in m.group(1).split(","))
            h = INLINE_HEAD.match(lines[i])
            if h is None:
                i += 1
                continue
            j = i
            if not lines[i].rstrip().endswith("}"):
                while lines[j] != "}":
                    j += 1
                    assert j < len(lines), "unterminated helper %s" % h.group(1)
            if h.group(1) in PURE_HELPERS:
                assert not CPU_REG.search("\n".join(lines[i:j + 1])), "impure helper %s" % h.group(1)
            helpers.append((h.group(1), lines[i:j + 1]))
            i = j + 1
    names = {n for n, _ in helpers}
    qual = sorted(decls - names, key=len, reverse=True)
    pat = re.compile(r'(?<![\w.])(%s)\b' % "|".join(qual))
    body = []
    for _, ls in helpers:
        body += [pat.sub(r"x86.\1", l) for l in ls] + [""]
    return names, body


# Hand-written replacements (port/src/native): a proc named Name_xxxxxxxx
# replaces the guest function at 0xxxxxxxxx. Its recompiled body is still
# emitted and registered; native.register swaps the dispatch entry, and direct
# calls from every package go to the native proc.
# WHY: docs/recompiler.md §8
NATIVE_HEAD = re.compile(r'^(\w+_([0-9a-f]{8})) :: proc\(\) (?:#no_bounds_check )?\{', re.M)


def native_procs(native_dir):
    out = {}
    for fn in sorted(os.listdir(native_dir)):
        if fn.endswith(".odin"):
            for m in NATIVE_HEAD.finditer(open(os.path.join(native_dir, fn)).read()):
                out[int(m.group(2), 16)] = m.group(1)
    return out


# Native spans: a proc named Name_ssssssss_xxxxxxxx returning bool replaces
# the stretch of a recompiled body from the block at 0xssssssss to the block
# at 0xxxxxxxxx. The body calls it on entering the start block, with every
# register in x86.cpu, and jumps to the exit block when it returns true; on
# false (a fallback, or JE_NATIVE=check) the recompiled stretch runs. Under
# check, native.span_end at the exit block compares the two.
# WHY: docs/recompiler.md §8
SPAN_HEAD = re.compile(r'^(\w+_([0-9a-f]{8})_([0-9a-f]{8})) :: proc\(\) -> bool (?:#no_bounds_check )?\{', re.M)


def native_spans(native_dir):
    """{start: (proc name, exit)}."""
    out = {}
    for fn in sorted(os.listdir(native_dir)):
        if fn.endswith(".odin"):
            for m in SPAN_HEAD.finditer(open(os.path.join(native_dir, fn)).read()):
                out[int(m.group(2), 16)] = (m.group(1), int(m.group(3), 16))
    return out


def localize_calls(text, names):
    return re.sub(r'\bx86\.(%s)\(' % "|".join(sorted(names)), r"\1(", text)


def analyse(img, funcs, exe, ghidra_path, out_dir):
    """The whole-program analyses: flag and GPR liveness, transparency. They
    depend only on the image, the function list and this generator, not on
    port/src/native, so their results are cached in port/build keyed by those
    three; a regen for a new native or hook skips them (most of the run).
    Sets f.live on every function."""
    h = hashlib.sha256()
    for path in (exe, ghidra_path, os.path.abspath(__file__)):
        with open(path, "rb") as fp:
            h.update(fp.read())
    cache = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(out_dir))), "build", "x86rec_analysis.pickle")
    try:
        with open(cache, "rb") as fp:
            key, live, res = pickle.load(fp)
        if key == h.hexdigest():
            for f in funcs:
                f.live = live[f.start]
            print("analysis cached")
            return res
    except (OSError, EOFError, pickle.UnpicklingError, ValueError):
        pass
    flag_entry, flag_ret = flag_liveness(funcs)
    mod = gpr_mod(funcs)
    entry0, _, ntaken = gpr_liveness(img, funcs, mod, {})
    host = host_pops(img)
    print("%d of %d imports with known argument pops" % (len(host), len(img.iat)))
    transp = transparency(funcs, entry0, mod, taken_entries(img, funcs), host)
    gpr_entry, gpr_ret, _ = gpr_liveness(img, funcs, mod, transp)
    res = (flag_entry, flag_ret, mod, transp, gpr_entry, gpr_ret, ntaken)
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache + ".tmp", "wb") as fp:
        pickle.dump((h.hexdigest(), {f.start: f.live for f in funcs}, res), fp, pickle.HIGHEST_PROTOCOL)
    os.replace(cache + ".tmp", cache)
    return res


def main():
    exe, ghidra_path, out_dir = sys.argv[1:4]
    img = Image(exe)
    ghidra = [int(l.split()[0], 16) for l in open(ghidra_path) if l.strip()]
    fnames = load_names(os.path.join(os.path.dirname(ghidra_path), "funcnames.txt"))
    funcs, rejected = build_funcs(img, ghidra)
    funcs.sort(key=lambda f: f.start)
    flag_entry, flag_ret, mod, transp, gpr_entry, gpr_ret, ntaken = analyse(img, funcs, exe, ghidra_path, out_dir)
    check_indirect_calls(img, funcs)
    print("flags live at ret in %d functions, at %d entries"
          % (sum(1 for v in flag_ret.values() if v), sum(1 for v in flag_entry.values() if v)))
    sync = Sync(funcs, flag_entry, flag_ret, gpr_entry, gpr_ret, mod, transp)
    print("%d functions reachable through pointers" % ntaken)
    print("transparent registers: %s" % ", ".join(
        "%s %d" % (r, sum(1 for v in transp.values() if v >> k & 1))
        for k, r in enumerate(R32) if SAVED >> k & 1))
    # Packages of about PACKAGE_INSNS instructions, in address order.
    pkgs = []
    cur, n = [], 0
    for f in funcs:
        cur.append(f)
        n += len(f.insns)
        if n >= PACKAGE_INSNS:
            pkgs.append(cur); cur, n = [], 0
    if cur:
        pkgs.append(cur)
    src_dir = os.path.dirname(os.path.abspath(out_dir))
    inl_names, inl_body = inline_helpers(os.path.join(src_dir, "x86"))
    native = native_procs(os.path.join(src_dir, "native"))
    spans = native_spans(os.path.join(src_dir, "native"))
    assert all(any(f.inside(s) and s in f.labels for f in funcs) for s in spans), "span start is not a block"
    entries = {e for f in funcs for e in f.entries}
    assert set(native) <= entries, "native procs without a guest function: %s" % sorted(set(native) - entries)
    print("%d native replacements, %d spans" % (len(native), len(spans)))
    unsupported = defaultdict(int)
    nstruct = ndisp = 0
    names = []
    total = 0
    for k, pf in enumerate(pkgs):
        pname = "m%02d" % k
        names.append(pname)
        local = {}
        for f in pf:
            for e in f.entries:
                local[e] = proc_name(f, e, fnames)
        em = Emitter(img, local, sync, fnames, native, spans)
        out = []
        for f in pf:
            em.emit_func(f, out)
            total += len(f.insns)
        imports = ['import "base:intrinsics"', 'import "core:math"', 'import "../../x86"']
        if em.uses_native:
            imports.append('import "../../native"')
        out = (["// Generated by tools/x86rec.py. Do not edit.", "package %s" % pname, ""] + imports
               + ["", "_ :: intrinsics", "_ :: math", ""] + out)
        out.append("FUNCS := [?]x86.Func_Entry{")
        for f in pf:
            for e in sorted(f.entries):
                out.append("\t{%s, %s}," % (hexu(e), local[e]))
        out.append("}")
        d = os.path.join(out_dir, pname)
        os.makedirs(d, exist_ok=True)
        out.append("")
        out.append("// Copies of the x86 package's contextless #force_inline helpers.")
        with open(os.path.join(d, "code.odin"), "w") as fp:
            fp.write(localize_calls("\n".join(out + inl_body), inl_names))
        nstruct += em.structured
        ndisp += em.dispatched
        for key, v in em.unsupported.items():
            unsupported[key] += v
    reg = ["// Generated by tools/x86rec.py. Do not edit.", "package rec", "", 'import "../x86"', 'import "../native"']
    reg += ['import "%s"' % n for n in names]
    reg += ["", "register :: proc() {"]
    reg += ["\tx86.register_funcs(%s.FUNCS[:])" % n for n in names]
    reg += ["\tnative.register()", "}"]
    with open(os.path.join(out_dir, "rec.odin"), "w") as fp:
        fp.write("\n".join(reg) + "\n")
    nentries = sum(len(f.entries) for f in funcs)
    print("functions %d, entries %d, instructions %d, packages %d, data pointers rejected %d"
          % (len(funcs), nentries, total, len(pkgs), rejected))
    print("%d functions structured, %d dispatched" % (nstruct, ndisp))
    for key, v in sorted(unsupported.items(), key=lambda x: -x[1]):
        print("unsupported %6d %s" % (v, key))


if __name__ == "__main__":
    main()
