#+feature dynamic-literals
package x86rec

import "core:fmt"
import "core:slice"
import "core:strings"

CF :: 1
PF :: 2
AF :: 4
ZF :: 8
SF :: 16
OF :: 32
ALL :: 63

Cond :: struct {
	reads: u8,
	expr:  string,
}

// Condition code -> (flags read, expression over c.* flags).
COND := map[string]Cond {
	"o"  = {OF, "c.of"},
	"no" = {OF, "!c.of"},
	"b"  = {CF, "c.cf"},
	"ae" = {CF, "!c.cf"},
	"e"  = {ZF, "c.zf"},
	"ne" = {ZF, "!c.zf"},
	"be" = {CF | ZF, "(c.cf || c.zf)"},
	"a"  = {CF | ZF, "(!c.cf && !c.zf)"},
	"s"  = {SF, "c.sf"},
	"ns" = {SF, "!c.sf"},
	"p"  = {PF, "c.pf"},
	"np" = {PF, "!c.pf"},
	"l"  = {SF | OF, "(c.sf != c.of)"},
	"ge" = {SF | OF, "(c.sf == c.of)"},
	"le" = {ZF | SF | OF, "(c.zf || c.sf != c.of)"},
	"g"  = {ZF | SF | OF, "(!c.zf && c.sf == c.of)"},
}

// The condition code of a setcc mnemonic, or "".
setcc_cond :: proc(m: string) -> string {
	if !strings.has_prefix(m, "set") do return ""
	c := m[3:]
	return c in COND ? c : ""
}

// The last word of a mnemonic: "rep movsd" -> "movsd".
mnem_base :: proc(m: string) -> string {
	k := strings.last_index_byte(m, ' ')
	return m[k + 1:]
}

// The count of a shift by its second operand: 1 without one, the
// immediate & 31, or false for cl.
shift_count :: proc(i: ^Insn) -> (int, bool) {
	if i.nops <= 1 do return 1, true
	op := &i.ops[1]
	if op.type == OP_IMM do return int(op.imm & 31), true
	return 0, false
}

in_list :: proc(s: string, list: []string) -> bool {
	for v in list do if s == v do return true
	return false
}

// (uses, defs) flag masks of one instruction.
flag_effect :: proc(i: ^Insn) -> (u8, u8) {
	m := i.mnemonic
	base := mnem_base(m)
	if c := jcc_cond(m); c != "" do return COND[c].reads, 0
	if c := setcc_cond(m); c != "" do return COND[c].reads, 0
	switch {
	case in_list(base, {"add", "sub", "cmp", "neg", "and", "or", "xor", "test", "imul", "mul", "div", "idiv", "popfd", "xadd"}):
		return 0, ALL
	case base == "adc" || base == "sbb":
		return CF, ALL
	case base == "inc" || base == "dec":
		return 0, ALL & ~u8(CF)
	case in_list(base, {"shl", "sal", "shr", "sar", "shld", "shrd"}):
		n: int
		ok: bool
		if base == "shld" || base == "shrd" {
			if i.ops[2].type == OP_IMM do n, ok = int(i.ops[2].imm & 31), true
		} else {
			n, ok = shift_count(i)
		}
		// A count in cl may be 0, which leaves every flag unchanged: the flags
		// are a may-def, so they neither read nor kill (live-in = live-out).
		if n == 0 || !ok do return 0, 0
		return 0, ALL
	case base == "rol" || base == "ror":
		n, ok := shift_count(i)
		if n == 0 || !ok do return 0, 0
		return 0, CF | OF
	case base == "rcl" || base == "rcr":
		n, ok := shift_count(i)
		if ok && n == 0 do return 0, 0
		return CF, ok ? CF | OF : 0
	case in_list(base, {"bt", "bts", "btr", "btc"}):
		return 0, CF
	case base == "sahf":
		return 0, ALL & ~u8(OF)
	case base == "lahf":
		return ALL & ~u8(OF), 0
	case base == "pushfd":
		return ALL, 0
	case in_list(base, {"cmpsb", "cmpsw", "cmpsd", "scasb", "scasw", "scasd"}) && i.nops > 0:
		return strings.has_prefix(m, "rep") ? ALL : 0, ALL
	case in_list(base, {"fucomi", "fcomi", "fucomip", "fcomip", "ucomiss", "comiss", "ucomisd", "comisd"}):
		return 0, ALL
	case base == "clc" || base == "stc":
		return 0, CF
	case base == "cmc":
		return CF, CF
	case base == "call":
		return 0, ALL
	}
	return 0, 0
}

// Targets outside f that control leaves to after instruction k of f (tail
// calls), in the order the analyses visit them.
exits_of :: proc(f: ^Func, k: int, out: ^[dynamic]u32) {
	p, i := f.pcs[k], f.code[k]
	kind, t := control(i)
	if (kind == .Jmp || kind == .Jcc) && !inside(f, t) do append(out, t)
	if es, ok := f.tables[p]; ok {
		for e in es do if !inside(f, e) do append(out, e)
	}
	nxt := p + u32(i.size)
	if kind != .Jmp && kind != .Ijmp && kind != .Ret && i.mnemonic != "int3" && i.mnemonic != "ud2" && !inside(f, nxt) {
		append(out, nxt)
	}
}

