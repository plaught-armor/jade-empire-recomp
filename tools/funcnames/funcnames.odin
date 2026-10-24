// Readable names for JadeEmpire.exe functions, for the recompiler's proc names.
// Usage: funcnames <exe> <re dir> > re/funcnames.txt
//
// Writes `address name source`, one line per named function start. Sources,
// the first that names a function wins:
//   curated  re/names.txt
//   ghidra   library functions Ghidra recognized in re/ghidra_funcs.txt
//   method   the one `Class::Method` the function's own log or assert strings name
//   nws      the NWScript engine function the action table dispatches to it
//   file     the source file its assert strings name, or that the functions on
//            both sides of it name (MSVC links each object file contiguously)
// WHY: docs/exe_inventory.md §8
package funcnames

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../common"
import "../pe"

// Function start -> name, keys in the order the source found them.
Names :: map[u32]string

// An identifier from a symbol: `FID_conflict:_free` -> `free`,
// `__87except` -> `fn_87except`.
ident :: proc(sym: string) -> string {
	s := sym
	if strings.has_prefix(s, "FID_conflict:") do s = s[strings.last_index_byte(s, ':') + 1:]
	s, _ = strings.replace_all(s, "~", "dtor_")
	b := strings.builder_make()
	gap := false
	for c in transmute([]u8)s {
		if 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' {
			if gap && len(b.buf) > 0 do strings.write_byte(&b, '_')
			gap = false
			strings.write_byte(&b, c)
		} else do gap = true
	}
	out := strings.to_string(b)
	if len(out) > 0 && '0' <= out[0] && out[0] <= '9' do return strings.concatenate({"fn_", out})
	return out
}

// The one name in set, or false when it holds several.
single :: proc(set: map[string]bool) -> (string, bool) {
	if len(set) != 1 do return "", false
	for k in set do return k, true
	unreachable()
}

add :: proc(m: ^map[u32]map[string]bool, f: u32, name: string) {
	if f not_in m do m[f] = make(map[string]bool)
	(&m[f])[name] = true
}

// {function: Class_Method} for functions whose strings name one method.
methods :: proc(fs: []u32, data: []u8, refs: map[u32][dynamic]u32) -> Names {
	seen: map[u32]map[string]bool
	for r in common.strings_in(data, 6, 300) {
		rs := refs[u32(common.DATA_LO + r.start)]
		if len(rs) == 0 do continue
		s := data[r.start:r.end]
		// \b(C[A-Za-z0-9_]+)::(~?[A-Za-z_][A-Za-z0-9_]*)
		p := 0
		for p < len(s) {
			if s[p] != 'C' || p > 0 && common.is_word(s[p - 1]) {
				p += 1
				continue
			}
			q := p + 1
			for q < len(s) && common.is_word(s[q]) do q += 1
			m := q + 2
			if q - p < 2 || m > len(s) || s[q] != ':' || s[q + 1] != ':' {
				p += 1
				continue
			}
			if m < len(s) && s[m] == '~' do m += 1
			if m >= len(s) || !(common.is_word(s[m]) && !('0' <= s[m] && s[m] <= '9')) {
				p += 1
				continue
			}
			e := m + 1
			for e < len(s) && common.is_word(s[e]) do e += 1
			name := strings.concatenate({string(s[p:q]), "_", ident(string(s[q + 2:e]))})
			for a in rs {
				f := common.owner(fs, a) or_continue
				add(&seen, f, name)
			}
			p = e
		}
	}
	out: Names
	for f, set in seen do if n, ok := single(set); ok do out[f] = n
	return out
}

// {function: file stem} from .cpp strings, filled across same-file gaps.
files :: proc(fs: []u32, data: []u8, refs: map[u32][dynamic]u32) -> Names {
	direct: map[u32]map[string]bool
	for r in common.suffixed_strings(data, {".cpp"}, 4, 200) {
		rs := refs[u32(common.DATA_LO + r.start)]
		name := strings.to_lower(common.base_name(string(data[r.start:r.end])))
		if !cpp_name(name) do continue
		for a in rs {
			f := common.owner(fs, a) or_continue
			add(&direct, f, ident(name[:len(name) - 4]))
		}
	}
	one: Names
	for f, set in direct do if n, ok := single(set); ok do one[f] = n
	marked: [dynamic]u32
	for f in one do append(&marked, f)
	slice.sort(marked[:])
	out: Names
	for f, n in one do out[f] = n
	for k in 0 ..< max(len(marked) - 1, 0) {
		a, b := marked[k], marked[k + 1]
		if one[a] != one[b] do continue
		lo, _ := slice.linear_search(fs, a)
		hi, _ := slice.linear_search(fs, b)
		gap := fs[lo + 1:hi]
		inside := false
		for f in gap do if f in direct do inside = true
		if inside do continue
		for f in gap do out[f] = one[a]
	}
	return out
}

