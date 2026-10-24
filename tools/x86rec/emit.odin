package x86rec

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// Register promotion. The guest registers and flags live in x86.cpu, a global,
// and every guest store may alias it as far as LLVM can tell, so each c.esp in
// a run of pushes and stack stores was a reload. A function therefore keeps the
// ones it names in proc locals g_<reg>, loaded at entry. A sync line (a call of
// anything that may read or write them, or a return) keeps its c.<reg> refs:
// before it the locals the function writes go back to x86.cpu, after it (unless
// it returns) the locals reload. A direct call or a return narrows both to the
// registers its Sync names. WHY: docs/recompiler.md §2
PROMOTED := [15]string{"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "cf", "zf", "sf", "of", "pf", "af", "df"}
Regs :: u16 // bit k: PROMOTED[k]
EVERY: Regs : 0x7FFF
NON_GPR: Regs : 0x7F00
ESP_DF: Regs : 1 << 4 | 1 << 14
// x86 helpers that touch no promoted register; any other call syncs.
PURE_HELPERS := [?]string {
	"rd8", "rd16", "rd32", "rd64", "rd128", "wr8", "wr16", "wr32", "wr64", "wr128",
	"st", "set_st", "set_st_raw", "st_phys", "set_st_phys", "round_pc", "round_single",
	"rot8", "fpush", "fpop", "fstsw", "fcom", "fldcw", "fist32", "fist32_trunc", "fist64",
	"round_cw", "parity", "shr64", "shl64", "ld80", "st80", "pshufd", "cmppd", "shufps",
	"frstor", "fnsave",
}

is_pure :: proc(n: string) -> bool {
	for h in PURE_HELPERS do if h == n do return true
	return false
}

promoted_index :: proc(n: string) -> int {
	for r, k in PROMOTED do if r == n do return k
	return -1
}

is_word :: proc(b: u8) -> bool {
	return b == '_' || '0' <= b && b <= '9' || 'a' <= b && b <= 'z' || 'A' <= b && b <= 'Z'
}

// End of the word run starting at i.
word_end :: proc(s: string, i: int) -> int {
	j := i
	for j < len(s) && is_word(s[j]) do j += 1
	return j
}

// Promoted names of GPR and flag bit sets; esp and df always.
reg_set :: proc(gpr: u8, flags: u8) -> Regs {
	r := Regs(gpr) | ESP_DF
	if flags & CF != 0 do r |= 1 << 8
	if flags & ZF != 0 do r |= 1 << 9
	if flags & SF != 0 do r |= 1 << 10
	if flags & OF != 0 do r |= 1 << 11
	if flags & PF != 0 do r |= 1 << 12
	if flags & AF != 0 do r |= 1 << 13
	return r
}

// Promoted registers each direct call and return must store, and each
// direct call must reload. A call skips registers the callee is transparent
// in; the callee's returns store those it may write, so x86.cpu holds the
// caller's values again, as on the machine.
Sync :: struct {
	call: map[u32][2]Regs, // entry -> (store, reload)
	ret:  map[u32]Regs, // f.start -> store
}

sync_new :: proc(flag, gpr: ^Live_Result, mod: []u8, transp: map[u32]u8) -> Sync {
	s: Sync
	for f, n in funcs {
		restore: u8
		for e in set_sorted(f.entries, context.temp_allocator) {
			tr := transp[e]
			restore |= tr
			s.call[e] = {reg_set(gpr.entry_live[e - TEXT_LO] & ~tr, flag.entry_live[e - TEXT_LO]), reg_set(mod[n] & ~tr, ALL) | NON_GPR}
		}
		s.ret[f.start] = reg_set(gpr.ret_live[n] | restore & mod[n], flag.ret_live[n])
	}
	return s
}

// One match of SYNC_CALL: `\bx86\.(\w+)\(|(?<![\w.])[rf]_[0-9a-f]{8}\(|\bnative\.\w+\(`.
// group is "" for the second and third alternatives.
Sync_Match :: struct {
	group: string,
	end:   int,
}

is_hex8 :: proc(s: string) -> bool {
	if len(s) != 8 do return false
	for b in transmute([]u8)s do if !('0' <= b && b <= '9' || 'a' <= b && b <= 'f') do return false
	return true
}

sync_match_at :: proc(l: string, i: int) -> (Sync_Match, bool) {
	at_b := i == 0 || !is_word(l[i - 1])
	if at_b && strings.has_prefix(l[i:], "x86.") {
		e := word_end(l, i + 4)
		if e > i + 4 && e < len(l) && l[e] == '(' do return {l[i + 4:e], e + 1}, true
	}
	if (i == 0 || !is_word(l[i - 1]) && l[i - 1] != '.') && i + 11 <= len(l) && (l[i] == 'r' || l[i] == 'f') && l[i + 1] == '_' && is_hex8(l[i + 2:i + 10]) && l[i + 10] == '(' {
		return {"", i + 11}, true
	}
	if at_b && strings.has_prefix(l[i:], "native.") {
		e := word_end(l, i + 7)
		if e > i + 7 && e < len(l) && l[e] == '(' do return {"", e + 1}, true
	}
	return {}, false
}

// Address a sync line calls when that call is all it does, else false.
sync_target :: proc(l: string) -> (u32, bool) {
	// CALL_LIT: `\bx86\.call(?:_ext)?\((0x[0-9a-f]{8})\)`
	lit: u32
	nlit, nlits := 0, 0
	for i := 0; i < len(l); i += 1 {
		if !(i == 0 || !is_word(l[i - 1])) || !strings.has_prefix(l[i:], "x86.call") do continue
		j := i + 8
		if strings.has_prefix(l[j:], "_ext") do j += 4
		if !strings.has_prefix(l[j:], "(0x") || j + 12 > len(l) || !is_hex8(l[j + 3:j + 11]) || l[j + 11] != ')' do continue
		v, _ := strconv.parse_uint(l[j + 3:j + 11], 16)
		if nlit == 0 || u32(v) != lit do nlits += 1
		if nlit == 0 do lit = u32(v)
		nlit += 1
		i = j + 11
	}
	n := 0
	for i := 0; i < len(l); {
		m, ok := sync_match_at(l, i)
		if !ok {
			i += 1
			continue
		}
		if m.group == "call" || m.group == "call_ext" {
			n += 1
		} else if m.group != "" && !is_pure(m.group) {
			return 0, false
		}
		i = m.end
	}
	if nlit == 0 || nlits != 1 || n != nlit do return 0, false
	return lit, true
}

is_return :: proc(s: string) -> bool {
	return s == "return" || strings.has_prefix(s, "return ")
}

is_sync :: proc(l: string) -> bool {
	if is_return(strings.trim_space(l)) do return true
	for i := 0; i < len(l); {
		m, ok := sync_match_at(l, i)
		if !ok {
			i += 1
			continue
		}
		if m.group == "" || !is_pure(m.group) do return true
		i = m.end
	}
	return false
}

// REG_REF `\bc\.(promoted)\b` matches: calls fn with the register index and
// the span [i, e) of the match.
Reg_Ref :: struct {
	k:    int,
	i, e: int,
}

reg_refs :: proc(l: string, out: ^[dynamic]Reg_Ref, prefix := "c.") {
	clear(out)
	p := len(prefix)
	for i := 0; i + p < len(l); {
		if (i == 0 || !is_word(l[i - 1])) && strings.has_prefix(l[i:], prefix) {
			e := word_end(l, i + p)
			if k := promoted_index(l[i + p:e]); k >= 0 {
				append(out, Reg_Ref{k, i, e})
				i = e
				continue
			}
		}
		i += 1
	}
}

// REG_WRITE: a REG_REF followed by `\s*(?:<<|>>|&~|[-+*/%|&~])?=(?!=)`.
is_reg_write :: proc(l: string, e: int) -> bool {
	j := e
	for j < len(l) && strings.is_space(rune(l[j])) do j += 1
	assign :: proc(l: string, j: int) -> bool {
		return j < len(l) && l[j] == '=' && !(j + 1 < len(l) && l[j + 1] == '=')
	}
	if assign(l, j) do return true
	r := l[j:]
	if (strings.has_prefix(r, "<<") || strings.has_prefix(r, ">>") || strings.has_prefix(r, "&~")) && assign(l, j + 2) do return true
	if len(r) > 0 && strings.index_byte("-+*/%|&~", r[0]) >= 0 && assign(l, j + 1) do return true
	return false
}

// (store, reload) for a sync line; ok false for all registers.
Sync_Regs :: struct {
	sync:  ^Sync,
	start: u32,
}

sync_regs :: proc(sr: Sync_Regs, st: string) -> (Regs, Regs, bool) {
	if st == "return" do return sr.sync.ret[sr.start], 0, true
	t, ok := sync_target(st)
	if !ok do return 0, 0, false
	if v, has := sr.sync.call[t]; has do return v[0], v[1], true
	return 0, 0, false
}

// Returns (entry declarations, lines) with promoted registers in locals.
promote_regs :: proc(lines: []string, sr: Sync_Regs) -> ([]string, []string) {
	sync := make([]bool, len(lines))
	refs: [dynamic]Reg_Ref
	named, written: Regs
	for l, n in lines {
		sync[n] = is_sync(l)
		if sync[n] do continue
		reg_refs(l, &refs)
		for r in refs {
			named |= 1 << uint(r.k)
			if is_reg_write(l, r.e) do written |= 1 << uint(r.k)
		}
	}
	regs := named
	if regs == 0 do return {}, lines
	every := regs & written
	// Locals that may differ from x86.cpu: those written since the last sync on
	// the straight-line path, or all written ones at a point control can reach
	// from elsewhere (a loop head, a case, the end of a labeled or if block).
	dirty: Regs
	opens: [dynamic]bool // per open brace: does its close join paths?
	out := make([dynamic]string, 0, len(lines) + len(lines) / 4)
	for l, n in lines {
		st := strings.trim_space(l)
		code := st
		if c := strings.index(st, "//"); c >= 0 do code = st[:c]
		rest := code
		closes := 0
		if strings.has_prefix(code, "}") {
			rest = code[1:]
			closes = 1
		}
		no, nc := strings.count(rest, "{"), strings.count(rest, "}")
		closes += max(nc - no, 0)
		for _ in 0 ..< closes {
			fmt.assertf(len(opens) > 0, "unbalanced close: %s", l)
			if pop(&opens) do dirty = every
		}
		d := no - nc
		for _ in 0 ..< max(d, 0) do append(&opens, !strings.has_prefix(rest, "{"))
		if (d > 0 || strings.has_prefix(code, "case")) && !(strings.has_prefix(rest, "{") || strings.has_prefix(rest, "if ") || strings.has_prefix(rest, "B_")) {
			dirty = every // for, else, switch, case: entered from elsewhere
		}
		if !sync[n] {
			reg_refs(l, &refs)
			if len(refs) == 0 {
				append(&out, l)
				continue
			}
			b := strings.builder_make()
			at := 0
			for r in refs {
				if is_reg_write(l, r.e) do dirty |= 1 << uint(r.k)
				strings.write_string(&b, l[at:r.i])
				strings.write_string(&b, "g_")
				strings.write_string(&b, PROMOTED[r.k])
				at = r.e
			}
			strings.write_string(&b, l[at:])
			append(&out, strings.to_string(b))
			continue
		}
		ind := l[:len(l) - len(strings.trim_left(l, "\t"))]
		// A reload after the line must run after it, so the line cannot open a block.
		fmt.assertf(!strings.has_suffix(st, "{"), "sync line opens a block: %s", st)
		store, reload, ok := sync_regs(sr, st)
		if !ok do store, reload = every, regs
		for r, k in PROMOTED {
			if every & dirty & store >> uint(k) & 1 != 0 do append(&out, fmt.aprintf("%sc.%s = g_%s", ind, r, r))
		}
		append(&out, l)
		// A register neither stored nor reloaded still differs from x86.cpu.
		dirty &~= store | reload
		if !is_return(st) {
			for r, k in PROMOTED {
				if regs & reload >> uint(k) & 1 != 0 do append(&out, fmt.aprintf("%sg_%s = c.%s", ind, r, r))
			}
		}
	}
	assert(len(opens) == 0)
	decls: [dynamic]string
	for r, k in PROMOTED do if regs >> uint(k) & 1 != 0 do append(&decls, fmt.aprintf("g_%s := c.%s", r, r))
	return decls[:], out[:]
}

// Fail if the lifted lines st of ins name a GPR gpr_effect misses.
check_gpr_effect :: proc(ins: ^Insn, st: []string) {
	refs: [dynamic]Reg_Ref
	for l in st {
		reg_refs(l, &refs)
		for r in refs {
			if r.k < 8 && (ins.use | ins.mod) >> uint(r.k) & 1 == 0 {
				fmt.panicf("%08x %s %s: lift names %s", ins.address, ins.mnemonic, ins.op_str, PROMOTED[r.k])
			}
		}
	}
}

// ---------------------------------------------------------------- emission

Span :: struct {
	name: string,
	exit: u32,
}

Emitter :: struct {
	local:       map[u32]string, // entry addr -> proc name, for direct calls in this package
	native:      map[u32]string, // entry addr -> proc name in package native
	spans:       map[u32]Span, // start addr -> proc name in package native, exit addr
	span_exits:  Set,
	uses_native: bool,
	names:       map[u32]string, // entry addr -> readable name, from re/funcnames.txt
	sync:        ^Sync,
	unsupported: map[string]int,
	unsup_order: [dynamic]string, // unsupported keys in first-seen order
	structured:  int, // functions emitted as nested blocks and loops
	dispatched:  int, // functions emitted as a pc-dispatch loop
}

call_expr :: proc(em: ^Emitter, t: u32) -> string {
	// A direct call goes through x86.call while any probe is set, so
	// probes see calls inside a package too. WHY: docs/recompiler.md §7
	if n, ok := em.native[t]; ok {
		em.uses_native = true
		return fmt.aprintf("if x86.probe_n > 0 {{x86.call(%s)}} else {{native.%s()}}", hexu(t), n)
	}
	if n, ok := em.local[t]; ok do return fmt.aprintf("if x86.probe_n > 0 {{x86.call(%s)}} else {{%s()}}", hexu(t), n)
	return fmt.aprintf("x86.call_ext(%s)", hexu(t))
}

target_value :: proc(L: ^Lift, op: ^Cs_Op) -> string {
	if op.type == OP_REG do return lift_read(L, op)
	if op.type == OP_MEM do return fmt.aprintf("x86.rd32(%s)", lift_ea(L, op))
	unsupported(L, "indirect")
	return ""
}

// Control flow between basic blocks. emit_func lowers each block to lines
// with markers for its exits; structure() lays the blocks out as nested
// labeled blocks (a forward jump is `break`) and loops (a backward jump is
// `continue`), so jumps are direct branches. A function whose blocks do not
// nest that way (a jump into a loop past its head, an entry inside a loop)
// keeps the pc-dispatch loop, where every jump goes through the switch.
// WHY: docs/recompiler.md §1
GOTO :: "\x00goto " // jump to the block at the address
FALL :: "\x00fall" // last line: falls into the next block in address order
TABLE :: "\x00table " // switch-table jump at the address; pc holds the target
MAX_NEST :: 128 // deeper nesting overflows the Odin compiler's stack

Case :: struct {
	label:     u32,
	has_label: bool,
	lines:     []string,
}

marker :: proc(line: string) -> (string, string) {
	s := strings.trim_left(line, "\t")
	return line[:len(line) - len(s)], s
}

marker_addr :: proc(s: string, prefix: string) -> u32 {
	v, ok := strconv.parse_uint(s[len(prefix):], 0)
	assert(ok)
	return u32(v)
}

add_tab :: proc(dst: ^[dynamic]string, tab: string, src: []string) {
	for x in src do append(dst, strings.concatenate({tab, x}))
}

emit_func :: proc(em: ^Emitter, n: int, out: ^[dynamic]string) {
	f := funcs[n]
	multi := len(f.entries) > 1
	name := multi ? body_name(f, em.names) : em.local[f.start]
	if len(f.labels) > COLD_LABELS do append(out, `@(optimization_mode="none")`)
	if multi {
		append(out, fmt.aprintf("%s :: proc(entry: u32) {{", name))
	} else {
		append(out, fmt.aprintf("%s :: proc() {{", name))
	}
	append(out, "\tc := &x86.cpu")
	fs: X87
	x87_reset(&fs)
	live := flag_live[n]
	pcs := f.pcs
	body: [dynamic]string
	cases: [dynamic]Case // lines hold GOTO / FALL / TABLE markers
	open_case := false
	prev_nxt: u32
	have_prev := false // prev_nxt: address the last emitted instruction falls through to
	cur: u32
	have_cur := false
	span_used := false
	k := 0

	goto_ :: proc(em: ^Emitter, f: ^Func, t: u32) -> []string {
		if inside(f, t) && set_has(f.labels, t) do return slice.clone([]string{strings.concatenate({GOTO, hexu(t)})})
		return slice.clone([]string{call_expr(em, t), "return"})
	}

	for k < len(pcs) {
		pc := pcs[k]
		kp := k
		k += 1
		ins := f.insns[pc]
		if set_has(f.labels, pc) {
			if open_case {
				fs_flush(&fs, &body)
				// address order is not execution order across overlapping streams
				if have_prev && prev_nxt == pc {
					append(&body, FALL)
				} else {
					append(&body, ..goto_(em, f, prev_nxt))
				}
			}
			if have_cur do append(&cases, Case{cur, true, slice.clone(body[:])})
			clear(&body)
			cur, have_cur = pc, true
			open_case = true
			// The native span's hooks open the block at pc.
			if set_has(em.span_exits, pc) {
				em.uses_native = true
				append(&body, fmt.aprintf("if native.mode == .Check {{native.span_end(%s)}}", hexu(pc)))
			}
			if sp, ok := em.spans[pc]; ok {
				fmt.assertf(inside(f, sp.exit) && set_has(f.labels, sp.exit), "span %s exit %s is not a block", sp.name, hexu(sp.exit))
				em.uses_native = true
				span_used = true
				append(&body, fmt.aprintf("span_ok = x86.probe_n == 0 && native.%s()", sp.name), "if span_ok {", strings.concatenate({"\t", GOTO, hexu(sp.exit)}), "}")
			}
		} else if !open_case {
			continue
		} else {
			fmt.assertf(have_prev && prev_nxt == pc, "unlabeled overlap at %s", hexu(pc))
		}
		if ins == nil || set_has(f.bad, pc) {
			fs_flush(&fs, &body)
			append(&body, fmt.aprintf("x86.bad_insn(%s)", hexu(pc)), "return")
			open_case = false
			continue
		}
		nxt := pc + u32(ins.size)
		prev_nxt, have_prev = nxt, true
		kind, t := control(ins)
		m := ins.mnemonic
		err := ""
		lifted: {
			if kind == .None {
				// Fuse a flag producer with an immediately following consumer.
				nins := f.insns[nxt]
				cc := ""
				after: u8
				if nins != nil && !set_has(f.labels, nxt) && (is_fuse_arith(m) || is_fuse_logic(m)) {
					cc = jcc_cond(nins.mnemonic)
					if cc == "" do cc = setcc_cond(nins.mnemonic)
					if cc != "" do after = live[pc_index(f, nxt)]
				}
				L := lift(ins, live[kp], cc, after, &fs)
				if L.err != "" {
					err = L.err
					break lifted
				}
				st := L.s[:]
				check_gpr_effect(ins, st)
				if cc != "" && L.fused != "" {
					cond := L.fused
					k += 1 // nxt is not a label, so split_overlaps made pcs[k] == nxt
					prev_nxt = nxt + u32(nins.size)
					if setcc_cond(nins.mnemonic) != "" {
						L2 := Lift{i = nins}
						w := lift_write(&L2, &nins.ops[0], fmt.aprintf("u8(1) if %s else u8(0)", cond))
						if L2.err != "" {
							err = L2.err
							break lifted
						}
						append(&body, "{")
						add_tab(&body, "\t", st)
						append(&body, strings.concatenate({"\t", w}), "}")
						continue
					}
					// jcc: flags kept in locals; branch after the block.
					fs_flush(&fs, &body)
					append(&body, "{")
					add_tab(&body, "\t", st)
					tgt := u32(nins.ops[0].imm & 0xFFFFFFFF)
					append(&body, fmt.aprintf("\tif %s {{", cond))
					add_tab(&body, "\t\t", goto_(em, f, tgt))
					append(&body, "\t}", "}")
					nn := nxt + u32(nins.size)
					if !(nn in f.insns) || !inside(f, nn) {
						append(&body, ..goto_(em, f, nn))
						open_case = false
					}
					continue
				}
				if len(st) == 1 && !strings.contains(st[0], ":=") {
					append(&body, st[0])
				} else if len(st) > 0 {
					append(&body, "{")
					add_tab(&body, "\t", st)
					append(&body, "}")
				}
				in_ins := nxt in f.insns
				if !in_ins || f.insns[nxt] == nil && !set_has(f.labels, nxt) {
					if !inside(f, nxt) || !in_ins {
						fs_flush(&fs, &body)
						append(&body, ..goto_(em, f, nxt))
						open_case = false
					}
				}
				continue
			}
			fs_flush(&fs, &body)
			#partial switch kind {
			case .Jcc:
				cond: string
				switch {
				case m == "jecxz":
					cond = "c.ecx == 0"
				case strings.has_prefix(m, "loop"):
					append(&body, "c.ecx -= 1")
					switch m {
					case "loop":
						cond = "c.ecx != 0"
					case "loope":
						cond = "c.ecx != 0 && c.zf"
					case "loopne":
						cond = "c.ecx != 0 && !c.zf"
					case:
						panic(m)
					}
				case:
					cond = COND[jcc_cond(m)].expr
				}
				append(&body, fmt.aprintf("if %s {{", cond))
				add_tab(&body, "\t", goto_(em, f, t))
				append(&body, "}")
				if !(nxt in f.insns) || !inside(f, nxt) {
					append(&body, ..goto_(em, f, nxt))
					open_case = false
				}
			case .Jmp:
				append(&body, ..goto_(em, f, t))
				open_case = false
			case .Ret:
				r := ins.nops > 0 ? ins.ops[0].imm : 0
				append(&body, fmt.aprintf("c.esp += %d", 4 + r), "return")
				open_case = false
			case .Call, .Icall:
				if kind == .Call {
					tgt := call_expr(em, t)
					append(&body, "c.esp -= 4", fmt.aprintf("x86.wr32(c.esp, %s)", hexu(nxt)), tgt)
				} else {
					L := Lift{i = ins}
					v := target_value(&L, &ins.ops[0])
					if L.err != "" {
						err = L.err
						break lifted
					}
					append(&body, "{", fmt.aprintf("\tt := %s", v), "\tc.esp -= 4", fmt.aprintf("\tx86.wr32(c.esp, %s)", hexu(nxt)), "\tx86.call_ext(t)", "}")
				}
				if !(nxt in f.insns) || !inside(f, nxt) {
					append(&body, ..goto_(em, f, nxt))
					open_case = false
				}
			case .Ijmp:
				L := Lift{i = ins}
				v := target_value(&L, &ins.ops[0])
				if L.err != "" {
					err = L.err
					break lifted
				}
				append(&body, fmt.aprintf("pc = %s", v))
				if pc in f.tables {
					append(&body, strings.concatenate({TABLE, hexu(pc)}))
				} else {
					append(&body, "x86.call(pc)", "return")
				}
				open_case = false
			}
			continue
		}
		fs_flush(&fs, &body)
		if !(err in em.unsupported) do append(&em.unsup_order, err)
		em.unsupported[err] += 1
		append(&body, fmt.aprintf("x86.unsupported(%s) // %s %s", hexu(pc), ins.mnemonic, ins.op_str), "return")
		open_case = false
	}
	if open_case {
		// Ran off the decoded code (should not happen): fail loudly.
		fs_flush(&fs, &body)
		append(&body, fmt.aprintf("x86.bad_insn(%s)", hexu(pcs[len(pcs) - 1])), "return")
	}
	if have_cur do append(&cases, Case{cur, true, slice.clone(body[:])})
	clear(&body)
	assert(!fs.active)
	lines, ok := structure(f, cases[:])
	if !ok {
		em.dispatched += 1
		lines = dispatch(f, cases[:])
	} else {
		em.structured += 1
	}
	gdecl, plines := promote_regs(lines, {em.sync, f.start})
	used: [dynamic]string
	for u in fs.used do append(&used, u)
	slice.sort(used[:])
	for d in used do append(out, strings.concatenate({"\t", d}))
	for d in gdecl do append(out, strings.concatenate({"\t", d}))
	if span_used do append(out, "\tspan_ok: bool")
	append(out, ..plines)
	append(out, "}", "")
	if multi {
		for e in set_sorted(f.entries) do append(out, fmt.aprintf("%s :: proc() {{ %s(%s) }}", em.local[e], name, hexu(e)))
		append(out, "")
	}
}

