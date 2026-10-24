// Recursive-descent inventory of the unpacked JadeEmpire.exe's .text.
// Usage: inventory <exe> <ghidra_funcs.txt> <out.json> [--data-seeds]
// WHY: docs/exe_inventory.md
//
// Seeds: Ghidra's function starts and the OEP, with --data-seeds also every
// aligned .data word pointing into .text. Follows direct branches and calls,
// and records the instruction mix, indirect branches, switch tables and
// coverage. Writes the counts to out.json, the undecoded gaps of 16 bytes or
// more to out.json.gaps, and prints the counts but the two long lists.
package inventory

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import cs "../capstone"
import "../common"
import "../pe"

IAT_LO :: 0x6e1000
IAT_HI :: 0x6e1000 + 0x400
OEP :: 0x6b4923
MAX_INSN :: 3_000_000

// A counter keeping first-seen key order, as Python's Counter does.
Counter :: struct {
	n:     map[string]int,
	order: [dynamic]string,
}

count :: proc(c: ^Counter, key: string) {
	if key not_in c.n {
		k := strings.clone(key)
		append(&c.order, k)
		c.n[k] = 0
	}
	c.n[key] += 1
}

// Counts high to low, ties in first-seen order.
most_common :: proc(c: Counter) -> []string {
	keys := slice.clone(c.order[:])
	n := c.n
	for i in 1 ..< len(keys) {
		for j := i; j > 0 && n[keys[j]] > n[keys[j - 1]]; j -= 1 do keys[j], keys[j - 1] = keys[j - 1], keys[j]
	}
	return keys
}