// `[\w.\-]+\.cpp`, the name already lowercased.
cpp_name :: proc(s: string) -> bool {
	for c in transmute([]u8)s do if !common.is_word(c) && c != '.' && c != '-' do return false
	return len(s) > 4 && strings.has_suffix(s, ".cpp")
}

// A table's rows as (key column, value column): `#` lines and blank lines
// skipped, split at tabs when the line has one, else at whitespace.
table :: proc(path: string, key := 0, val := 1) -> [][2]string {
	rows: [dynamic][2]string
	for l in common.read_lines(path) {
		if strings.has_prefix(l, "#") || strings.trim_space(l) == "" do continue
		p := strings.index_byte(l, '\t') >= 0 ? strings.split(l, "\t") : strings.fields(l)
		append(&rows, [2]string{p[key], p[val]})
	}
	return rows[:]
}

hex :: proc(s: string) -> u32 {
	h := s
	if strings.has_prefix(h, "0x") || strings.has_prefix(h, "0X") do h = h[2:]
	v, ok := strconv.parse_uint(h, 16)
	fmt.assertf(ok, "bad address %q", s)
	return u32(v)
}

is_digits :: proc(s: string) -> bool {
	if s == "" do return false
	for c in transmute([]u8)s do if c < '0' || c > '9' do return false
	return true
}

// {handler: nws_Name}; a handler shared by several actions gets `_etc`.
nws :: proc(re_dir: string) -> Names {
	names: map[string]string
	for r in table(strings.concatenate({re_dir, "/nwscript_functions.tsv"})) do names[r[0]] = r[1]
	by: map[u32][dynamic]string
	order: [dynamic]u32
	for r in table(strings.concatenate({re_dir, "/nwscript_handlers.tsv"})) {
		n, ok := names[r[0]]
		if !is_digits(r[0]) || !ok do continue
		h := hex(r[1])
		if h not_in by {
			by[h] = make([dynamic]string)
			append(&order, h)
		}
		append(&by[h], n)
	}
	out: Names
	for h in order {
		n := by[h]
		out[h] = strings.concatenate({"nws_", n[0], len(n) > 1 ? "_etc" : ""})
	}
	return out
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: funcnames <exe> <re dir>")
		os.exit(2)
	}
	img := pe.load(os.args[1])
	re_dir := os.args[2]
	data := img.data[common.DATA_LO - img.base:common.DATA_HI - img.base]
	refs := common.data_refs(img)
	ghidra := common.read_ghidra(strings.concatenate({re_dir, "/ghidra_funcs.txt"}))
	fs := common.ghidra_starts(strings.concatenate({re_dir, "/ghidra_funcs.txt"}))
	curated, lib: Names
	for r in table(strings.concatenate({re_dir, "/names.txt"})) {
		a := hex(r[0])
		if a < common.TEXT_HI do curated[a] = r[1]
	}
	for g in ghidra do if !strings.has_prefix(g.name, "FUN_") do lib[g.start] = ident(g.name)
	Source :: struct {
		name:  string,
		names: Names,
	}
	sources := [?]Source {
		{"curated", curated},
		{"ghidra", lib},
		{"method", methods(fs, data, refs)},
		{"nws", nws(re_dir)},
		{"file", files(fs, data, refs)},
	}
	Named :: struct {
		name: string,
		src:  int,
	}
	named: map[u32]Named
	for s, k in sources {
		for a, n in s.names {
			if a not_in named && common.TEXT_LO <= a && a < common.TEXT_HI && n != "" do named[a] = {n, k}
		}
	}
	count: [len(sources)]int
	addrs: [dynamic]u32
	for a, n in named {
		count[n.src] += 1
		append(&addrs, a)
	}
	slice.sort(addrs[:])
	fmt.println("# Generated by tools/funcnames. Do not edit; see docs/exe_inventory.md §8.")
	fmt.print("#")
	for s, k in sources do fmt.printf("%s %s %d", k == 0 ? "" : ",", s.name, count[k])
	fmt.printf(" of %d functions\n", len(fs))
	for a in addrs do fmt.printf("%#x %s %s\n", a, named[a].name, sources[named[a].src].name)
}
