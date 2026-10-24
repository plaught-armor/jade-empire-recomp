#+feature dynamic-literals
package x86rec

import "core:slice"

Set :: map[u32]struct{}

set_add :: proc(s: ^Set, v: u32) {
	s[v] = {}
}

set_has :: proc(s: Set, v: u32) -> bool {
	return v in s
}

set_sorted :: proc(s: Set, allocator := context.allocator) -> []u32 {
	out := make([]u32, len(s), allocator)
	k := 0
	for v in s {
		out[k] = v
		k += 1
	}
	slice.sort(out)
	return out
}

// Mnemonics that never occur in this compiler's output; seeing one means the
// bytes are data, not code.
BOGUS := map[string]struct{} {
	"in" = {}, "out" = {}, "insb" = {}, "insd" = {}, "outsb" = {}, "outsd" = {}, "rep outsd" = {},
	"iretd" = {}, "retf" = {}, "into" = {}, "das" = {}, "daa" = {}, "aaa" = {}, "aas" = {}, "aam" = {},
	"aad" = {}, "les" = {}, "lds" = {}, "ljmp" = {}, "lcall" = {}, "sldt" = {}, "salc" = {}, "hlt" = {},
	"cli" = {}, "sti" = {}, "int" = {}, "int1" = {}, "arpl" = {}, "bound" = {}, "pushaw" = {}, "popaw" = {},
}

is_bogus :: proc(i: ^Insn) -> bool {
	return i.mnemonic in BOGUS
}

// ---------------------------------------------------------------- control flow

Kind :: enum u8 {
	None,
	Jmp,
	Jcc,
	Call,
	Ret,
	Ijmp,
	Icall,
}

// The condition code of a jcc mnemonic, or "".
jcc_cond :: proc(m: string) -> string {
	if len(m) < 2 || m[0] != 'j' do return ""
	c := m[1:]
	return c in COND ? c : ""
}

// The control transfer of i and its direct target.
control :: proc(i: ^Insn) -> (Kind, u32) {
	m := i.mnemonic
	if m == "ret" || m == "retn" do return .Ret, 0
	if m == "jmp" || jcc_cond(m) != "" || m == "jecxz" || m == "loop" || m == "loope" || m == "loopne" || m == "call" {
		op := &i.ops[0]
		if op.type == OP_IMM {
			kind: Kind = m == "jmp" ? .Jmp : m == "call" ? .Call : .Jcc
			return kind, u32(op.imm)
		}
		return m == "call" ? .Icall : .Ijmp, 0
	}
	return .None, 0
}

text :: proc(v: u32) -> bool {
	return TEXT_LO <= v && v < TEXT_HI
}

// Entries of `jmp [idx*4 + table]`, or nil. prev: the instruction before i
// in the same block, or nil.
switch_table :: proc(i: ^Insn, prev: ^Insn) -> [dynamic]u32 {
	op := &i.ops[0]
	if op.type != OP_MEM || op.base != 0 || op.index == 0 || op.scale != 4 do return nil
	ents: [dynamic]u32
	tbl := i64(u32(op.disp))
	if prev != nil && prev.mnemonic == "neg" && prev.ops[0].type == OP_REG && prev.ops[0].reg == op.index {
		// `neg idx; jmp [idx*4 + table]` indexes at or below the table (CRT
		// memmove backward tail, index -7..0): scan down from slot 0.
		for k in 0 ..< i64(4096) {
			v, ok := img_u32(tbl - 4 * k)
			if !ok || !text(v) do break
			append(&ents, v)
		}
		return ents
	}
	for k in 0 ..< i64(4096) {
		v, ok := img_u32(tbl + 4 * k)
		if !ok || !text(v) {
			// An index that never takes low values leaves leading slots that
			// overlap other bytes (CRT memcpy: index 1..3 after the jmp).
			if len(ents) == 0 && k < 3 do continue
			break
		}
		append(&ents, v)
	}
	return ents
}

Func :: struct {
	start, end: u32, // region [start, end)
	entries:    Set, // addresses other code can enter at
	insns:      map[u32]^Insn, // nil: bytes that do not decode
	labels:     Set,
	succ:       map[u32][dynamic]u32, // intra successors
	tables:     map[u32][dynamic]u32, // pc of jmp -> entries
	out:        Set, // tail-call targets outside the region
	bad:        Set,
	// Set by finish_funcs: the insns keys in address order, their
	// instructions, successors, and the non-nil ones' positions.
	pcs:        []u32,
	code:       []^Insn,
	succs:      [][]u32,
	live_pcs:   []u32,
}

inside :: proc(f: ^Func, a: u32) -> bool {
	return f.start <= a && a < f.end
}

func_new :: proc(start, end: u32) -> ^Func {
	f := new(Func)
	f.start, f.end = start, end
	set_add(&f.entries, start)
	return f
}

func_free :: proc(f: ^Func) {
	delete(f.entries)
	delete(f.insns)
	delete(f.labels)
	for _, v in f.succ do delete(v)
	delete(f.succ)
	for _, v in f.tables do delete(v)
	delete(f.tables)
	delete(f.out)
	delete(f.bad)
	free(f)
}

