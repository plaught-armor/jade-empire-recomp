"""Count IDirect3DDevice9 vtable slots called via the device global.
Tracks per basic linear run: reg <- [DEV]; reg2 <- [reg]; call [reg2+off]."""
import sys, collections, pefile
from capstone import *
from capstone.x86 import *
exe, funcs, dev = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
pe = pefile.PE(exe); img = pe.get_memory_mapped_image(); base = 0x400000
md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
seeds = sorted(int(l.split()[0], 16) for l in open(funcs))
slots = collections.Counter()
for s in seeds:
    if not 0x401000 <= s < 0x6e1000: continue
    devreg, vtreg = set(), set()
    for ins in md.disasm(img[s-base:s-base+0x4000], s):
        ops = ins.operands
        if ins.mnemonic == "mov" and len(ops) == 2 and ops[0].type == X86_OP_REG:
            d, src = ops[0].reg, ops[1]
            devreg.discard(d); vtreg.discard(d)
            if src.type == X86_OP_MEM and src.mem.base == 0 and src.mem.index == 0 and src.mem.disp == dev:
                devreg.add(d)
            elif src.type == X86_OP_MEM and src.mem.base in devreg and src.mem.disp == 0 and src.mem.index == 0:
                vtreg.add(d)
        elif ins.mnemonic == "call" and ops[0].type == X86_OP_MEM and ops[0].mem.base in vtreg:
            slots[ops[0].mem.disp // 4] += 1
        if ins.mnemonic == "ret": break
for k, v in sorted(slots.items()): print(k, v)