Run :: struct {
	va, n: int,
}

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: inventory <exe> <ghidra_funcs.txt> <out.json> [--data-seeds]")
		os.exit(2)
	}
	img := pe.load(os.args[1])
	out_path := os.args[3]
	u32_at :: proc(img: pe.Image, va: int) -> int {
		v, ok := pe.u32_at(img, i64(va))
		fmt.assertf(ok, "%x is outside the image", va)
		return int(v)
	}
	seeds: [dynamic]int
	for f in common.read_ghidra(os.args[2]) do if common.TEXT_LO <= f.start && f.start < common.TEXT_HI do append(&seeds, int(f.start))
	append(&seeds, OEP)
	ghidra_seeds: map[int]bool
	for s in seeds do ghidra_seeds[s] = true
	data_ptrs: map[int]bool
	for va := common.DATA_LO; va < common.DATA_HI - 3; va += 4 {
		v := u32_at(img, va)
		if common.TEXT_LO <= v && v < common.TEXT_HI do data_ptrs[v] = true
	}
	if slice.contains(os.args[4:], "--data-seeds") {
		extra: [dynamic]int
		for p in data_ptrs do if p not_in ghidra_seeds do append(&extra, p)
		slice.sort(extra[:])
		append(&seeds, ..extra[:])
	}
	assert(cs.open() != 0, "capstone open failed")
	covered := make([]bool, common.TEXT_HI - common.TEXT_LO)
	mn, ind_call, ind_jmp: Counter
	switches: map[int]int // table -> entries
	call_targets, fstarts: map[int]bool
	seen_insn := make([]bool, common.TEXT_HI - common.TEXT_LO)
	work: [dynamic]int
	append(&work, ..seeds[:])
	for s in seeds do fstarts[s] = true
	n := 0
	ci: cs.Insn
	for len(work) > 0 && n < MAX_INSN {
		pc := pop(&work)
		for _ in 0 ..< 100000 {
			if !(common.TEXT_LO <= pc && pc < common.TEXT_HI) || seen_insn[pc - common.TEXT_LO] do break
			o := pc - int(img.base)
			code := img.data[o:o + 16]
			if cs.decode(raw_data(code), len(code), u64(pc), &ci) <= 0 do break
			seen_insn[pc - common.TEXT_LO] = true
			n += 1
			for b in 0 ..< int(ci.size) do covered[pc - common.TEXT_LO + b] = true
			m := cs.mnemonic(&ci)
			count(&mn, m)
			nxt := pc + int(ci.size)
			isjmp, iscall := cs.has_group(&ci, cs.GRP_JUMP), cs.has_group(&ci, cs.GRP_CALL)
			if cs.has_group(&ci, cs.GRP_RET) || m == "hlt" || m == "int3" || m == "ud2" do break
			if isjmp || iscall {
				op := ci.ops[0]
				if op.type == cs.OP_IMM {
					t := int(op.imm)
					if iscall {
						call_targets[t] = true
						fstarts[t] = true
					}
					append(&work, t)
					if m == "jmp" do break
				} else {
					kind := op.type == cs.OP_REG ? "reg" : "mem"
					if op.type == cs.OP_MEM {
						if op.base == 0 && op.index == 0 && IAT_LO <= op.disp && op.disp < IAT_HI {
							kind = "iat"
						} else if op.base == 0 && op.index != 0 && op.scale == 4 && isjmp {
							kind = "table"
						} else if op.base != 0 && op.index == 0 {
							kind = "vcall[reg+disp]"
						}
					}
					count(iscall ? &ind_call : &ind_jmp, kind)
					if kind == "table" {
						// MSVC switch: entries until a non-text value
						tbl := int(op.disp)
						ents: [dynamic]int
						for i in 0 ..< 4096 {
							v := u32_at(img, tbl + 4 * i)
							if !(common.TEXT_LO <= v && v < common.TEXT_HI) || i != 0 && tbl + 4 * i in switches do break
							append(&ents, v)
						}
						switches[tbl] = len(ents)
						append(&work, ..ents[:])
						for b in 0 ..< 4 * len(ents) {
							if common.TEXT_LO <= tbl + b && tbl + b < common.TEXT_HI do covered[tbl + b - common.TEXT_LO] = true
						}
					}
					if isjmp do break
				}
			}
			pc = nxt
		}
	}
	// x87 / SSE classification
	x87, sse, mmx, strops := 0, 0, 0, 0
	for k, c in mn.n {
		if strings.has_prefix(k, "f") && k != "fxsave" && k != "fxrstor" do x87 += c
		packed := strings.has_suffix(k, "ps") || strings.has_suffix(k, "ss") || strings.has_suffix(k, "pd") || strings.has_suffix(k, "sd")
		if packed && !strings.has_prefix(k, "f") && k != "movsd" || strings.has_prefix(k, "cvt") || strings.has_prefix(k, "movaps") || strings.has_prefix(k, "movups") do sse += c
		switch k {
		case "push", "pop", "pushal", "popal", "pushfd", "popfd", "pause":
		case:
			if strings.has_prefix(k, "p") do mmx += c
		}
		switch k {
		case "movsb", "movsd", "movsw", "stosb", "stosd", "stosw", "lodsb", "scasb", "cmpsb":
			strops += c
		case:
			if strings.has_prefix(k, "rep") do strops += c
		}
	}
	// vtable candidates in .data: runs >=3 of pointers to known function starts
	vt: [dynamic]Run
	for va := common.DATA_LO; va < common.DATA_HI - 4; {
		run := 0
		for va + 4 * run < common.DATA_HI && (u32_at(img, va + 4 * run) in fstarts) do run += 1
		if run >= 3 {
			append(&vt, Run{va, run})
			va += 4 * run
		} else do va += 4
	}
	covered_bytes, vt_slots, sw_entries := 0, 0, 0
	for c in covered do if c do covered_bytes += 1
	for r in vt do vt_slots += r.n
	for _, e in switches do sw_entries += e
	biggest := slice.clone(vt[:])
	slice.stable_sort_by(biggest, proc(a, b: Run) -> bool {return a.n > b.n})
	biggest = biggest[:min(20, len(biggest))]
	not_ghidra :: proc(set, ghidra: map[int]bool) -> int {
		c := 0
		for k in set do if k not_in ghidra do c += 1
		return c
	}

	w: Json
	w.full = strings.builder_make()
	w.short = strings.builder_make()
	open_obj(&w, "{", true)
	field(&w, "insns", n)
	field(&w, "seeds", len(seeds))
	field(&w, "fstarts", len(fstarts))
	field(&w, "covered_bytes", covered_bytes)
	field(&w, "text_bytes", common.TEXT_HI - common.TEXT_LO)
	key(&w, "top_mnemonics", false)
	open_obj(&w, "[", false)
	for k in most_common(mn) {
		item(&w, false)
		open_obj(&w, "[", false)
		item(&w, false)
		quoted(&w, k, false)
		item(&w, false)
		num(&w, mn.n[k], false)
		close_obj(&w, "]", false)
	}
	close_obj(&w, "]", false)
	field(&w, "x87", x87)
	field(&w, "sse", sse)
	field(&w, "mmx_like", mmx)
	field(&w, "strops", strops)
	counter(&w, "ind_call", ind_call)
	counter(&w, "ind_jmp", ind_jmp)
	field(&w, "switch_tables", len(switches))
	field(&w, "switch_entries", sw_entries)
	field(&w, "vtable_runs", len(vt))
	field(&w, "vtable_slots", vt_slots)
	key(&w, "biggest_vtables", false)
	open_obj(&w, "[", false)
	for r in biggest {
		item(&w, false)
		open_obj(&w, "[", false)
		item(&w, false)
		num(&w, r.va, false)
		item(&w, false)
		num(&w, r.n, false)
		close_obj(&w, "]", false)
	}
	close_obj(&w, "]", false)
	field(&w, "new_fstarts_not_in_ghidra", not_ghidra(fstarts, ghidra_seeds))
	field(&w, "data_text_ptrs", len(data_ptrs))
	field(&w, "data_ptrs_not_ghidra", not_ghidra(data_ptrs, ghidra_seeds))
	field(&w, "direct_call_targets", len(call_targets))
	field(&w, "call_targets_not_ghidra", not_ghidra(call_targets, ghidra_seeds))
	close_obj(&w, "}", true)
	write(out_path, strings.to_string(w.full))
	// uncovered gaps for later inspection
	gaps := strings.builder_make()
	strings.write_byte(&gaps, '[')
	ng := 0
	for i := 0; i < len(covered); {
		if covered[i] {
			i += 1
			continue
		}
		j := i
		for j < len(covered) && !covered[j] do j += 1
		if j - i >= 16 {
			fmt.sbprintf(&gaps, "%s[%d, %d]", ng == 0 ? "" : ", ", common.TEXT_LO + i, j - i)
			ng += 1
		}
		i = j
	}
	strings.write_byte(&gaps, ']')
	write(strings.concatenate({out_path, ".gaps"}), strings.to_string(gaps))
	fmt.println(strings.to_string(w.short))
}