// Per-function facts the analyses share, set by finish_flow: by f.pcs
// index, the transfer, its exits and its successors' indices (-1 for one
// that is no decoded pc of f); funcs[k] owns the entries with
// owner_of[e - TEXT_LO] == k (the last function to list one).
Flow :: struct {
	kind:  []Kind,
	tgt:   []u32,
	exits: [][]u32,
	succ:  [][]i32, // f.pcs indices
}

funcs: []^Func
flows: []Flow
owner_of: []i32 // by address - TEXT_LO: index into funcs of the owner, or -1

owner :: proc(t: u32) -> i32 {
	return text(t) ? owner_of[t - TEXT_LO] : -1
}

// Index of p in f.pcs, or -1.
pc_index :: proc(f: ^Func, p: u32) -> i32 {
	k, ok := slice.binary_search(f.pcs, p)
	return ok ? i32(k) : -1
}

finish_flow :: proc() {
	owner_of = make([]i32, TEXT_HI - TEXT_LO)
	for &v in owner_of do v = -1
	flows = make([]Flow, len(funcs))
	for f, n in funcs {
		for e in f.entries {
			assert(text(e))
			owner_of[e - TEXT_LO] = i32(n)
		}
	}
	ex: [dynamic]u32
	defer delete(ex)
	for f, n in funcs {
		fl := &flows[n]
		m := len(f.pcs)
		fl.kind = make([]Kind, m)
		fl.tgt = make([]u32, m)
		fl.exits = make([][]u32, m)
		fl.succ = make([][]i32, m)
		for k in 0 ..< m {
			s := f.succs[k]
			if len(s) > 0 {
				fl.succ[k] = make([]i32, len(s))
				for v, j in s do fl.succ[k][j] = pc_index(f, v)
			}
			if f.code[k] == nil do continue
			fl.kind[k], fl.tgt[k] = control(f.code[k])
			clear(&ex)
			exits_of(f, k, &ex)
			if len(ex) > 0 do fl.exits[k] = slice_clone(ex[:])
		}
	}
}

slice_clone :: proc(s: []$T) -> []T {
	out := make([]T, len(s))
	copy(out, s)
	return out
}

// Bits of a liveness problem: effect(f, k) -> (use, def) of instruction k;
// unknown: bits read by a transfer to an address that is no entry;
// keeps(t): bits a tail transfer to t leaves as they were, so those live at
// f's ret are live at the transfer; hidden(t): bits of entry_live[t] that
// are no read of the caller's value.
Live_Problem :: struct {
	effect:   proc(n: int, k: int) -> (u8, u8),
	unknown:  u8,
	keeps:    proc(t: u32) -> u8,
	hidden:   proc(t: u32) -> u8,
	ret_init: []u8, // by funcs index, or nil
}

no_bits :: proc(t: u32) -> u8 {
	return 0
}

Live_Result :: struct {
	entry_live: []u8, // by address - TEXT_LO, entries only
	ret_live:   []u8, // by funcs index
	live_out:   [][]u8, // by funcs index, then f.pcs index
}

entry_bits :: proc(r: ^Live_Result, lp: ^Live_Problem, t: u32) -> u8 {
	return owner(t) >= 0 ? r.entry_live[t - TEXT_LO] : lp.unknown
}

// (live_in, live_out) bits of each instruction of funcs[n].
liveness :: proc(n: int, eff_u, eff_d, extra, live_in, live_out: []u8, r: ^Live_Result, lp: ^Live_Problem) {
	f, fl := funcs[n], &flows[n]
	rl := r.ret_live[n]
	for k in 0 ..< len(f.pcs) {
		live_in[k] = 0
		if f.code[k] == nil do continue
		u, d := lp.effect(n, k)
		kind := fl.kind[k]
		if kind == .Call {
			t := fl.tgt[k]
			u |= entry_bits(r, lp, t) & ~lp.hidden(t)
		}
		x := kind == .Ret ? rl : 0
		for t in fl.exits[k] do x |= entry_bits(r, lp, t) & ~lp.hidden(t) | (rl & lp.keeps(t))
		eff_u[k], eff_d[k], extra[k] = u, d, x
	}
	m := len(f.live_pcs)
	converged := false
	for _ in 0 ..< m + 2 {
		changed := false
		#reverse for _, k in f.pcs {
			if f.code[k] == nil do continue
			out := extra[k]
			for s in fl.succ[k] do if s >= 0 do out |= live_in[s]
			v := eff_u[k] | (out & ~eff_d[k])
			if v != live_in[k] {
				live_in[k] = v
				changed = true
			}
		}
		if !changed {
			converged = true
			break
		}
	}
	fmt.assertf(converged, "liveness did not converge in %08x", f.start)
	for k in 0 ..< len(f.pcs) {
		live_out[k] = 0
		if f.code[k] == nil do continue
		out := extra[k]
		for s in fl.succ[k] do if s >= 0 do out |= live_in[s]
		live_out[k] = out
	}
}