dispatch :: proc(f: ^Func, cases: []Case) -> []string {
	out: [dynamic]string
	append(&out, fmt.aprintf("\tpc: u32 = %s", len(f.entries) > 1 ? "entry" : hexu(f.start)), "\tfor {", "\t\tswitch pc {")
	for c in cases {
		append(&out, fmt.aprintf("\t\tcase %s:", hexu(c.label)))
		for l in c.lines {
			ind, s := marker(l)
			if strings.has_prefix(s, GOTO) {
				append(&out, strings.concatenate({"\t\t\t", ind, "pc = ", s[len(GOTO):]}), strings.concatenate({"\t\t\t", ind, "continue"}))
			} else if s == FALL {
				append(&out, strings.concatenate({"\t\t\t", ind, "fallthrough"}))
			} else if strings.has_prefix(s, TABLE) {
				append(&out, strings.concatenate({"\t\t\t", ind, "continue"}))
			} else {
				append(&out, strings.concatenate({"\t\t\t", l}))
			}
		}
	}
	append(&out, "\t\tcase:", "\t\t\tx86.call(pc)", "\t\t\treturn", "\t\t}", "\t}")
	return out[:]
}

// Sorted table entries inside f of the switch jump at pc.
table_entries :: proc(f: ^Func, pc: u32) -> []u32 {
	s: Set
	for e in f.tables[pc] do if inside(f, e) do set_add(&s, e)
	return set_sorted(s)
}