write :: proc(path, s: string) {
	err := os.write_entire_file(path, transmute([]u8)s)
	fmt.assertf(err == nil, "write %s: %v", path, err)
}

// Python's json.dump with indent=1, written twice: in full to the file, and
// without the long lists (both = false) for stdout.
Json :: struct {
	full, short: strings.Builder,
	// Per open container in each: items written so far.
	full_n, short_n: [dynamic]int,
}

emit :: proc(w: ^Json, s: string, both: bool) {
	strings.write_string(&w.full, s)
	if both do strings.write_string(&w.short, s)
}

newline :: proc(w: ^Json, both: bool) {
	strings.write_byte(&w.full, '\n')
	for _ in 0 ..< len(w.full_n) do strings.write_byte(&w.full, ' ')
	if !both do return
	strings.write_byte(&w.short, '\n')
	for _ in 0 ..< len(w.short_n) do strings.write_byte(&w.short, ' ')
}

// Starts an item in the open container: a comma after the first, then a
// new line at the container's depth.
item :: proc(w: ^Json, both: bool) {
	if w.full_n[len(w.full_n) - 1] > 0 do strings.write_byte(&w.full, ',')
	w.full_n[len(w.full_n) - 1] += 1
	if both {
		if w.short_n[len(w.short_n) - 1] > 0 do strings.write_byte(&w.short, ',')
		w.short_n[len(w.short_n) - 1] += 1
	}
	newline(w, both)
}

open_obj :: proc(w: ^Json, c: string, both: bool) {
	emit(w, c, both)
	append(&w.full_n, 0)
	if both do append(&w.short_n, 0)
}

close_obj :: proc(w: ^Json, c: string, both: bool) {
	had := pop(&w.full_n) > 0
	sh := both && pop(&w.short_n) > 0
	// An empty container closes on its own line in neither.
	if had {
		strings.write_byte(&w.full, '\n')
		for _ in 0 ..< len(w.full_n) do strings.write_byte(&w.full, ' ')
	}
	if sh {
		strings.write_byte(&w.short, '\n')
		for _ in 0 ..< len(w.short_n) do strings.write_byte(&w.short, ' ')
	}
	emit(w, c, both)
}

key :: proc(w: ^Json, k: string, both: bool) {
	item(w, both)
	quoted(w, k, both)
	emit(w, ": ", both)
}

quoted :: proc(w: ^Json, s: string, both: bool) {
	for c in transmute([]u8)s do assert(' ' <= c && c <= '~' && c != '"' && c != '\\', "string needs JSON escapes")
	emit(w, "\"", both)
	emit(w, s, both)
	emit(w, "\"", both)
}

num :: proc(w: ^Json, v: int, both: bool) {
	emit(w, fmt.tprintf("%d", v), both)
}

field :: proc(w: ^Json, k: string, v: int) {
	key(w, k, true)
	num(w, v, true)
}

counter :: proc(w: ^Json, k: string, c: Counter) {
	key(w, k, true)
	open_obj(w, "{", true)
	for name in c.order {
		key(w, name, true)
		num(w, c.n[name], true)
	}
	close_obj(w, "}", true)
}
