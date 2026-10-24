// Maps source-file assert strings to the functions referencing them, and
// each .cpp file to the address range of those functions.
// Usage: srcmap <exe> <ghidra_funcs.txt>
// WHY: docs/exe_inventory.md
package srcmap

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../common"
import "../pe"

Row :: struct {
	lo, hi: u32,
	n:      int,
	name:   string,
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: srcmap <exe> <ghidra_funcs.txt>")
		os.exit(2)
	}
	img := pe.load(os.args[1])
	fs := common.ghidra_starts(os.args[2])
	refs := common.data_refs(img)
	data := img.data[common.DATA_LO - img.base:common.DATA_HI - img.base]
	by_file: map[string]map[u32]bool
	for s in common.suffixed_strings(data, {".cpp", ".h", ".inl"}, 4, 200) {
		name := strings.to_lower(common.base_name(string(data[s.start:s.end])))
		if !file_name(name) do continue
		rs := refs[u32(common.DATA_LO + s.start)]
		for r in rs {
			f := common.owner(fs, r) or_continue
			if name not_in by_file do by_file[name] = make(map[u32]bool)
			(&by_file[name])[f] = true
		}
	}
	rows: [dynamic]Row
	headers := 0
	for name, set in by_file {
		if !strings.has_suffix(name, ".cpp") {
			headers += 1
			continue
		}
		r := Row{max(u32), 0, len(set), name}
		for f in set do r.lo, r.hi = min(r.lo, f), max(r.hi, f)
		append(&rows, r)
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.lo != b.lo do return a.lo < b.lo
		if a.hi != b.hi do return a.hi < b.hi
		if a.n != b.n do return a.n < b.n
		return a.name < b.name
	})
	for r in rows do fmt.printf("%#x %#x % 4d %s\n", r.lo, r.hi, r.n, r.name)
	fmt.printf("cpp files %d headers %d\n", len(rows), headers)
}

// `[\w.\-]+\.(cpp|h|inl)`, the name already lowercased.
file_name :: proc(s: string) -> bool {
	for c in transmute([]u8)s do if !common.is_word(c) && c != '.' && c != '-' do return false
	for x in ([]string{".cpp", ".h", ".inl"}) do if len(s) > len(x) && strings.has_suffix(s, x) do return true
	return false
}