// Blocks a block's lines jump to (by index), or false for a jump to an
// address that is not a block.
block_edges :: proc(f: ^Func, lines: []string, at: map[u32]int) -> ([]int, bool) {
	succ: [dynamic]int
	for l in lines {
		_, s := marker(l)
		ts: []u32
		if strings.has_prefix(s, GOTO) {
			ts = slice.clone([]u32{marker_addr(s, GOTO)})
		} else if strings.has_prefix(s, TABLE) {
			ts = table_entries(f, marker_addr(s, TABLE))
		} else {
			continue
		}
		for t in ts {
			i, ok := at[t]
			if !ok do return nil, false
			append(&succ, i)
		}
	}
	return succ[:], true
}

Con :: struct {
	kind: u8, // 'L' or 'B'
	o, c: int,
}

// Lines of f's body as nested blocks and loops, or false.
structure :: proc(f: ^Func, cases_in: []Case) -> ([]string, bool) {
	if len(cases_in) == 0 || cases_in[0].label != f.start do return nil, false
	cases := cases_in
	if len(f.entries) > 1 {
		// Block 0 picks the entry; the first block is the function start.
		sw: [dynamic]string
		append(&sw, "switch entry {")
		for e in set_sorted(f.entries) {
			if e == f.start do continue
			append(&sw, fmt.aprintf("case %s:", hexu(e)), strings.concatenate({"\t", GOTO, hexu(e)}))
		}
		append(&sw, "}", FALL)
		cs := make([]Case, len(cases_in) + 1)
		cs[0] = Case{lines = sw[:]}
		copy(cs[1:], cases_in)
		cases = cs
	}
	at: map[u32]int
	for c, i in cases do if c.has_label do at[c.label] = i
	succ := make([][]int, len(cases))
	fall := make([]bool, len(cases))
	for c, i in cases {
		s, ok := block_edges(f, c.lines, at)
		if !ok do return nil, false
		succ[i] = s
		fall[i] = len(c.lines) > 0 && c.lines[len(c.lines) - 1] == FALL
	}
	// Unreachable blocks are dropped: Odin rejects code after a return.
	reach_set := make([]bool, len(cases) + 1)
	reach_set[0] = true
	work: [dynamic]int
	append(&work, 0)
	for len(work) > 0 {
		i := pop(&work)
		visit :: proc(j: int, reach_set: []bool, work: ^[dynamic]int) {
			if !reach_set[j] {
				reach_set[j] = true
				append(work, j)
			}
		}
		for j in succ[i] do visit(j, reach_set, &work)
		if fall[i] do visit(i + 1, reach_set, &work)
	}
	keep: [dynamic]int
	pos := make([]int, len(cases) + 1)
	for r, i in reach_set {
		if r {
			pos[i] = len(keep)
			append(&keep, i)
		}
	}
	n := len(keep)
	// Constructs [open, close) over block positions: a loop from each
	// backward target to its last source, a block from the first forward
	// source to each forward target.
	loop_c := make([]int, n + 1)
	block_o := make([]int, n + 1)
	for &v in loop_c do v = -1
	for &v in block_o do v = -1
	loop_order, block_order: [dynamic]int
	for i in keep {
		for j in succ[i] {
			p, q := pos[i], pos[j]
			if q <= p {
				if loop_c[q] < 0 {
					append(&loop_order, q)
					loop_c[q] = p + 1
				}
				loop_c[q] = max(loop_c[q], p + 1)
			} else {
				if block_o[q] < 0 {
					append(&block_order, q)
					block_o[q] = p
				}
				block_o[q] = min(block_o[q], p)
			}
		}
	}
	cons: [dynamic]Con
	for q in loop_order do append(&cons, Con{'L', q, loop_c[q]})
	for q in block_order do append(&cons, Con{'B', block_o[q], q})
	// Make them nest: a block may open earlier, a loop may close later.
	nested := false
	for _ in 0 ..< 4 * len(cons) + 1 {
		changed := false
		for &a in cons {
			for &b in cons {
				if a.o < b.o && b.o < a.c && a.c < b.c {
					if b.kind == 'B' {
						b.o = a.o
					} else if a.kind == 'L' {
						a.c = b.c
					} else {
						return nil, false // a block closes inside a loop it opened before
					}
					changed = true
				}
			}
		}
		if !changed {
			nested = true
			break
		}
	}
	if !nested do return nil, false
	sorted := slice.clone(cons[:])
	slice.stable_sort_by(sorted, proc(x, y: Con) -> bool {
		if x.o != y.o do return x.o < y.o
		if x.c != y.c do return x.c > y.c
		return x.kind == 'B' && y.kind != 'B'
	})
	opens := make([][dynamic]Con, n + 1)
	for con in sorted do append(&opens[con.o], con)

	jump :: proc(ind: string, p, q: int) -> string {
		if q <= p do return fmt.aprintf("%scontinue L_%d", ind, q)
		return fmt.aprintf("%sbreak B_%d", ind, q)
	}

	out: [dynamic]string
	append(&out, "\tpc: u32")
	stack: [dynamic]Con
	reach := true
	for p in 0 ..= n {
		for len(stack) > 0 && stack[len(stack) - 1].c == p {
			con := pop(&stack)
			if con.kind == 'L' {
				if reach do append(&out, fmt.aprintf("\tbreak L_%d", con.o))
			} else {
				reach = true
			}
			append(&out, "\t}")
		}
		for con in stack do if con.c == p do return nil, false
		if p == n do break
		for con in opens[p] {
			if con.kind == 'L' {
				append(&out, fmt.aprintf("\tL_%d: for {{", p))
			} else {
				append(&out, fmt.aprintf("\tB_%d: {{", con.c))
			}
			append(&stack, con)
		}
		if len(stack) > MAX_NEST || !reach do return nil, false
		for l in cases[keep[p]].lines {
			ind, s := marker(l)
			if strings.has_prefix(s, GOTO) {
				append(&out, strings.concatenate({"\t", jump(ind, p, pos[at[marker_addr(s, GOTO)]])}))
			} else if s == FALL {
			} else if strings.has_prefix(s, TABLE) {
				ents := table_entries(f, marker_addr(s, TABLE))
				append(&out, strings.concatenate({"\t", ind, "switch pc {"}))
				ind2 := strings.concatenate({ind, "\t"})
				for e in ents {
					append(&out, strings.concatenate({"\t", ind, "case ", hexu(e), ":"}), strings.concatenate({"\t", jump(ind2, p, pos[at[e]])}))
				}
				append(&out, strings.concatenate({"\t", ind, "case:"}), strings.concatenate({"\t", ind, "\tx86.call(pc)"}), strings.concatenate({"\t", ind, "\treturn"}), strings.concatenate({"\t", ind, "}"}))
			} else {
				append(&out, strings.concatenate({"\t", l}))
			}
		}
		reach = fall[keep[p]]
	}
	return out[:], true
}