succ_add :: proc(f: ^Func, pc, s: u32) {
	l, ok := &f.succ[pc]
	if !ok {
		f.succ[pc] = {}
		l = &f.succ[pc]
	}
	append(l, s)
}

// Collect the instructions reachable from f.entries inside the region.
decode_func :: proc(f: ^Func) {
	clear(&f.insns)
	clear(&f.labels)
	for e in f.entries do set_add(&f.labels, e)
	for _, v in f.succ do delete(v)
	clear(&f.succ)
	for _, v in f.tables do delete(v)
	clear(&f.tables)
	clear(&f.out)
	clear(&f.bad)
	es := set_sorted(f.entries)
	work: [dynamic]u32
	append(&work, ..es)
	delete(es)
	seen: Set
	defer delete(seen)
	defer delete(work)
	for len(work) > 0 {
		pc := pop(&work)
		prev: ^Insn
		walk: for {
			if pc in seen do break
			if !inside(f, pc) {
				set_add(&f.out, pc)
				break
			}
			i := insn(pc)
			if i == nil || is_bogus(i) {
				set_add(&f.bad, pc)
				f.insns[pc] = i
				set_add(&seen, pc)
				break
			}
			set_add(&seen, pc)
			f.insns[pc] = i
			nxt := pc + u32(i.size)
			kind, t := control(i)
			#partial switch kind {
			case .Jmp, .Jcc:
				if inside(f, t) {
					set_add(&f.labels, t)
					append(&work, t)
					succ_add(f, pc, t)
				} else {
					set_add(&f.out, t)
				}
				if kind == .Jmp do break walk
				succ_add(f, pc, nxt)
				if !inside(f, nxt) {
					set_add(&f.out, nxt)
					break walk
				}
				set_add(&f.labels, nxt)
			case .Ijmp:
				ents := switch_table(i, prev)
				if len(ents) > 0 {
					f.tables[pc] = ents
					for e in ents {
						if inside(f, e) {
							set_add(&f.labels, e)
							append(&work, e)
							succ_add(f, pc, e)
						} else {
							set_add(&f.out, e)
						}
					}
				} else {
					delete(ents)
				}
				break walk
			case .Ret:
				break walk
			case:
				if i.mnemonic == "int3" || i.mnemonic == "ud2" do break walk
				if nxt not_in f.insns && !inside(f, nxt) {
					set_add(&f.out, nxt)
					break walk
				}
				if kind == .None || kind == .Call || kind == .Icall do succ_add(f, pc, nxt)
			}
			prev = i
			pc = nxt
		}
	}
	split_overlaps(f)
}

// Overlapping instruction streams (a label one byte into an instruction,
// e.g. 0x464c45 inside `cmp [esi+0x9c], edi` at 0x464c44) interleave in
// address order. The emitter walks address order and falls through between
// cases, so at every break in that order the true successor and the
// out-of-order instruction both become labels; the emitter then jumps
// instead of falling through.
split_overlaps :: proc(f: ^Func) {
	pcs := make([dynamic]u32, 0, len(f.insns))
	defer delete(pcs)
	for p in f.insns do append(&pcs, p)
	slice.sort(pcs[:])
	for k in 0 ..< max(len(pcs) - 1, 0) {
		p, q := pcs[k], pcs[k + 1]
		i := f.insns[p]
		if i == nil || p in f.bad do continue
		nxt := p + u32(i.size)
		if nxt != q {
			set_add(&f.labels, q)
			if nxt in f.insns do set_add(&f.labels, nxt)
		}
	}
}

data_pointers :: proc(out: ^Set) {
	for va := i64(DATA_LO); va < DATA_HI - 3; va += 4 {
		v, _ := img_u32(va)
		if text(v) do set_add(out, v)
	}
}

// Straight-line instructions from pc up to a terminator, or false when the
// path hits bogus bytes or leaves .text.
clean_path :: proc(pc0: u32, path: ^[dynamic]^Insn, limit := 4000) -> bool {
	clear(path)
	pc := pc0
	for _ in 0 ..< limit {
		if !text(pc) do return false
		i := insn(pc)
		if i == nil || is_bogus(i) do return false
		append(path, i)
		kind, _ := control(i)
		if kind == .Ret || kind == .Jmp || kind == .Ijmp || i.mnemonic == "int3" do return true
		pc += u32(i.size)
	}
	return false
}

// Code addresses as instruction immediates (`push offset fn` for atexit,
// `mov [esi], offset vtable_thunk`); jump/call targets excluded.
imm_pointers :: proc(fs: []^Func, out: ^Set) {
	for f in fs {
		for _, i in f.insns {
			if i == nil do continue
			if k, _ := control(i); k != .None do continue
			for op in i.ops[:i.nops] {
				if op.type == OP_IMM && text(u32(op.imm)) do set_add(out, u32(op.imm))
			}
		}
	}
}

