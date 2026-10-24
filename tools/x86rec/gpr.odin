package x86rec

import cs "../capstone"
import "../pe"
import "core:strings"

// Register liveness decides which promoted registers a call or return must
// store to x86.cpu, and which a call must reload. A direct call stores what
// the callee reads at entry and reloads what it, or anything it calls, may
// write; a return stores what a caller reads after it. Bits follow R32.
// WHY: docs/recompiler.md §2
ALL_GPR :: 0xFF

R32 := [8]string{"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"}

Gpr_Bit :: struct {
	bit:  u8,
	full: bool, // the name covers all 32 bits
}

// Register name -> its bit, for the 32-, 16- and 8-bit names.
gpr_bit :: proc(n: string) -> (Gpr_Bit, bool) {
	switch n {
	case "eax": return {1, true}, true
	case "ecx": return {2, true}, true
	case "edx": return {4, true}, true
	case "ebx": return {8, true}, true
	case "esp": return {16, true}, true
	case "ebp": return {32, true}, true
	case "esi": return {64, true}, true
	case "edi": return {128, true}, true
	case "ax", "al", "ah": return {1, false}, true
	case "cx", "cl", "ch": return {2, false}, true
	case "dx", "dl", "dh": return {4, false}, true
	case "bx", "bl", "bh": return {8, false}, true
	case "sp": return {16, false}, true
	case "bp": return {32, false}, true
	case "si": return {64, false}, true
	case "di": return {128, false}, true
	}
	return {}, false
}

// Writes that may leave the old value in place, so the destination is a use.
MAY_WRITE := []string{"bsf", "bsr", "cmpxchg"}

// (use, def, mod) GPR bits of i: read, always overwritten, possibly
// written. read, write: capstone's register access lists.
gpr_effect :: proc(i: ^Insn, read, write: []u16) -> (u8, u8, u8) {
	wrote :: proc(write: []u16, n: string) -> bool {
		for x in write do if reg_names[x] == n do return true
		return false
	}
	use, kill, mod: u8
	m := i.mnemonic
	base := mnem_base(m)
	may := strings.has_prefix(m, "rep") || strings.has_prefix(m, "cmov") || in_list(base, MAY_WRITE)
	for x in read {
		if b, ok := gpr_bit(reg_names[x]); ok do use |= b.bit
	}
	// capstone leaves some operand reads out (`test [m], al`): an operand
	// register it does not list as written is read.
	for &op in i.ops[:i.nops] {
		if op.type == cs.OP_REG && !wrote(write, reg_names[op.reg]) {
			if b, ok := gpr_bit(reg_names[op.reg]); ok do use |= b.bit
		} else if op.type == cs.OP_MEM {
			for x in ([2]u32{op.base, op.index}) {
				if x == 0 do continue
				if b, ok := gpr_bit(reg_names[x]); ok do use |= b.bit
			}
		}
	}
	for x in write {
		b, ok := gpr_bit(reg_names[x])
		if !ok do continue
		mod |= b.bit
		if b.full && !may {
			kill |= b.bit
		} else {
			use |= b.bit
		}
	}
	// Writes whose result does not depend on the register's old value:
	// `xor r, r`, `sub r, r`, `sbb r, r` (0 or -1 from CF), `and r, 0`,
	// `or r, -1`.
	ops := i.ops[:i.nops]
	if len(ops) == 2 && ops[0].type == cs.OP_REG {
		same := ops[1].type == cs.OP_REG && ops[1].reg == ops[0].reg && (base == "xor" || base == "sub" || base == "sbb")
		imm := ops[1].type == cs.OP_IMM && (base == "and" && u32(ops[1].imm) == 0 || base == "or" && u32(ops[1].imm) == 0xFFFFFFFF)
		if same || imm {
			if b, ok := gpr_bit(reg_names[ops[0].reg]); ok && b.full do use &= ~b.bit
		}
	}
	// Accesses capstone does not report.
	switch base {
	case "cmpxchg":
		use |= 1; mod |= 1
	case "xlatb":
		use |= 1 | 8; mod |= 1
	case "enter":
		use |= 16 | 32; mod |= 16 | 32
	}
	return use, kill, mod
}

unknown_jump :: proc(f: ^Func, p: u32, kind: Kind) -> bool {
	return kind == .Icall || kind == .Ijmp && !(p in f.tables)
}