// Proc names keep the entry address, so they stay unique and greppable; a
// function tools/funcnames.py names is prefixed with that name.
// WHY: docs/exe_inventory.md §8
proc_name :: proc(f: ^Func, e: u32, names: map[u32]string) -> string {
	if n, ok := names[e]; ok do return fmt.aprintf("%s_%08x", n, e)
	return len(f.entries) > 1 ? fmt.aprintf("f_%08x", e) : fmt.aprintf("r_%08x", f.start)
}

// The shared body of a multi-entry function, behind one wrapper per entry.
body_name :: proc(f: ^Func, names: map[u32]string) -> string {
	if n, ok := names[f.start]; ok do return fmt.aprintf("%s_%08x_body", n, f.start)
	return fmt.aprintf("r_%08x", f.start)
}

// The file as text with CRLF and lone CR read as LF,
// so a Windows checkout generates the same code.
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	fmt.assertf(err == nil, "read %s: %v", path, err)
	s := string(data)
	if strings.index_byte(s, '\r') < 0 do return s
	s, _ = strings.replace_all(s, "\r\n", "\n")
	s, _ = strings.replace_all(s, "\r", "\n")
	return s
}

// {address: name} from re/funcnames.txt.
load_names :: proc(path: string) -> map[u32]string {
	names: map[u32]string
	text_s := read_text(path)
	for l in strings.split_lines_iterator(&text_s) {
		if !strings.has_prefix(l, "0x") do continue
		fields := strings.fields(l)
		a, n := fields[0], fields[1]
		ok := len(n) > 0 && !('0' <= n[0] && n[0] <= '9') && n[0] != '_' && word_end(n, 0) == len(n)
		fmt.assertf(ok, "not an Odin identifier: %s", l)
		v, _ := strconv.parse_uint(a, 0)
		names[u32(v)] = n
	}
	return names
}

