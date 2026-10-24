package x86rec

// A register an entry saves and restores, reading its entry value only to save
// it, is transparent: a direct call to that entry neither stores nor reloads
// it. An abstract interpretation per entry follows each entry value through
// registers and stack slots at known esp offsets. WHY: docs/recompiler.md §2

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

ESP :: 4
EBP :: 5
SAVED :: ALL_GPR & ~u8(1 << ESP)
INLINE_MAX :: 32 // instructions of a straight-line callee interpreted in place
ARG_POP_MAX :: 64 // bytes of arguments an indirect callee may pop
// Registers a host function may read or write: the guest ABI's scratch ones.
// Host code changes no other register; control.odin restores the whole cpu.
HOST_REGS :: 0x7 // eax, ecx, edx

// esp deltas of the instructions that move it by a fixed amount.
fixed_step :: proc(m: string) -> (i64, bool) {
	switch m {
	case "pushfd": return -4, true
	case "popfd": return 4, true
	case "pushal", "pushad": return -32, true
	case "popal", "popad": return 32, true
	}
	return 0, false
}

s32 :: proc(v: i64) -> i64 {
	return i64(i32(u32(v & 0xFFFFFFFF)))
}

// The exact value a word holds: unknown, entry value of register x, stack
// offset x, constant x, the word at absolute address x, or return address x.
Vk :: enum u8 {
	None,
	E,
	S,
	C,
	M,
	A,
}

// A word: its exact value (x is 0 when k is None) and the entry values it
// may hold, as GPR bits. Taints are wider than a byte: step_inline sums them
// as the original did, and the carries are part of the result.
Val :: struct {
	k: Vk,
	x: i64,
	t: u32,
}

NONE :: Val{}

// An esp offset from the entry value, or unknown (v 0).
Off :: struct {
	v:  i64,
	ok: bool,
}

NO_OFF :: Off{}

off :: proc(v: i64) -> Off {
	return {v, true}
}

Slot :: struct {
	a: i64,
	v: Val,
}

// Abstract machine state before an instruction; slots sorted by offset.
State :: struct {
	o:     Off,
	regs:  [8]Val,
	slots: []Slot,
}

// R32 index of a 32-bit register operand, or -1.
reg_index :: proc(op: ^Cs_Op) -> int {
	if op.type != OP_REG do return -1
	n := reg_names[op.reg]
	for r, k in R32 do if r == n do return k
	return -1
}

r32_of :: proc(reg: u32) -> int {
	n := reg_names[reg]
	for r, k in R32 do if r == n do return k
	fmt.panicf("%s is no 32-bit register", n)
}

Step_Kind :: enum u8 {
	Unknown,
	Delta, // esp += d
	Reg, // esp = R32[k] + d
	Leave,
}

Step :: struct {
	kind: Step_Kind,
	k:    int,
	d:    i64,
}

// How i moves esp, calls and returns aside.
esp_step :: proc(i: ^Insn) -> Step {
	m, ops := i.mnemonic, i.ops[:i.nops]
	if m == "push" do return {.Delta, 0, -i64(ops[0].size)}
	if m == "pop" {
		if reg_index(&ops[0]) == ESP do return {}
		return {.Delta, 0, i64(ops[0].size)}
	}
	if d, ok := fixed_step(m); ok do return {.Delta, 0, d}
	if m == "leave" do return {kind = .Leave}
	if i.mod & (1 << ESP) == 0 do return {.Delta, 0, 0}
	if len(ops) == 0 || reg_index(&ops[0]) != ESP do return {}
	if (m == "add" || m == "sub") && ops[1].type == OP_IMM {
		return {.Delta, 0, s32(ops[1].imm) * (m == "add" ? 1 : -1)}
	}
	if m == "mov" && reg_index(&ops[1]) >= 0 do return {.Reg, reg_index(&ops[1]), 0}
	if m == "lea" && ops[1].index == 0 && ops[1].segment == 0 && ops[1].base != 0 {
		return {.Reg, r32_of(ops[1].base), s32(ops[1].disp)}
	}
	return {}
}

// The literal n of `ret(n, ...)` text from just past "ret(" to the next
// comma, as the regex `\bret\(([^,]+),` captures it, or false.
@(private = "file")
next_ret :: proc(body: string, from: ^int) -> (string, bool) {
	for from^ < len(body) {
		k := strings.index(body[from^:], "ret(")
		if k < 0 {
			from^ = len(body)
			return "", false
		}
		at := from^ + k
		from^ = at + 1
		if at > 0 {
			c := body[at - 1]
			if c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' do continue
		}
		rest := body[at + 4:]
		comma := strings.index_byte(rest, ',')
		if comma <= 0 do continue
		from^ = at + 4 + comma + 1
		return rest[:comma], true
	}
	return "", false
}

