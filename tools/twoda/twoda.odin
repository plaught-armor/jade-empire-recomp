// Read Jade Empire 2DA tables, binary (2DA V2.b) or text (2DA V2.0). WHY: docs/modding.md §1
//
// The base tables sit in GAME_RIMS as type 2017 (binary); patched copies in
// override/ are text. The binary layout is checked as it is read
// (every cell offset inside the string pool, the pool ending the file), so a
// layout guess that is wrong fails loudly instead of yielding shifted cells.
//
// Usage:
//   twoda dump FILE [COLUMN...]   rows as tab-separated text ("" cells shown as ****)
//   twoda style GAMEDIR STYLE      attack rows of a combat style (GetCurrentStyle value)
package twoda

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../common"
import "../pe"
import "../rim"

USAGE :: `Usage:
  twoda dump FILE [COLUMN...]   rows as tab-separated text ("" cells shown as ****)
  twoda style GAMEDIR STYLE      attack rows of a combat style (GetCurrentStyle value)`

// miniglobal: the global tables; globalunload: each style's AS (attack anims,
// ranges, damage) and MV (moves) tables. No 2DA is in chitin.key.
GAME_RIMS :: [?]string{"miniglobal-a.rim", "globalunload-a.rim"}
TYPE_2DA :: 2017
BINARY_MAGIC :: "2DA V2.b\n"
TEXT_MAGIC :: "2DA V2.0"
EMPTY :: "****"
STYLE_COLUMNS :: [?]string{"label", "anim", "minrange", "maxrange", "unblockable", "hdamage"}
MAX_FIELDS :: 65536 // bound on header / row-label scans

Table :: struct {
	columns, labels: []string,
	rows:            [][]string,
}

// A row keyed by lower-case column name, plus "_row" for its label.
Record :: map[string]string

// count tab-terminated strings from pos (count < 0: until a NUL byte).
// Returns the strings and the position after the last.
tab_list :: proc(d: []u8, pos: int, count: int) -> ([]string, int) {
	out: [dynamic]string
	pos := pos
	for _ in 0 ..< MAX_FIELDS {
		if count < 0 && d[pos] == 0 do return out[:], pos + 1
		if count >= 0 && len(out) == count do return out[:], pos
		end, ok := slice.linear_search(d[pos:], '\t')
		assert(ok, "tab-terminated field runs off the end")
		append(&out, common.latin1(d[pos:pos + end]))
		pos += end + 1
	}
	panic(fmt.tprintf("more than %d fields", MAX_FIELDS))
}

parse_binary :: proc(d: []u8) -> Table {
	assert(strings.has_prefix(string(d), BINARY_MAGIC))
	cols, pos := tab_list(d, len(BINARY_MAGIC), -1)
	nrows := int(pe.le32(d, pos))
	labels: []string
	labels, pos = tab_list(d, pos + 4, nrows)
	ncells := nrows * len(cols)
	offs := d[pos:pos + 2 * ncells]
	pos += 2 * ncells
	pool_size := int(pe.le16(d, pos))
	pool := d[pos + 2:]
	fmt.assertf(len(pool) == pool_size, "(%d, %d)", len(pool), pool_size)
	rows := make([][]string, nrows)
	for r in 0 ..< nrows {
		row := make([]string, len(cols))
		for c in 0 ..< len(cols) {
			o := int(pe.le16(offs, 2 * (r * len(cols) + c)))
			fmt.assertf(o < pool_size, "(%d, %d, %d, %d)", r, c, o, pool_size)
			end, ok := slice.linear_search(pool[o:], 0)
			assert(ok, "cell runs off the pool")
			row[c] = common.latin1(pool[o:o + end])
		}
		rows[r] = row
	}
	return {cols, labels, rows}
}

parse_text :: proc(d: []u8) -> Table {
	assert(strings.has_prefix(string(d), TEXT_MAGIC))
	lines: [dynamic]string
	for ln in common.py_splitlines(common.latin1(d))[1:] {
		if strings.trim_left_proc(ln, common.py_space) != "" do append(&lines, ln)
	}
	if len(lines) > 0 && strings.has_prefix(strings.trim_left_proc(lines[0], common.py_space), "DEFAULT:") do ordered_remove(&lines, 0)
	cols := common.py_fields(lines[0])
	labels: [dynamic]string
	rows: [dynamic][]string
	for ln in lines[1:] {
		f := common.py_fields(ln)
		fmt.assertf(len(f) == len(cols) + 1, "(%d, %d, %q)", len(f), len(cols), ln[:min(60, len(ln))])
		append(&labels, f[0])
		for &v in f[1:] do if v == EMPTY do v = ""
		append(&rows, f[1:])
	}
	return {cols, labels[:], rows[:]}
}

