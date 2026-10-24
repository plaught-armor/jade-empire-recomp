// Helpers the analysis tools share: Ghidra's function list, the function
// owning an address, and the code words that point at data.
package common

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../pe"

TEXT_LO :: 0x401000
TEXT_HI :: 0x6E1000
DATA_LO :: 0x6E1000
DATA_HI :: 0x895000

// The file's lines, CRLF or lone CR read as LF.
read_lines :: proc(path: string) -> []string {
	data, err := os.read_entire_file(path, context.allocator)
	fmt.assertf(err == nil, "read %s: %v", path, err)
	s, _ := strings.replace_all(string(data), "\r\n", "\n")
	s, _ = strings.replace_all(s, "\r", "\n")
	lines := strings.split(s, "\n")
	// A final newline ends the last line rather than starting another.
	if len(lines) > 0 && lines[len(lines) - 1] == "" do lines = lines[:len(lines) - 1]
	return lines
}

Ghidra_Func :: struct {
	start: u32,
	name:  string, // "" when the line has none
}

// re/ghidra_funcs.txt: `address [name]` per line, blank lines skipped, in
// file order.
read_ghidra :: proc(path: string) -> []Ghidra_Func {
	out: [dynamic]Ghidra_Func
	for line in read_lines(path) {
		f := strings.fields(line)
		if len(f) == 0 do continue
		h := f[0]
		if strings.has_prefix(h, "0x") || strings.has_prefix(h, "0X") do h = h[2:]
		v, ok := strconv.parse_uint(h, 16)
		fmt.assertf(ok, "bad ghidra line %q", line)
		append(&out, Ghidra_Func{u32(v), len(f) > 1 ? f[1] : ""})
	}
	return out[:]
}

// The function starts, sorted.
ghidra_starts :: proc(path: string) -> []u32 {
	fs: [dynamic]u32
	for f in read_ghidra(path) do append(&fs, f.start)
	slice.sort(fs[:])
	return fs[:]
}

// The last start at or below a in sorted fs, or false when none is.
owner :: proc(fs: []u32, a: u32) -> (u32, bool) {
	j, _ := slice.binary_search_by(fs, a, proc(x, k: u32) -> slice.Ordering {return x <= k ? .Less : .Greater})
	if j == 0 do return 0, false
	return fs[j - 1], true
}

// Every byte offset in .text (any alignment) whose word points into .data,
// as the referencing VA by the data VA.
data_refs :: proc(img: pe.Image) -> map[u32][dynamic]u32 {
	out := make(map[u32][dynamic]u32)
	b := img.base
	text := img.data[TEXT_LO - b:TEXT_HI - b]
	for i in 0 ..< len(text) - 3 {
		v := pe.le32(text, i)
		if v < DATA_LO || v >= DATA_HI do continue
		if v not_in out do out[v] = make([dynamic]u32)
		append(&out[v], u32(TEXT_LO + i))
	}
	return out
}

is_print :: proc(c: u8) -> bool {return ' ' <= c && c <= '~'}

// The NUL-terminated printable strings of buf as `[ -~]{lo,hi}\x00`
// matches them: each run of printable bytes ending in a NUL, cut to its last
// hi bytes, at least lo long. Offsets into buf, the NUL excluded.
Str :: struct {
	start, end: int,
}

strings_in :: proc(buf: []u8, lo, hi: int) -> []Str {
	out: [dynamic]Str
	s := 0
	for i in 0 ..< len(buf) {
		c := buf[i]
		if is_print(c) do continue
		if c == 0 && i - s >= lo do append(&out, Str{max(s, i - hi), i})
		s = i + 1
	}
	return out[:]
}

is_word :: proc(c: u8) -> bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || c == '_'
}

// The path's last component, split at / or \.
base_name :: proc(s: string) -> string {
	i := strings.last_index_any(s, "\\/")
	return s[i + 1:]
}

// The NUL-terminated strings `[ -~]{lo,hi}?\.(ext|...)\x00` matches, ext
// matched in any case: each printable run ending in one of exts and a NUL,
// the part before the extension cut to its last hi bytes and at least lo
// long. Offsets into buf, the NUL excluded.
suffixed_strings :: proc(buf: []u8, exts: []string, lo, hi: int) -> []Str {
	out: [dynamic]Str
	for r in strings_in(buf, 0, max(int)) {
		for x in exts {
			n := len(x)
			if r.end - r.start < n || !strings.equal_fold(string(buf[r.end - n:r.end]), x) do continue
			start := max(r.start, r.end - n - hi)
			if r.end - n - start >= lo do append(&out, Str{start, r.end})
			break
		}
	}
	return out[:]
}