ident_byte :: proc(c: u8) -> bool {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// Matches `{"dll!name", proc}` at s[k:]: (import, proc name, end).
@(private = "file")
table_row :: proc(s: string, k: int) -> (string, string, int, bool) {
	j := k + 2
	for j < len(s) && (s[j] == '_' || s[j] == '.' || s[j] >= '0' && s[j] <= '9' || s[j] >= 'a' && s[j] <= 'z') do j += 1
	if j == k + 2 || j >= len(s) || s[j] != '!' do return "", "", 0, false
	q := strings.index_byte(s[j + 1:], '"')
	if q <= 0 do return "", "", 0, false
	q += j + 1
	imp := s[k + 2:q]
	j = q + 1
	if j >= len(s) || s[j] != ',' do return "", "", 0, false
	j += 1
	for j < len(s) && s[j] == ' ' do j += 1
	n := j
	for j < len(s) && ident_byte(s[j]) do j += 1
	if j == n || j >= len(s) || s[j] != '}' do return "", "", 0, false
	return imp, s[n:j], j + 1, true
}

// IAT slot -> bytes of arguments its HLE proc pops, for procs whose every
// `ret(n, v)` in src (port/src/win32) has the same literal n. A proc with no
// such ret, or with differing ones, is left out.
host_pops :: proc(src: string) -> map[u32]i64 {
	table := make(map[string]string)
	bodies := make(map[string][dynamic]string)
	infos, err := os.read_all_directory_by_path(src, context.allocator)
	fmt.assertf(err == nil, "read %s: %v", src, err)
	names: [dynamic]string
	for fi in infos do if strings.has_suffix(fi.name, ".odin") do append(&names, fi.name)
	slice.sort(names[:])
	for name in names {
		s := read_text(strings.concatenate({src, "/", name}))
		for k := 0; k + 1 < len(s); {
			if s[k] == '{' && s[k + 1] == '"' {
				if imp, p, end, ok := table_row(s, k); ok {
					table[imp] = p
					k = end
					continue
				}
			}
			k += 1
		}
		cur := ""
		for line in strings.split(s, "\n") {
			m := ""
			n := 0
			for n < len(line) && ident_byte(line[n]) do n += 1
			if n > 0 && strings.has_prefix(line[n:], " :: proc()") do m = line[:n]
			if m != "" {
				cur = m
				bodies[cur] = {}
			}
			if cur != "" {
				append(&bodies[cur], line)
				if line == "}" || m != "" && strings.has_suffix(strings.trim_right_space(line), "}") do cur = ""
			}
		}
	}
	pops := make(map[u32]i64)
	for a, imp in img.iat {
		p, ok := table[imp]
		if !ok do continue
		b, bok := bodies[p]
		if !bok do continue
		body := strings.join(b[:], "\n")
		ns: map[string]struct{}
		at := 0
		for {
			n, found := next_ret(body, &at)
			if !found do break
			ns[n] = {}
		}
		if len(ns) != 1 do continue
		for n in ns {
			t := strings.trim_space(n)
			digits := len(t) > 0
			v: i64
			for c in transmute([]u8)t {
				if c < '0' || c > '9' {
					digits = false
					break
				}
				v = v * 10 + i64(c - '0')
			}
			if digits do pops[a] = 4 * v
		}
	}
	return pops
}

// Inputs of the per-entry analysis: callee facts by entry address.
Frames :: struct {
	entry0:      []u8, // GPR bits read at entry, by address - TEXT_LO
	mod:         []u8, // by funcs index
	pops:        map[u32]Off, // entry -> ret imm, or unknown
	transp:      map[u32]u8, // entry -> transparent bits
	taken:       Set, // entries indirect transfers reach
	ind_seen:    u8, // of indirect transfers
	ind_kill:    u8,
	inline:      map[u32][]^Insn, // entry -> straight_line() body
	inline_step: map[u32]Off, // entry -> its esp delta, or unknown
	noreturn:    Set, // no_return() entries
	host:        map[u32]i64, // IAT slot -> host_pops()
}

ctx: Frames

is_entry :: proc(t: u32) -> bool {
	return owner(t) >= 0
}

// Registers entry t may read or change, its transparent ones aside.
seen_of :: proc(t: u32) -> u8 {
	g := owner(t)
	if g < 0 do return ALL_GPR
	return (ctx.entry0[t - TEXT_LO] | ctx.mod[g]) & ~ctx.transp[t]
}

// Registers a call to t may change.
kill_of :: proc(t: u32) -> u8 {
	g := owner(t)
	return g < 0 ? ALL_GPR : ctx.mod[g] & ~ctx.transp[t]
}

// Folds taken entry e into the indirect sets; true if they grew.
add_taken :: proc(e: u32) -> bool {
	s := ctx.ind_seen | seen_of(e) & SAVED
	k := ctx.ind_kill | kill_of(e) & SAVED
	grew := s != ctx.ind_seen || k != ctx.ind_kill
	ctx.ind_seen, ctx.ind_kill = s, k
	return grew
}

// Entries from which no path reaches a ret or an unknown indirect jump:
// every path ends at an instruction without successors (int3, ud2) or
// leaves only by tail jumps to, or calls of, such entries. Greatest
// fixpoint, so mutually tail-jumping entries qualify together.
no_return :: proc() -> Set {
	nr: Set
	for f in funcs do for e in f.entries do set_add(&nr, e)
	n := len(nr)
	drop: [dynamic]u32
	for _ in 0 ..< n + 1 {
		clear(&drop)
		for e in nr do if !ends_without_return(int(owner(e)), e, &nr) do append(&drop, e)
		if len(drop) == 0 do return nr
		for e in drop do delete_key(&nr, e)
	}
	panic("no-return entries did not converge")
}

ends_without_return :: proc(n: int, e: u32, nr: ^Set) -> bool {
	f, fl := funcs[n], &flows[n]
	seen: Set
	work: [dynamic]u32
	set_add(&seen, e)
	append(&work, e)
	for _ in 0 ..< len(f.insns) + 1 {
		if len(work) == 0 do return true
		p := pop(&work)
		k := pc_index(f, p)
		if k < 0 || f.code[k] == nil do return false
		kind, t := fl.kind[k], fl.tgt[k]
		if kind == .Ret || kind == .Ijmp && unknown_jump(f, p, kind) do return false
		for x in fl.exits[k] do if !(x in nr) do return false
		if kind == .Call && t in nr do continue
		for s in f.succs[k] {
			if !(s in seen) {
				set_add(&seen, s)
				append(&work, s)
			}
		}
	}
	fmt.panicf("no-return walk did not converge at %08x", e)
}

// Instructions of f from its start to its ret when that path has no branch,
// call or second entry and at most INLINE_MAX of them, else nil.
straight_line :: proc(n: int) -> []^Insn {
	f, fl := funcs[n], &flows[n]
	if len(f.entries) != 1 || !(f.start in f.entries) do return nil
	body: [dynamic]^Insn
	p := f.start
	for _ in 0 ..< INLINE_MAX {
		k := pc_index(f, p)
		if k < 0 || f.code[k] == nil {
			delete(body)
			return nil
		}
		i := f.code[k]
		append(&body, i)
		if fl.kind[k] == .Ret do return body[:]
		_, fixed := fixed_step(i.mnemonic)
		if fl.kind[k] != .None || len(f.succs[k]) != 1 || strings.has_prefix(i.mnemonic, "rep") || fixed {
			delete(body)
			return nil
		}
		p = f.succs[k][0]
	}
	delete(body)
	return nil
}

ret_imm :: proc(i: ^Insn) -> i64 {
	return i.nops > 0 ? i.ops[0].imm : 0
}

// esp change of a call to body, or unknown.
inline_delta :: proc(body: []^Insn) -> Off {
	d: i64
	for i in body[:len(body) - 1] {
		st := esp_step(i)
		if st.kind != .Delta do return NO_OFF
		d += st.d
	}
	return off(d + ret_imm(body[len(body) - 1]))
}

// By funcs index: bytes past the return address its returns pop, or unknown
// when they, or those of functions it tail-jumps to, disagree or are unknown.
ret_pops :: proc() -> []Off {
	// A set of pops; UNKNOWN_POP stands for an unknown one.
	UNKNOWN_POP :: min(i64)
	pops := make([]map[i64]struct{}, len(funcs))
	tails := make([]Set, len(funcs))
	defer {
		for &v in pops do delete(v)
		for &v in tails do delete(v)
		delete(pops)
		delete(tails)
	}
	for f, n in funcs {
		fl := &flows[n]
		for k in 0 ..< len(f.pcs) {
			i := f.code[k]
			if i == nil do continue
			kind := fl.kind[k]
			if kind == .Ret {
				pops[n][ret_imm(i)] = {}
			} else if kind == .Ijmp && unknown_jump(f, f.pcs[k], kind) {
				pops[n][UNKNOWN_POP] = {}
			}
			for x in fl.exits[k] {
				g := owner(x)
				if g < 0 {
					pops[n][UNKNOWN_POP] = {}
				} else {
					set_add(&tails[n], u32(g))
				}
			}
		}
	}
	converged := false
	for _ in 0 ..< len(funcs) + 1 {
		changed := false
		for t, k in tails {
			for g in t {
				for v in pops[g] {
					if !(v in pops[k]) {
						pops[k][v] = {}
						changed = true
					}
				}
			}
		}
		if !changed {
			converged = true
			break
		}
	}
	assert(converged, "return pops did not converge")
	out := make([]Off, len(funcs))
	for v, n in pops {
		if len(v) != 1 do continue
		for x in v do if x != UNKNOWN_POP do out[n] = off(x)
	}
	return out
}

// IAT slot a call operand reaches when host_pops() knows it, else 0:
// `call [slot]`, or `call r` with r loaded from one.
host_slot :: proc(op: ^Cs_Op, o: Off, regs: ^[8]Val) -> u32 {
	a: u32
	ok := false
	if op.type == OP_MEM {
		if op.base == 0 && op.index == 0 && op.segment == 0 do a, ok = u32(op.disp & 0xFFFFFFFF), true
	} else {
		k := reg_index(op)
		if k >= 0 {
			v := word(regs, o, k)
			if v.k == .M do a, ok = u32(v.x), true
		}
	}
	if ok && a in ctx.host do return a
	return 0
}

host_get :: proc(slot: u32) -> Off {
	if slot == 0 do return NO_OFF
	return off(ctx.host[slot])
}

pops_get :: proc(t: u32) -> Off {
	return ctx.pops[t] or_else NO_OFF
}

// Value of register k, esp as its stack offset.
word :: proc(regs: ^[8]Val, o: Off, k: int) -> Val {
	if k == ESP do return o.ok ? Val{.S, o.v, 0} : NONE
	return regs[k]
}

// Stack offset a memory operand addresses, or unknown.
mem_slot :: proc(op: ^Cs_Op, o: Off, regs: ^[8]Val) -> Off {
	if op.index != 0 || op.segment != 0 || op.base == 0 do return NO_OFF
	v := word(regs, o, r32_of(op.base))
	return v.k == .S ? off(v.x + s32(op.disp)) : NO_OFF
}

slots_find :: proc(s: []Slot, a: i64) -> (int, bool) {
	return slice.binary_search_by(s, a, proc(x: Slot, a: i64) -> slice.Ordering {return slice.cmp(x.a, a)})
}

slots_get :: proc(s: []Slot, a: i64, def := NONE) -> Val {
	k, ok := slots_find(s, a)
	return ok ? s[k].v : def
}

slots_set :: proc(s: ^[dynamic]Slot, a: i64, v: Val) {
	k, ok := slots_find(s[:], a)
	if ok {
		s[k].v = v
	} else {
		inject_at(s, k, Slot{a, v})
	}
}

// Taint of the slots [a, a + size) overlaps; removes them.
drop_slots :: proc(s: ^[dynamic]Slot, a: i64, size: i64) -> u32 {
	t: u32
	j := 0
	for x in s {
		if a < x.a + 4 && x.a < a + size {
			t |= x.v.t
		} else {
			s[j] = x
			j += 1
		}
	}
	resize(s, j)
	return t
}

all_taint :: proc(s: []Slot) -> u32 {
	t: u32
	for x in s do t |= x.v.t
	return t
}

sum_taint :: proc(regs: ^[8]Val) -> u32 {
	t: u32
	for v in regs do t += v.t
	return t
}

restored :: proc(regs: ^[8]Val) -> u32 {
	t: u32
	for k in 0 ..< 8 do if regs[k].k == .E && regs[k].x == i64(k) do t |= 1 << uint(k)
	return t
}

// Entry values the caller sees again on leaving with esp at its entry
// value: copies in other registers, `mov eax, ecx`, or in the caller's
// stack words. A register whose value escapes this way is read, not only
// saved, so it cannot be transparent.
escaped :: proc(regs: ^[8]Val, slots: []Slot) -> u32 {
	t: u32
	for k in 0 ..< 8 {
		if k != ESP && !(regs[k].k == .E && regs[k].x == i64(k)) do t |= regs[k].t
	}
	for x in slots do if x.a >= 0 do t |= x.v.t
	return t
}

clone_slots :: proc(s: []Slot) -> [dynamic]Slot {
	d := make([dynamic]Slot, len(s), len(s) + 2)
	copy(d[:], s)
	return d
}

// A dword memory operand at a constant address.
absolute :: proc(op: ^Cs_Op) -> bool {
	return op.type == OP_MEM && op.size == 4 && op.base == 0 && op.index == 0 && op.segment == 0
}

Stepped :: struct {
	o:     Off,
	regs:  [8]Val,
	slots: []Slot,
	leak:  u32,
}

// State and entry values read after an instruction that is no call or
// return.
step_plain :: proc(i: ^Insn, o: Off, regs: ^[8]Val, slots0: []Slot) -> Stepped {
	m, ops := i.mnemonic, i.ops[:i.nops]
	if m == "lea" && ops[1].index == 0 && ops[1].disp == 0 && ops[1].base == ops[0].reg {
		return {o, regs^, slots0, 0} // `lea r, [r]`: a multi-byte nop
	}
	use, md := i.use, i.mod
	slots := clone_slots(slots0)
	dst := len(ops) > 0 ? reg_index(&ops[0]) : -1
	src := len(ops) > 0 && (m == "push" || m == "mov") ? reg_index(&ops[len(ops) - 1]) : -1
	to_slot := len(ops) > 0 && ops[0].type == OP_MEM ? mem_slot(&ops[0], o, regs) : NO_OFF
	if src >= 0 && !(m == "push" && o.ok || m == "mov" && (dst >= 0 || to_slot.ok)) {
		src = -1 // stores an entry value where it is not followed
	}
	leak: u32
	for k in 0 ..< 8 {
		if use >> uint(k) & 1 != 0 && k != src do leak |= word(regs, o, k).t
	}
	loaded := NONE
	for &op in ops {
		if op.type != OP_MEM || m == "lea" || op.access & AC_READ == 0 do continue
		a := mem_slot(&op, o, regs)
		if !a.ok do continue
		hit: u32
		for x in slots do if a.v < x.a + 4 && x.a < a.v + i64(op.size) do hit |= x.v.t
		if (m == "push" || m == "mov") && op.size == 4 && (m == "push" || dst >= 0) {
			loaded = slots_get(slots[:], a.v, Val{.None, 0, hit})
		} else {
			leak |= hit
		}
	}
	st := esp_step(i)
	new: [8]Val
	for k in 0 ..< 8 do new[k] = md >> uint(k) & 1 != 0 && k != ESP ? NONE : regs[k]
	o2: Off
	switch st.kind {
	case .Unknown:
		o2 = NO_OFF
	case .Delta:
		o2 = o.ok ? off(o.v + st.d) : NO_OFF
	case .Reg:
		v := word(regs, o, st.k)
		o2 = v.k == .S ? off(v.x + st.d) : NO_OFF
	case .Leave:
		v := regs[EBP]
		o2 = v.k == .S ? off(v.x + 4) : NO_OFF
		new[EBP] = o2.ok ? slots_get(slots[:], v.x) : Val{.None, 0, all_taint(slots[:])}
	}
	if st.kind == .Unknown && (m == "add" || m == "sub") && dst == ESP && o.ok {
		if r := reg_index(&ops[1]); r >= 0 {
			v := word(regs, o, r)
			if v.k == .C do o2 = off(o.v + s32(v.x) * (m == "add" ? 1 : -1)) // `sub esp, eax` with eax known
		}
	}
	if m == "mov" && dst >= 0 && ops[1].type == OP_IMM {
		new[dst] = {.C, ops[1].imm & 0xFFFFFFFF, 0}
	} else if m == "mov" && dst >= 0 && src < 0 && absolute(&ops[1]) {
		new[dst] = {.M, ops[1].disp & 0xFFFFFFFF, 0} // host_slot() resolves IAT loads
	} else if m == "mov" && dst >= 0 {
		new[dst] = src >= 0 ? word(regs, o, src) : loaded
	} else if m == "lea" && dst >= 0 {
		a := mem_slot(&ops[1], o, regs)
		new[dst] = a.ok ? Val{.S, a.v, 0} : NONE
	} else if m == "pop" && dst >= 0 {
		new[dst] = o.ok ? slots_get(slots[:], o.v) : Val{.None, 0, all_taint(slots[:])}
	}
	for &op in ops {
		if op.type != OP_MEM || op.access & AC_WRITE == 0 do continue
		if m == "pop" {
			leak |= all_taint(slots[:])
			clear(&slots)
		} else if a := mem_slot(&op, o, regs); a.ok {
			drop_slots(&slots, a.v, i64(op.size))
		}
	}
	if m == "mov" && to_slot.ok && src >= 0 do slots_set(&slots, to_slot.v, word(regs, o, src))
	if (m == "push" || m == "pushfd" || m == "pushal" || m == "pushad") && o.ok {
		drop_slots(&slots, o.v + st.d, -st.d)
		if m == "push" && ops[0].size == 4 && ops[0].type == OP_IMM {
			slots_set(&slots, o.v - 4, Val{.C, ops[0].imm & 0xFFFFFFFF, 0})
		} else if m == "push" && ops[0].size == 4 {
			slots_set(&slots, o.v - 4, src >= 0 ? word(regs, o, src) : loaded)
		}
	} else if m == "push" {
		leak |= loaded.t
	}
	return {o2, new, slots[:], leak}
}

// State and entry values read after a call to a straight-line body,
// interpreted in place. Its ret must pop ret_pc.
step_inline :: proc(body: []^Insn, ret_pc: u32, o: Off, regs: ^[8]Val, slots0: []Slot) -> Stepped {
	if !o.ok do return {NO_OFF, {}, nil, all_taint(slots0) | sum_taint(regs)}
	slots := clone_slots(slots0)
	drop_slots(&slots, o.v - 4, 4)
	slots_set(&slots, o.v - 4, Val{.A, i64(ret_pc), 0})
	r := Stepped{off(o.v - 4), regs^, slots[:], 0}
	for i in body[:len(body) - 1] {
		s := step_plain(i, r.o, &r.regs, r.slots)
		r.o, r.regs, r.slots, r.leak = s.o, s.regs, s.slots, r.leak | s.leak
		if !r.o.ok {
			r.leak |= all_taint(r.slots)
			return r
		}
	}
	if v := slots_get(r.slots, r.o.v); !(v.k == .A && v.x == i64(ret_pc)) {
		r.leak |= all_taint(r.slots) | sum_taint(&r.regs)
		r.o = NO_OFF
		return r
	}
	k, _ := slots_find(r.slots, r.o.v)
	d := clone_slots(r.slots)
	ordered_remove(&d, k)
	r.slots = d[:]
	r.o = off(r.o.v + 4 + ret_imm(body[len(body) - 1]))
	return r
}

// State and entry values the callee may read after a call; back_next:
// back_offsets at the return address; slot: host_slot() of an indirect
// call, or 0.
step_call :: proc(kind: Kind, t: u32, o: Off, regs: ^[8]Val, slots0: []Slot, back_next: Off, slot: u32) -> Stepped {
	direct := kind == .Call && is_entry(t)
	seen: u8 = HOST_REGS
	kill: u8 = HOST_REGS
	if slot == 0 {
		seen = kind == .Call ? seen_of(t) : ctx.ind_seen
		kill = kind == .Call ? kill_of(t) : ctx.ind_kill
	}
	r: Stepped
	for k in 0 ..< 8 {
		if seen >> uint(k) & 1 != 0 && k != ESP do r.leak |= regs[k].t
		r.regs[k] = kill >> uint(k) & 1 != 0 ? NONE : regs[k]
	}
	r.slots = slots0
	if o.ok {
		j := 0
		for j < len(slots0) && slots0[j].a < o.v do j += 1
		r.slots = slots0[j:]
	}
	pops := direct ? pops_get(t) : host_get(slot)
	d := back_next.v - o.v
	if o.ok && pops.ok {
		r.o = off(o.v + pops.v)
	} else if o.ok && back_next.ok && 0 <= d && d <= ARG_POP_MAX && d % 4 == 0 {
		r.o = back_next
	}
	return r
}

// (failed bits, balanced) of tail jumps to ex in the given state; ind: an
// indirect exit as well.
check_exits :: proc(ex: []u32, ind: bool, o: Off, regs: ^[8]Val, slots: []Slot) -> (u32, bool) {
	fail: u32
	bal := true
	n := len(ex) + (ind ? 1 : 0)
	for j in 0 ..< n {
		x := j < len(ex) ? ex[j] : 0
		indirect := j >= len(ex)
		if !indirect && x in ctx.noreturn do continue
		if !indirect && !is_entry(x) || !(o.ok && o.v == 0) do return u32(SAVED), false
		seen := indirect ? ctx.ind_seen : seen_of(x)
		for k in 0 ..< 8 do if seen >> uint(k) & 1 != 0 && k != ESP do fail |= regs[k].t
		fail |= u32(SAVED) & ~(restored(regs) & ~u32(seen)) | escaped(regs, slots)
		bal = bal && !indirect && pops_get(x).ok
	}
	return fail, bal
}

// (state after the instruction at f.pcs[k], failed bits, balanced);
// ok false: no state follows.
frame_step :: proc(n: int, k: int, st: ^State, back: []Off) -> (State, bool, u32, bool) {
	f, fl := funcs[n], &flows[n]
	p, i := f.pcs[k], f.code[k]
	kind, t := fl.kind[k], fl.tgt[k]
	o := st.o
	if kind == .Ret {
		if !(o.ok && o.v == 0) do return {}, false, u32(SAVED), false
		return {}, false, u32(SAVED) & ~restored(&st.regs) | escaped(&st.regs, st.slots), true
	}
	if kind == .Ijmp && unknown_jump(f, p, kind) {
		s := step_plain(i, o, &st.regs, st.slots)
		fail, _ := check_exits(nil, true, s.o, &s.regs, s.slots)
		return {}, false, s.leak | fail, false
	}
	if kind == .Call && t in ctx.noreturn do return {}, false, 0, true
	s: Stepped
	if body, ok := ctx.inline[t]; kind == .Call && ok {
		s = step_inline(body, p + u32(i.size), o, &st.regs, st.slots)
	} else if kind == .Call || kind == .Icall {
		slot := kind == .Icall ? host_slot(&i.ops[0], o, &st.regs) : 0
		bn := back_at(f, back, p + u32(i.size))
		s = step_call(kind, t, o, &st.regs, st.slots, bn, slot)
	} else {
		s = step_plain(i, o, &st.regs, st.slots)
	}
	for x in fl.succ[k] {
		b := x >= 0 ? back[x] : NO_OFF
		if s.o.ok && b.ok && b.v != s.o.v do return {}, false, u32(SAVED), false
	}
	fail, bal := check_exits(fl.exits[k], false, s.o, &s.regs, s.slots)
	return {s.o, s.regs, s.slots}, true, s.leak | fail, bal
}

back_at :: proc(f: ^Func, back: []Off, p: u32) -> Off {
	k := pc_index(f, p)
	return k >= 0 ? back[k] : NO_OFF
}

join_val :: proc(x, y: Val) -> Val {
	k, v := x.k, x.x
	if x.k != y.k || x.x != y.x do k, v = .None, 0
	return {k, v, x.t | y.t}
}

join_frames :: proc(a, b: ^State) -> State {
	r: State
	r.o = a.o == b.o ? a.o : NO_OFF
	for k in 0 ..< 8 do r.regs[k] = join_val(a.regs[k], b.regs[k])
	s := make([dynamic]Slot, 0, len(a.slots) + len(b.slots))
	ia, ib := 0, 0
	for ia < len(a.slots) || ib < len(b.slots) {
		key: i64
		x, y := NONE, NONE
		if ib >= len(b.slots) || ia < len(a.slots) && a.slots[ia].a < b.slots[ib].a {
			key, x = a.slots[ia].a, a.slots[ia].v
			ia += 1
		} else if ia >= len(a.slots) || b.slots[ib].a < a.slots[ia].a {
			key, y = b.slots[ib].a, b.slots[ib].v
			ib += 1
		} else {
			key, x, y = a.slots[ia].a, a.slots[ia].v, b.slots[ib].v
			ia += 1
			ib += 1
		}
		if v := join_val(x, y); v != NONE do append(&s, Slot{key, v})
	}
	r.slots = s[:]
	return r
}

state_eq :: proc(a, b: ^State) -> bool {
	return a.o == b.o && a.regs == b.regs && slice.equal(a.slots, b.slots)
}

// By f.pcs index: esp offset before the instruction, where known esp steps
// lead from it to a return or tail jump, given that f leaves esp at each as
// it found it.
back_offsets :: proc(n: int) -> []Off {
	f, fl := funcs[n], &flows[n]
	m := len(f.pcs)
	back := make([]Off, m)
	step := make([]Off, m)
	defer delete(step)
	none_regs: [8]Val
	ex: [dynamic]u32
	defer delete(ex)
	for k in 0 ..< m {
		i := f.code[k]
		if i == nil do continue
		kind, t := fl.kind[k], fl.tgt[k]
		s: Off
		if kind == .Call && t in ctx.noreturn {
			s = NO_OFF
		} else if kind == .Call {
			s = t in ctx.inline ? ctx.inline_step[t] : pops_get(t)
		} else if kind == .Icall {
			s = host_get(host_slot(&i.ops[0], NO_OFF, &none_regs))
		} else if e := esp_step(i); e.kind == .Delta {
			s = off(e.d)
		}
		step[k] = s
		clear(&ex)
		for x in fl.exits[k] do if !(x in ctx.noreturn) do append(&ex, x)
		if kind == .Ret || len(ex) > 0 && (kind == .Jmp || kind == .Jcc || kind == .Ijmp) {
			back[k] = off(0)
		} else if len(ex) > 0 && s.ok {
			back[k] = off(-s.v)
		}
	}
	for _ in 0 ..< len(f.live_pcs) + 1 {
		changed := false
		#reverse for _, k in f.pcs {
			if f.code[k] == nil || back[k].ok || !step[k].ok do continue
			v: i64
			nv := 0
			for x in fl.succ[k] {
				if x < 0 || !back[x].ok do continue
				if nv == 0 || back[x].v != v {
					if nv == 1 && back[x].v != v {
						nv = 2
						break
					}
					v = back[x].v
					nv = 1
				}
			}
			if nv == 1 {
				back[k] = off(v - step[k].v)
				changed = true
			}
		}
		if !changed do break
	}
	return back
}

