"""Recursive-descent inventory of unpacked JadeEmpire.exe .text.

Seeds: Ghidra function starts (funcs.txt) + OEP. Follows direct branches/calls,
records instruction mix, indirect branches, switch tables, coverage.
"""
import sys, collections, struct, json
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CS_GRP_JUMP, CS_GRP_CALL, CS_GRP_RET
from capstone.x86 import X86_OP_MEM, X86_OP_IMM, X86_OP_REG

exe, funcs_path, out_path = sys.argv[1:4]
pe = pefile.PE(exe)
base = pe.OPTIONAL_HEADER.ImageBase
img = bytearray(pe.get_memory_mapped_image())
TEXT_LO, TEXT_HI = 0x401000, 0x6e1000
DATA_LO, DATA_HI = 0x6e1000, 0x895000
IAT_LO, IAT_HI = 0x6e1000, 0x6e1000 + 0x400

def u32(va): return struct.unpack_from("<I", img, va - base)[0]

md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
seeds = [int(l.split()[0], 16) for l in open(funcs_path) if l.strip()]
seeds = [s for s in seeds if TEXT_LO <= s < TEXT_HI] + [0x6b4923]
ghidra_seeds = set(seeds)
# Extra seeds: every aligned .data dword that points into .text (vtables,
# EH unwind maps, CRT init tables, callbacks). Switch tables live in .text.
data_ptrs = set()
for va in range(DATA_LO, DATA_HI - 3, 4):
    v = u32(va)
    if TEXT_LO <= v < TEXT_HI: data_ptrs.add(v)
if "--data-seeds" in sys.argv: seeds += sorted(data_ptrs - ghidra_seeds)

covered = bytearray(TEXT_HI - TEXT_LO)
mn = collections.Counter(); groups = collections.Counter()
ind_call = collections.Counter(); ind_jmp = collections.Counter()
switches = {}; call_targets = set(); seen_insn = set()
work = list(seeds); fstarts = set(seeds); MAX_INSN = 3_000_000
n = 0
while work and n < MAX_INSN:
    pc = work.pop()
    for _ in range(100000):
        if not (TEXT_LO <= pc < TEXT_HI) or pc in seen_insn: break
        code = bytes(img[pc - base: pc - base + 16])
        ins = next(md.disasm(code, pc), None)
        if ins is None: break
        seen_insn.add(pc); n += 1
        for b in range(ins.size): covered[pc - TEXT_LO + b] = 1
        mn[ins.mnemonic] += 1
        nxt = pc + ins.size
        isjmp = ins.group(CS_GRP_JUMP); iscall = ins.group(CS_GRP_CALL)
        if ins.group(CS_GRP_RET) or ins.mnemonic in ("hlt", "int3", "ud2"): break
        if isjmp or iscall:
            op = ins.operands[0]
            if op.type == X86_OP_IMM:
                t = op.imm
                if iscall:
                    call_targets.add(t); fstarts.add(t); work.append(t)
                else:
                    work.append(t)
                if ins.mnemonic == "jmp": break
            else:
                kind = "reg" if op.type == X86_OP_REG else "mem"
                if op.type == X86_OP_MEM:
                    m = op.mem
                    if m.base == 0 and m.index == 0 and IAT_LO <= m.disp < IAT_HI:
                        kind = "iat"
                    elif m.base == 0 and m.index != 0 and m.scale == 4 and isjmp:
                        kind = "table"
                    elif m.base != 0 and m.index == 0:
                        kind = "vcall[reg+disp]"
                (ind_call if iscall else ind_jmp)[kind] += 1
                if kind == "table":
                    # MSVC switch: entries until a non-text value
                    tbl = m.disp; ents = []
                    for i in range(4096):
                        v = u32(tbl + 4 * i)
                        if not (TEXT_LO <= v < TEXT_HI) or (i and tbl + 4*i in switches): break
                        ents.append(v)
                    switches[tbl] = (pc, len(ents))
                    for e in ents: work.append(e)
                    for b in range(4 * len(ents)):
                        if TEXT_LO <= tbl + b < TEXT_HI: covered[tbl + b - TEXT_LO] = 1
                if isjmp: break
        pc = nxt

# x87 / SSE classification
x87 = sum(c for k, c in mn.items() if k.startswith("f") and k not in ("fxsave", "fxrstor"))
sse = sum(c for k, c in mn.items() if any(k.endswith(s) for s in ("ps", "ss", "pd", "sd")) and not k.startswith("f") and k not in ("movsd",) or k.startswith("cvt") or k.startswith("movaps") or k.startswith("movups"))
mmx = sum(c for k, c in mn.items() if k.startswith("p") and k not in ("push", "pop", "pushal", "popal", "pushfd", "popfd", "pause"))
strops = sum(c for k, c in mn.items() if k.startswith("rep") or k in ("movsb", "movsd", "movsw", "stosb", "stosd", "stosw", "lodsb", "scasb", "cmpsb"))

# vtable candidates in .data: runs >=3 of pointers to known function starts
vt = []; va = DATA_LO
while va < DATA_HI - 4:
    run = 0
    while va + 4 * run < DATA_HI and u32(va + 4 * run) in fstarts: run += 1
    if run >= 3: vt.append((va, run)); va += 4 * run
    else: va += 4

res = dict(
    insns=n, seeds=len(seeds), fstarts=len(fstarts),
    covered_bytes=sum(covered), text_bytes=TEXT_HI - TEXT_LO,
    top_mnemonics=mn.most_common(), x87=x87, sse=sse, mmx_like=mmx, strops=strops,
    ind_call=dict(ind_call), ind_jmp=dict(ind_jmp),
    switch_tables=len(switches), switch_entries=sum(v[1] for v in switches.values()),
    vtable_runs=len(vt), vtable_slots=sum(r for _, r in vt),
    biggest_vtables=sorted(vt, key=lambda x: -x[1])[:20],
    new_fstarts_not_in_ghidra=len(fstarts - ghidra_seeds), data_text_ptrs=len(data_ptrs), data_ptrs_not_ghidra=len(data_ptrs - ghidra_seeds), direct_call_targets=len(call_targets), call_targets_not_ghidra=len(call_targets - ghidra_seeds),
)
json.dump(res, open(out_path, "w"), indent=1)
# uncovered gaps for later inspection
gaps = []; i = 0
while i < len(covered):
    if not covered[i]:
        j = i
        while j < len(covered) and not covered[j]: j += 1
        if j - i >= 16: gaps.append((TEXT_LO + i, j - i))
        i = j
    else: i += 1
json.dump(gaps, open(out_path + ".gaps", "w"))
print(json.dumps({k: v for k, v in res.items() if k not in ("top_mnemonics", "biggest_vtables")}, indent=1))