// Interprocedural fixpoint of liveness().
reg_liveness :: proc(lp: ^Live_Problem) -> Live_Result {
	r: Live_Result
	r.entry_live = make([]u8, TEXT_HI - TEXT_LO)
	r.ret_live = make([]u8, len(funcs))
	if lp.ret_init != nil do copy(r.ret_live, lp.ret_init)
	r.live_out = make([][]u8, len(funcs))
	// deps[n]: functions to revisit when funcs[n] changes.
	deps := make([]Set, len(funcs))
	defer {
		for &d in deps do delete(d)
		delete(deps)
	}
	for f, n in funcs {
		fl := &flows[n]
		for k in 0 ..< len(f.pcs) {
			if f.code[k] == nil do continue
			add :: proc(deps: []Set, n: int, t: u32) {
				g := owner(t)
				if g < 0 do return
				set_add(&deps[g], u32(n)) // n reads g's entry bits
				set_add(&deps[n], u32(g)) // g's returns serve n's call/tail
			}
			if fl.kind[k] == .Call do add(deps, n, fl.tgt[k])
			for x in fl.exits[k] do add(deps, n, x)
		}
	}
	work := make([dynamic]i32, len(funcs))
	queued := make([]bool, len(funcs))
	defer delete(work)
	defer delete(queued)
	for n in 0 ..< len(funcs) {
		work[n] = i32(n)
		queued[n] = true
	}
	most := 0
	for f in funcs do most = max(most, len(f.pcs))
	eff_u, eff_d, extra, live_in := make([]u8, most), make([]u8, most), make([]u8, most), make([]u8, most)
	defer {
		delete(eff_u)
		delete(eff_d)
		delete(extra)
		delete(live_in)
	}
	touched: [dynamic]i32
	defer delete(touched)
	converged := false
	for _ in 0 ..< 64 * len(funcs) + 1 {
		if len(work) == 0 {
			converged = true
			break
		}
		n := int(pop(&work))
		queued[n] = false
		f, fl := funcs[n], &flows[n]
		m := len(f.pcs)
		if r.live_out[n] == nil do r.live_out[n] = make([]u8, m)
		live_out := r.live_out[n]
		liveness(n, eff_u[:m], eff_d[:m], extra[:m], live_in[:m], live_out, &r, lp)
		clear(&touched)
		for e in f.entries {
			j := pc_index(f, e)
			v := j >= 0 ? live_in[j] : 0
			if v != r.entry_live[e - TEXT_LO] {
				r.entry_live[e - TEXT_LO] = v
				append(&touched, i32(n))
			}
		}
		rl := r.ret_live[n]
		for k in 0 ..< m {
			if f.code[k] == nil do continue
			serve :: proc(r: ^Live_Result, lp: ^Live_Problem, t: u32, v: u8, touched: ^[dynamic]i32, work: ^[dynamic]i32, queued: []bool) {
				g := owner(t)
				v := v & ~lp.keeps(t)
				if g >= 0 && v & ~r.ret_live[g] != 0 {
					r.ret_live[g] |= v
					append(touched, g)
					if !queued[g] {
						append(work, g)
						queued[g] = true
					}
				}
			}
			if fl.kind[k] == .Call do serve(&r, lp, fl.tgt[k], live_out[k], &touched, &work, queued)
			for x in fl.exits[k] do serve(&r, lp, x, rl, &touched, &work, queued)
		}
		for t in touched {
			for g in deps[t] {
				if !queued[g] {
					append(&work, i32(g))
					queued[g] = true
				}
			}
		}
	}
	assert(converged, "liveness did not converge")
	return r
}

flag_live: [][]u8 // by funcs index, then f.pcs index: flags live after it

// Sets flag_live; returns the flag problem's result.
flag_liveness :: proc() -> Live_Result {
	lp := Live_Problem {
		effect = proc(n: int, k: int) -> (u8, u8) {return flag_effect(funcs[n].code[k])},
		keeps = no_bits,
		hidden = no_bits,
	}
	r := reg_liveness(&lp)
	flag_live = r.live_out
	return r
}

// Indirect calls are modeled as passing no flags back. Fail if any code
// after one reads a flag before writing it (docs/recompiler.md §3).
check_indirect_calls :: proc() {
	for f, n in funcs {
		for k in 0 ..< len(f.pcs) {
			if f.code[k] != nil && flows[n].kind[k] == .Icall && flag_live[n][k] != 0 {
				fmt.panicf("flags %x read after indirect call at %08x", flag_live[n][k], f.pcs[k])
			}
		}
	}
}
