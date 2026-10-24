#!/usr/bin/env python3
"""Recover the NWScript command table: action id -> handler address.
WHY: docs/modding.md §2

Usage: dis.py JadeEmpire.exe 0x4a0e50 0x4a33d0 | cmdtable.py > re/nwscript_handlers.tsv

FUN_004a0e50 (CVirtualMachineCommands setup) allocates 0x108c bytes, one
handler pointer per action id, and fills them with stores of the form
  mov REG, [esi + 0x10] ; mov dword ptr [REG + 4*id], HANDLER
where HANDLER is an immediate or a register loaded with one earlier. The
ACTION opcode's id indexes this table, so it is the ground truth that
re/nwscript_functions.tsv (names from xoreos) is checked against.
"""
import re
import sys

TABLE_BYTES = 0x108C
MOV_IMM = re.compile(r"mov (e[a-z]{2}), 0x([0-9a-f]+)$")
MOV_ANY = re.compile(r"mov (e[a-z]{2}), ")
BASE = re.compile(r"mov (e[a-z]{2}), dword ptr \[esi \+ 0x10\]$")
# The disassembler prints offsets below 10 in decimal and omits a zero offset.
STORE = re.compile(r"mov dword ptr \[(e[a-z]{2})(?: \+ (0x[0-9a-f]+|\d+))?\], (?:0x([0-9a-f]+)|(e[a-z]{2}))$")


def parse(lines):
    regs, bases, table = {}, set(), {}
    for line in lines:
        insn = line[10:].strip()
        m = STORE.match(insn)
        if m and m.group(1) in bases:
            off = int(m.group(2) or "0", 0)
            assert off % 4 == 0 and off < TABLE_BYTES, line
            val = int(m.group(3), 16) if m.group(3) else regs.get(m.group(4))
            if val is None:
                raise SystemExit("store from unknown register: %s" % line)
            table[off // 4] = val
            continue
        m = BASE.match(insn)
        if m:
            regs.pop(m.group(1), None)
            bases.add(m.group(1))
            continue
        m = MOV_IMM.match(insn)
        if m:
            regs[m.group(1)] = int(m.group(2), 16)
            bases.discard(m.group(1))
        elif MOV_ANY.match(insn):
            regs.pop(MOV_ANY.match(insn).group(1), None)
            bases.discard(MOV_ANY.match(insn).group(1))
    return table


def main():
    table = parse(sys.stdin.read().splitlines())
    print("# action id -> handler, from FUN_004a0e50 (tools/cmdtable.py)")
    print("id\thandler")
    for i in sorted(table):
        print("%d\t%#x" % (i, table[i]))
    print("%d ids filled of %d" % (len(table), TABLE_BYTES // 4), file=sys.stderr)


if __name__ == "__main__":
    main()