parse :: proc(d: []u8) -> Table {
	return strings.has_prefix(string(d), BINARY_MAGIC) ? parse_binary(d) : parse_text(d)
}

load :: proc(path: string) -> Table {
	return parse(rim.read(path))
}

// The table resref as the engine sees it: override/<resref>.2da if
// present (any case), else the binary copy in one of GAME_RIMS.
game_table :: proc(game, resref: string) -> Table {
	want := strings.concatenate({strings.to_lower(resref), ".2da"})
	over := strings.concatenate({game, "/override"})
	fis, err := os.read_all_directory_by_path(over, context.allocator)
	if err != nil do common.die("%s: %v", over, err)
	for fi in fis {
		if strings.to_lower(fi.name) == want do return load(strings.concatenate({over, "/", fi.name}))
	}
	for rim_name in GAME_RIMS {
		data := rim.read(strings.concatenate({game, "/data/", rim_name}))
		for e in rim.entries(data) {
			if e.type == TYPE_2DA && strings.to_lower(e.ref) == strings.to_lower(resref) do return parse(data[e.off:e.off + e.size])
		}
	}
	g := GAME_RIMS
	common.die("no 2DA %s in override/ or %s", resref, strings.join(g[:], ", "))
}

// Each row as a Record.
records :: proc(t: Table) -> []Record {
	out := make([]Record, len(t.rows))
	for row, i in t.rows {
		r := make(Record)
		for c, k in t.columns do r[strings.to_lower(c)] = row[k]
		r["_row"] = t.labels[i]
		out[i] = r
	}
	return out
}

// The attack rows (AS table records) of combat style `style`, the value
// GetCurrentStyle returns: a stylesuperlist row, whose styledata column
// names a styledata row, whose animsound2da column names the AS table.
// Rows with no anim are dropped. WHY: docs/modding.md §5
style_attacks :: proc(game: string, style: int) -> []Record {
	sup := records(game_table(game, "stylesuperlist"))
	fmt.assertf(0 <= style && style < len(sup), "(%d, %d)", style, len(sup))
	data_row := sup[style]["styledata"]
	if data_row == "" do common.die("style %d (%s) has no styledata row", style, sup[style]["label"])
	sd := records(game_table(game, "styledata"))
	n, ok := strconv.parse_int(data_row, 10)
	fmt.assertf(ok, "styledata row %q", data_row)
	out: [dynamic]Record
	for r in records(game_table(game, sd[n]["animsound2da"])) do if r["anim"] != "" do append(&out, r)
	return out[:]
}

main :: proc() {
	a := os.args
	if len(a) == 4 && a[1] == "style" {
		style, ok := strconv.parse_int(strings.trim_space(a[3]), 10)
		if !ok do common.die("invalid style %q", a[3])
		for r in style_attacks(a[2], style) {
			cells: [dynamic]string
			for k in STYLE_COLUMNS {
				v := r[k]
				append(&cells, v == "" ? EMPTY : v)
			}
			fmt.println(strings.join(cells[:], "\t"))
		}
		return
	}
	if len(a) < 3 || a[1] != "dump" do common.die(USAGE)
	t := load(a[2])
	want := make(map[string]bool)
	for c in a[3:] do want[strings.to_lower(c)] = true
	idx: [dynamic]int
	for c, i in t.columns do if len(want) == 0 || strings.to_lower(c) in want do append(&idx, i)
	missing: [dynamic]string
	for w in want {
		found := false
		for i in idx do if strings.to_lower(t.columns[i]) == w do found = true
		if !found do append(&missing, w)
	}
	if len(missing) > 0 {
		slice.sort(missing[:])
		common.die("no column %s in %s", strings.join(missing[:], ", "), a[2])
	}
	line: [dynamic]string
	append(&line, "row")
	for i in idx do append(&line, t.columns[i])
	fmt.println(strings.join(line[:], "\t"))
	for lab, r in t.labels {
		clear(&line)
		append(&line, lab)
		for i in idx do append(&line, t.rows[r][i] == "" ? EMPTY : t.rows[r][i])
		fmt.println(strings.join(line[:], "\t"))
	}
}