// By funcs index: GPR bits the function, or anything it calls or
// tail-jumps to, may write.
gpr_mod :: proc() -> []u8 {
	mod := make([]u8, len(funcs))
	callers := make([]Set, len(funcs))
	defer {
		for &c in callers do delete(c)
		delete(callers)
	}
	for f, n in funcs {
		fl := &flows[n]
		m: u8
		for k in 0 ..< len(f.pcs) {
			i := f.code[k]
			if i == nil do continue
			m |= i.mod
			if unknown_jump(f, f.pcs[k], fl.kind[k]) do m = ALL_GPR
			reach :: proc(callers: []Set, n: int, t: u32, m: ^u8) {
				g := owner(t)
				if g < 0 {
					m^ = ALL_GPR
				} else if int(g) != n {
					set_add(&callers[g], u32(n))
				}
			}
			if fl.kind[k] == .Call do reach(callers, n, fl.tgt[k], &m)
			for t in fl.exits[k] do reach(callers, n, t, &m)
		}
		mod[n] = m
	}
	work := make([dynamic]i32, len(funcs))
	defer delete(work)
	for n in 0 ..< len(funcs) do work[n] = i32(n)
	converged := false
	for _ in 0 ..< 9 * len(funcs) + 1 {
		if len(work) == 0 {
			converged = true
			break
		}
		g := pop(&work)
		for a in callers[g] {
			v := mod[a] | mod[g]
			if v != mod[a] {
				mod[a] = v
				append(&work, i32(a))
			}
		}
	}
	assert(converged, "register mod sets did not converge")
	return mod
}

// Entries other code may reach without a direct call or jump, so a caller
// the analysis does not see may read any register after they return: the
// program entry, any entry whose address is a 32-bit word in the image below
// DATA_SCAN_HI outside the IAT (function pointers, vtables, immediates), and
// any entry no direct transfer reaches. The bound and the IAT skip keep the
// Steam and GOG exes alike (see data_pointers).
taken_entries :: proc() -> Set {
	entries: Set
	defer delete(entries)
	for f in funcs do for e in f.entries do set_add(&entries, e)
	taken: Set
	hi := int(DATA_SCAN_HI - img.base)
	for k in 0 ..< 4 {
		for o := k; o + 4 <= hi; o += 4 {
			// A word touching an IAT slot.
			slot := (img.base + u32(o)) &~ 3
			if slot in img.iat || (k != 0 && slot + 4 in img.iat) do continue
			v := pe.le32(img.data, o)
			if v in entries do set_add(&taken, v)
		}
	}
	direct: Set
	defer delete(direct)
	for f, n in funcs {
		fl := &flows[n]
		for k in 0 ..< len(f.pcs) {
			if f.code[k] == nil do continue
			if fl.kind[k] == .Call || fl.kind[k] == .Jmp || fl.kind[k] == .Jcc do set_add(&direct, fl.tgt[k])
			for t in fl.exits[k] do set_add(&direct, t)
		}
	}
	set_add(&taken, OEP)
	for e in entries do if !(e in direct) do set_add(&taken, e)
	return taken
}

// Inputs of the GPR problem's callbacks, which cannot close over them.
@(private = "file")
g_mod: []u8
@(private = "file")
g_transp: map[u32]u8

@(private = "file")
gpr_keeps :: proc(t: u32) -> u8 {
	g := owner(t)
	return g < 0 ? 0 : ALL_GPR & ~g_mod[g] | g_transp[t]
}

@(private = "file")
gpr_hidden :: proc(t: u32) -> u8 {
	return g_transp[t]
}

@(private = "file")
gpr_step :: proc(n: int, k: int) -> (u8, u8) {
	f, fl := funcs[n], &flows[n]
	i := f.code[k]
	if fl.kind[k] == .Call do return i.use, ALL_GPR & ~gpr_keeps(fl.tgt[k])
	if unknown_jump(f, f.pcs[k], fl.kind[k]) do return ALL_GPR, 0
	return i.use, i.kill
}

// GPR liveness and the count of functions with a taken entry. mod:
// gpr_mod(); transp: entry -> bits it is transparent in.
gpr_liveness :: proc(mod: []u8, transp: map[u32]u8) -> (Live_Result, int) {
	g_mod, g_transp = mod, transp
	taken := taken_entries()
	defer delete(taken)
	ret_init := make([]u8, len(funcs))
	defer delete(ret_init)
	ntaken := 0
	for f, n in funcs {
		for e in f.entries {
			if e in taken {
				ret_init[n] = ALL_GPR
				ntaken += 1
				break
			}
		}
	}
	lp := Live_Problem {
		effect   = gpr_step,
		unknown  = ALL_GPR,
		keeps    = gpr_keeps,
		hidden   = gpr_hidden,
		ret_init = ret_init,
	}
	return reg_liveness(&lp), ntaken
}