// saved_at's states and whether each is set, by f.pcs index, sized for the
// largest function; g_touched lists the set ones.
@(private = "file")
g_states: []State
@(private = "file")
g_have: []bool
@(private = "file")
g_touched: [dynamic]i32

// (transparent bits, balanced) of entry e of funcs[n].
saved_at :: proc(n: int, e: u32, back: []Off) -> (u8, bool) {
	f, fl := funcs[n], &flows[n]
	k0 := pc_index(f, e)
	if k0 < 0 do return 0, false
	// The states of the reached instructions only: one dense array per
	// entry would cost pcs times entries.
	states, have, touched := g_states, g_have, &g_touched
	append(touched, k0)
	for k in 0 ..< 8 do states[k0].regs[k] = Val{.E, i64(k), 1 << uint(k)}
	states[k0].regs[ESP] = NONE
	states[k0].o = off(0)
	have[k0] = true
	work: [dynamic]i32
	append(&work, k0)
	fail: u32
	bal := true
	for _ in 0 ..< 64 * len(f.insns) + 64 {
		if len(work) == 0 do return SAVED & ~u8(fail & 0xFF), bal
		k := int(pop(&work))
		if f.code[k] == nil do return 0, false
		out, ok, ff, b := frame_step(n, k, &states[k], back)
		fail |= ff
		bal = bal && b
		if fail == u32(SAVED) && !bal do return 0, false
		if !ok do continue
		for s in fl.succ[k] {
			if s < 0 do return 0, false
			if !have[s] {
				states[s] = out
				have[s] = true
				append(touched, s)
				append(&work, s)
				continue
			}
			j := join_frames(&states[s], &out)
			if !state_eq(&j, &states[s]) {
				states[s] = j
				append(&work, s)
			}
		}
	}
	fmt.panicf("frame analysis did not converge at %08x", e)
}