// Partition .text into regions at primary entries, decode each, then add
// secondary entries (data pointers, tail-jump targets) until stable.
// Returns the functions with code, in address order, and the count of
// rejected pointer candidates.
build_funcs :: proc(ghidra: []u32) -> ([]^Func, int) {
	primary: Set
	for a in ghidra do if text(a) do set_add(&primary, a)
	set_add(&primary, OEP)
	make_funcs :: proc(primary: Set) -> ([]u32, []^Func) {
		starts := set_sorted(primary)
		funcs := make([]^Func, len(starts))
		for s, k in starts do funcs[k] = func_new(s, k + 1 < len(starts) ? starts[k + 1] : TEXT_HI)
		return starts, funcs
	}
	// Direct call targets found by a first pass become primary entries.
	for _ in 0 ..< 4 {
		starts, funcs := make_funcs(primary)
		calls: Set
		for f in funcs {
			decode_func(f)
			for _, i in f.insns {
				if i == nil do continue
				if kind, t := control(i); kind == .Call && text(t) do set_add(&calls, t)
			}
		}
		grew := false
		for t in calls {
			if t not_in primary {
				set_add(&primary, t)
				grew = true
			}
		}
		delete(calls)
		for f in funcs do func_free(f)
		delete(funcs)
		delete(starts)
		if !grew do break
	}
	starts, funcs := make_funcs(primary)
	owner :: proc(starts: []u32, funcs: []^Func, a: u32) -> ^Func {
		k, _ := slice.binary_search(starts, a)
		// bisect_right - 1: the last start <= a.
		for k < len(starts) && starts[k] <= a do k += 1
		k -= 1
		return k >= 0 ? funcs[k] : nil
	}
	for f in funcs do decode_func(f)
	overlaps :: proc(f: ^Func, p: u32) -> bool {
		for q in p - 15 ..< p {
			i := f.insns[q]
			if i != nil && q < p && p < q + u32(i.size) do return true
		}
		return false
	}
	// Pointer candidates (data words, immediates) are accepted on an
	// instruction boundary of decoded code, or when they decode cleanly in
	// undecoded bytes. Tail-jump targets are always accepted.
	rejected, cands, forced: Set
	data_pointers(&cands)
	imm_pointers(funcs, &cands)
	path: [dynamic]^Insn
	for len(cands) > 0 || len(forced) > 0 {
		changed: Set // f.start
		changed_fs: [dynamic]^Func
		all := make(Set, len(cands) + len(forced))
		for c in cands do set_add(&all, c)
		for c in forced do set_add(&all, c)
		// Ascending order, and each accepted path is claimed at once, so two
		// candidates in one batch cannot both enter overlapping decodes.
		for p in set_sorted(all, context.temp_allocator) {
			f := owner(starts, funcs, p)
			if f == nil || p in f.entries do continue
			ok := p in forced || f.insns[p] != nil
			if !ok && !overlaps(f, p) {
				// A path that straddles decoded instruction starts is a
				// misaligned decode of known code, not a new entry.
				if clean_path(p, &path) && !straddles(f, path[:]) {
					ok = true
					for i in path {
						if inside(f, i.address) && i.address not_in f.insns do f.insns[i.address] = i
					}
				}
			}
			if ok {
				set_add(&f.entries, p)
				if f.start not_in changed {
					set_add(&changed, f.start)
					append(&changed_fs, f)
				}
				delete_key(&rejected, p)
			} else {
				set_add(&rejected, p)
			}
		}
		delete(all)
		for f in changed_fs do decode_func(f)
		clear(&forced)
		for f in funcs {
			for t in f.out {
				g := owner(starts, funcs, t)
				if g != nil && t not_in g.entries do set_add(&forced, t)
			}
		}
		clear(&cands)
		imm_pointers(changed_fs[:], &cands)
		delete(changed)
		delete(changed_fs)
		free_all(context.temp_allocator)
	}
	kept: [dynamic]^Func
	for f in funcs {
		if len(f.insns) > 0 do append(&kept, f)
		else do func_free(f)
	}
	return kept[:], len(rejected)
}

straddles :: proc(f: ^Func, path: []^Insn) -> bool {
	for i in path {
		for k in 1 ..< u32(i.size) do if i.address + k in f.insns do return true
	}
	return false
}

// Address-ordered arrays of each function's instructions for the analyses.
finish_funcs :: proc(funcs: []^Func) {
	for f in funcs {
		f.pcs = make([]u32, len(f.insns))
		k := 0
		for p in f.insns {
			f.pcs[k] = p
			k += 1
		}
		slice.sort(f.pcs)
		f.code = make([]^Insn, len(f.pcs))
		f.succs = make([][]u32, len(f.pcs))
		live: [dynamic]u32
		for p, k in f.pcs {
			f.code[k] = f.insns[p]
			if s, ok := f.succ[p]; ok do f.succs[k] = s[:]
			if f.code[k] != nil do append(&live, p)
		}
		f.live_pcs = live[:]
	}
}