// Sorted .odin files of a directory.
odin_files :: proc(dir: string) -> []string {
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	fmt.assertf(err == nil, "list %s: %v", dir, err)
	out: [dynamic]string
	for fi in fis do if strings.has_suffix(fi.name, ".odin") do append(&out, strings.concatenate({dir, "/", fi.name}))
	slice.sort(out[:])
	return out[:]
}

// Inlining. Under -use-separate-modules Odin emits one LLVM module per source
// file of a large package, and #force_inline does not cross modules: an x86
// helper (rd32, set_st, ...) called from generated code stays an out-of-line
// call. Each code.odin therefore ends with a copy of x86's
// #force_inline helpers, extracted from the x86 sources so those stay the
// single definition; x86 names they use are qualified.
// WHY: docs/recompiler.md §2
inline_helpers :: proc(x86_dir: string) -> (map[string]struct{}, []string) {
	decls, names: map[string]struct{}
	Helper :: struct {
		name:  string,
		lines: []string,
	}
	helpers: [dynamic]Helper
	for path in odin_files(x86_dir) {
		lines := strings.split(read_text(path), "\n")
		for i := 0; i < len(lines); {
			l := lines[i]
			// TOP_DECL `^(\w+(?:\s*,\s*\w+)*)\s*:`
			if e := word_end(l, 0); e > 0 {
				found: [dynamic]string
				append(&found, l[:e])
				j := e
				for {
					x := j
					for x < len(l) && strings.is_space(rune(l[x])) do x += 1
					if x >= len(l) || l[x] != ',' do break
					x += 1
					for x < len(l) && strings.is_space(rune(l[x])) do x += 1
					y := word_end(l, x)
					if y == x do break
					append(&found, l[x:y])
					j = y
				}
				for j < len(l) && strings.is_space(rune(l[j])) do j += 1
				if j < len(l) && l[j] == ':' do for d in found do decls[d] = {}
			}
			// INLINE_HEAD `^(\w+) :: #force_inline proc\b`
			e := word_end(l, 0)
			head := " :: #force_inline proc"
			if e == 0 || !strings.has_prefix(l[e:], head) || e + len(head) < len(l) && is_word(l[e + len(head)]) {
				i += 1
				continue
			}
			name := l[:e]
			j := i
			if !strings.has_suffix(strings.trim_right_space(l), "}") {
				for lines[j] != "}" {
					j += 1
					fmt.assertf(j < len(lines), "unterminated helper %s", name)
				}
			}
			if is_pure(name) {
				refs: [dynamic]Reg_Ref
				for hl in lines[i:j + 1] {
					reg_refs(hl, &refs, "cpu.")
					fmt.assertf(len(refs) == 0, "impure helper %s", name)
				}
			}
			append(&helpers, Helper{name, lines[i:j + 1]})
			names[name] = {}
			i = j + 1
		}
	}
	body: [dynamic]string
	for h in helpers {
		for l in h.lines {
			b := strings.builder_make()
			for i := 0; i < len(l); {
				if !is_word(l[i]) {
					strings.write_byte(&b, l[i])
					i += 1
					continue
				}
				e := word_end(l, i)
				w := l[i:e]
				if (i == 0 || l[i - 1] != '.') && w in decls && !(w in names) do strings.write_string(&b, "x86.")
				strings.write_string(&b, w)
				i = e
			}
			append(&body, strings.to_string(b))
		}
		append(&body, "")
	}
	return names, body[:]
}