// Entry -> GPR bits it is transparent in: a greatest fixpoint, since a call
// keeps a register's entry value only if the callee is transparent. taken:
// taken_entries(); host: host_pops().
transparency :: proc(entry0: []u8, mod: []u8, taken: Set, host: map[u32]i64) -> map[u32]u8 {
	ctx = Frames {
		entry0 = entry0,
		mod    = mod,
		taken  = taken,
		host   = host,
	}
	ctx.ind_seen, ctx.ind_kill = HOST_REGS, HOST_REGS
	rp := ret_pops()
	for f in funcs {
		for e in f.entries {
			ctx.transp[e] = SAVED
			ctx.pops[e] = rp[owner(e)]
		}
	}
	ctx.noreturn = no_return()
	for f, n in funcs {
		if body := straight_line(n); body != nil {
			ctx.inline[f.start] = body
			ctx.inline_step[f.start] = inline_delta(body)
		}
	}
	for e in taken do add_taken(e)
	users := make(map[u32]Set) // entry -> funcs indices calling or tail-jumping to it
	indirect: Set // funcs indices with an indirect transfer
	for f, n in funcs {
		fl := &flows[n]
		for k in 0 ..< len(f.pcs) {
			if f.code[k] == nil do continue
			kind := fl.kind[k]
			if kind == .Icall || unknown_jump(f, f.pcs[k], kind) do set_add(&indirect, u32(n))
			use :: proc(users: ^map[u32]Set, x: u32, n: int) {
				if !is_entry(x) do return
				s, ok := &users[x]
				if !ok {
					users[x] = {}
					s = &users[x]
				}
				set_add(s, u32(n))
			}
			if kind == .Call do use(&users, fl.tgt[k], n)
			for x in fl.exits[k] do use(&users, x, n)
		}
	}
	// Reset per entry without zeroing: a growing arena zeroes what it used,
	// which costs more than the analysis. Pages are committed on first touch.
	buf, aerr := vmem.reserve_and_commit(1 << 32)
	assert(aerr == nil)
	defer vmem.release(raw_data(buf), len(buf))
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	most := 0
	for f in funcs do most = max(most, len(f.pcs))
	g_states, g_have = make([]State, most), make([]bool, most)
	g_touched = make([dynamic]i32, 0, most) // on the heap: saved_at_in frees its arena
	work := make([dynamic]i32, len(funcs))
	queued := make([]bool, len(funcs))
	for n in 0 ..< len(funcs) {
		work[n] = i32(n)
		queued[n] = true
	}
	again: [dynamic]u32
	converged := false
	for _ in 0 ..< 64 * len(funcs) + 1 {
		if len(work) == 0 {
			converged = true
			break
		}
		n := int(pop(&work))
		queued[n] = false
		f := funcs[n]
		back := back_offsets(n)
		entries := set_sorted(f.entries)
		for e in entries {
			tr, bal: = saved_at_in(&arena, n, e, back)
			tr &= ctx.transp[e]
			pops := bal ? ctx.pops[e] : NO_OFF
			if tr == ctx.transp[e] && pops == ctx.pops[e] do continue
			ctx.transp[e], ctx.pops[e] = tr, pops
			clear(&again)
			if us, ok := users[e]; ok do for u in us do append(&again, u)
			if e in taken && add_taken(e) do for u in indirect do append(&again, u)
			for u in again {
				if !queued[u] {
					append(&work, i32(u))
					queued[u] = true
				}
			}
		}
		delete(entries)
		delete(back)
	}
	assert(converged, "transparency did not converge")
	return ctx.transp
}

// saved_at with its states in arena, freed after.
saved_at_in :: proc(arena: ^mem.Arena, n: int, e: u32, back: []Off) -> (u8, bool) {
	context.allocator = mem.arena_allocator(arena)
	defer {
		free_all(context.allocator)
		for k in g_touched do g_states[k], g_have[k] = {}, false
		clear(&g_touched)
	}
	return saved_at(n, e, back)
}
