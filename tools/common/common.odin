// Helpers the analysis tools share: Ghidra's function list, the function
// owning an address, and the code words that point at data.
package common

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
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

// Prints msg to stderr and exits 1, as a Python SystemExit(msg) does.
die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

// Bytes read as Latin-1, returned as UTF-8.
latin1 :: proc(b: []u8) -> string {
	sb := strings.builder_make_len_cap(0, len(b))
	for c in b do strings.write_rune(&sb, rune(c))
	return strings.to_string(sb)
}

// Python's str.split() with no separator, over Latin-1 text.
py_space :: proc(r: rune) -> bool {
	switch r {
	case '\t' ..= '\r', 0x1c ..= 0x20, 0x85, 0xa0:
		return true
	}
	return false
}

py_fields :: proc(s: string) -> []string {
	return strings.fields_proc(s, py_space)
}

// Python's str.splitlines() over Latin-1 text.
py_splitlines :: proc(s: string) -> []string {
	out: [dynamic]string
	start, i := 0, 0
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85:
		case '\r':
			if i + 1 < len(s) && s[i + 1] == '\n' do n += 1
		case:
			i += n
			continue
		}
		append(&out, s[start:i])
		i += n
		start = i
	}
	if start < len(s) do append(&out, s[start:])
	return out[:]
}

// Python's repr() of a float.
py_repr_float :: proc(f: f64) -> string {
	if f != f do return "nan"
	if f > max(f64) do return "inf"
	if f < -max(f64) do return "-inf"
	buf: [64]u8
	e := string(strconv.write_float(buf[:], f, 'e', -1, 64)) // "+1.5e+00"
	sb := strings.builder_make()
	if e[0] == '-' do strings.write_byte(&sb, '-')
	x := strings.index_byte(e, 'e')
	digits, _ := strings.remove_all(e[1:x], ".")
	exp, _ := strconv.parse_int(e[x + 1:], 10)
	// Python writes the shortest digits in fixed notation when the decimal
	// point falls within 16 places, else as d.ddde+XX.
	decpt, n := exp + 1, len(digits)
	if -4 < decpt && decpt <= 16 {
		switch {
		case decpt <= 0:
			strings.write_string(&sb, "0.")
			for _ in 0 ..< -decpt do strings.write_byte(&sb, '0')
			strings.write_string(&sb, digits)
		case decpt >= n:
			strings.write_string(&sb, digits)
			for _ in 0 ..< decpt - n do strings.write_byte(&sb, '0')
			strings.write_string(&sb, ".0")
		case:
			strings.write_string(&sb, digits[:decpt])
			strings.write_byte(&sb, '.')
			strings.write_string(&sb, digits[decpt:])
		}
	} else {
		strings.write_byte(&sb, digits[0])
		if n > 1 {
			strings.write_byte(&sb, '.')
			strings.write_string(&sb, digits[1:])
		}
		fmt.sbprintf(&sb, "e%s%02d", exp < 0 ? "-" : "+", abs(exp))
	}
	return strings.to_string(sb)
}

// Python's repr() of a str whose characters are all below 256.
py_repr_str :: proc(s: string) -> string {
	q: u8 = '\''
	if strings.contains_rune(s, '\'') && !strings.contains_rune(s, '"') do q = '"'
	sb := strings.builder_make()
	strings.write_byte(&sb, q)
	for r in s {
		switch {
		case r == rune(q) || r == '\\':
			strings.write_byte(&sb, '\\')
			strings.write_rune(&sb, r)
		case r == '\t': strings.write_string(&sb, `\t`)
		case r == '\n': strings.write_string(&sb, `\n`)
		case r == '\r': strings.write_string(&sb, `\r`)
		case r < 0x20 || 0x7f <= r && r <= 0xa0 || r == 0xad: fmt.sbprintf(&sb, `\x%02x`, r)
		case: strings.write_rune(&sb, r)
		}
	}
	strings.write_byte(&sb, q)
	return strings.to_string(sb)
}

// Python's round(x): the nearest integer, ties to even.
py_round :: proc(x: f64) -> int {
	r := math.floor(x)
	d := x - r
	if d > 0.5 || d == 0.5 && int(r) & 1 != 0 do r += 1
	return int(r)
}

// Python's math.hypot(x, y), correctly rounded (Python's result in all but
// rare cases): the square root of x*x + y*y summed exactly in two doubles,
// corrected by one Newton step on the exact residual. No FMA, so the same
// on every target.
py_hypot :: proc(x, y: f64) -> f64 {
	two_prod :: proc(a, b: f64) -> (f64, f64) {
		SPLIT :: 134217729.0 // 2^27 + 1, Dekker's split
		p := a * b
		ta, tb := SPLIT * a, SPLIT * b
		ah, bh := ta - (ta - a), tb - (tb - b)
		al, bl := a - ah, b - bh
		return p, ((ah * bh - p) + ah * bl + al * bh) + al * bl
	}
	x, y := abs(x), abs(y)
	if x < y do x, y = y, x
	if x > max(f64) do return x
	if y == 0 || x != x || y != y do return x + y
	// Scale by a power of two so squares neither overflow nor go subnormal.
	_, e := math.frexp(x)
	scale := math.ldexp(1.0, -e)
	x, y = x * scale, y * scale
	xh, xl := two_prod(x, x)
	yh, yl := two_prod(y, y)
	s := xh + yh
	sl := (xh - s) + yh + xl + yl // exact sum error, as x >= y
	h := math.sqrt(s + sl)
	hh, hl := two_prod(h, h)
	h += ((s - hh) - hl + sl) / (2 * h)
	return math.ldexp(h, e)
}