// Hand-written replacements (port/src/native): a proc named Name_xxxxxxxx
// replaces the guest function at 0xxxxxxxxx. Its recompiled body is still
// emitted and registered; native.register swaps the dispatch entry, and direct
// calls from every package go to the native proc.
// WHY: docs/recompiler.md §8
//
// Native spans: a proc named Name_ssssssss_xxxxxxxx returning bool replaces
// the stretch of a recompiled body from the block at 0xssssssss to the block
// at 0xxxxxxxxx. The body calls it on entering the start block, with every
// register in x86.cpu, and jumps to the exit block when it returns true; on
// false (a fallback, or JE_NATIVE=check) the recompiled stretch runs. Under
// check, native.span_end at the exit block compares the two.
// WHY: docs/recompiler.md §8
native_scan :: proc(native_dir: string) -> (map[u32]string, map[u32]Span) {
	procs: map[u32]string
	spans: map[u32]Span
	// The address suffix of a proc name: `\w+_([0-9a-f]{8})`.
	suffix :: proc(w: string) -> (u32, bool) {
		if len(w) < 10 || w[len(w) - 9] != '_' || !is_hex8(w[len(w) - 8:]) do return 0, false
		v, _ := strconv.parse_uint(w[len(w) - 8:], 16)
		return u32(v), true
	}
	body_open :: proc(r: string) -> bool {
		return r == "{" || strings.has_prefix(r, "{") || strings.has_prefix(r, "#no_bounds_check {")
	}
	for path in odin_files(native_dir) {
		text_s := read_text(path)
		for l in strings.split_iterator(&text_s, "\n") {
			e := word_end(l, 0)
			if e == 0 do continue
			w := l[:e]
			r := l[e:]
			if strings.has_prefix(r, " :: proc() -> bool ") {
				// SPAN_HEAD `^(\w+_([0-9a-f]{8})_([0-9a-f]{8})) :: proc\(\) -> bool (?:#no_bounds_check )?\{`
				x, ok1 := suffix(w)
				s: u32
				ok2 := false
				if ok1 do s, ok2 = suffix(w[:len(w) - 9])
				if ok1 && ok2 && body_open(r[len(" :: proc() -> bool "):]) do spans[s] = Span{w, x}
			} else if strings.has_prefix(r, " :: proc() ") {
				// NATIVE_HEAD `^(\w+_([0-9a-f]{8})) :: proc\(\) (?:#no_bounds_check )?\{`
				a, ok := suffix(w)
				if ok && body_open(r[len(" :: proc() "):]) do procs[a] = w
			}
		}
	}
	return procs, spans
}

// `\bx86\.(helper)\(` -> `helper(`.
localize_calls :: proc(b: ^strings.Builder, text: string, names: map[string]struct{}) {
	last := 0
	for i := 0; i + 4 < len(text); {
		if text[i] == 'x' && (i == 0 || !is_word(text[i - 1])) && strings.has_prefix(text[i:], "x86.") {
			e := word_end(text, i + 4)
			if e < len(text) && text[e] == '(' && text[i + 4:e] in names {
				strings.write_string(b, text[last:i])
				last = i + 4
			}
			i = e
			continue
		}
		i += 1
	}
	strings.write_string(b, text[last:])
}
