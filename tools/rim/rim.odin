// List and extract Jade Empire RIM archives. WHY: docs/modding.md §1
//
// Usage:
//   rim list FILE.rim [SUBSTRING]   resref, extension, size of each entry
//   rim get FILE.rim OUTDIR NAME... write NAME (resref.ext) to OUTDIR
//
// Layout (little endian): "RIM V1.0", u32 0, u32 entry count, u32 entry table
// offset; each entry is 32 bytes: char resref[16], u16 type, u16 0, u32 index,
// u32 data offset, u32 data size. Data is stored uncompressed.
// A module folder data/<module>/ holds a010.rim (scripts, dialogs, templates)
// and a010-a.rim (area geometry and textures); a file in override/ with the
// same resref.ext replaces the RIM entry.
package rim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../common"
import "../pe"

USAGE :: `Usage:
  rim list FILE.rim [SUBSTRING]   resref, extension, size of each entry
  rim get FILE.rim OUTDIR NAME... write NAME (resref.ext) to OUTDIR`

MAGIC :: "RIM V1.0"
ENTRY :: 32
ENTRIES_MAX :: 1 << 16

Entry :: struct {
	ref:             string,
	type, off, size: int,
}

// Resource type id -> extension, named from each type's file magic in the
// shipped RIMs (Jade Empire's ids differ from KotOR's). Others print as numbers.
ext :: proc(ty: int) -> string {
	switch ty {
	case 2002: return "mdl"
	case 2010: return "ncs"
	case 2017: return "2da"
	case 2026: return "cre"
	case 2029: return "dlg"
	case 2031: return "trg"
	case 2043: return "pla"
	case 2053: return "pwk"
	case 3000: return "lyt"
	case 3001: return "vis"
	case 3012: return "qst"
	case 3013: return "sto"
	case 3015: return "hex"
	case 3016: return "mdx"
	case 3017: return "tpc"
	case 3022: return "fsm"
	case 3023: return "scn"
	}
	return fmt.aprintf("%d", ty)
}

// The entries of a RIM image.
entries :: proc(data: []u8) -> []Entry {
	if len(data) < 20 || string(data[:8]) != MAGIC do common.die("not a RIM V1.0 file")
	n, table := int(pe.le32(data, 12)), int(pe.le32(data, 16))
	if n > ENTRIES_MAX || table + n * ENTRY > len(data) do common.die("entry table out of range: %d at %#x", n, table)
	out := make([]Entry, n)
	for i in 0 ..< n {
		e := table + i * ENTRY
		raw := data[e:e + 16]
		if z, ok := slice.linear_search(raw, 0); ok do raw = raw[:z]
		ref := common.latin1(raw)
		off, size := int(pe.le32(data, e + 24)), int(pe.le32(data, e + 28))
		if off + size > len(data) do common.die("%s data out of range", ref)
		out[i] = {ref, int(pe.le16(data, e + 16)), off, size}
	}
	return out
}

name :: proc(e: Entry) -> string {
	return fmt.aprintf("%s.%s", e.ref, ext(e.type))
}

read :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do common.die("%s: %v", path, err)
	return data
}

main :: proc() {
	a := os.args
	if len(a) < 3 do common.die(USAGE)
	data := read(a[2])
	table := entries(data)
	if a[1] == "list" && len(a) <= 4 {
		sub := len(a) == 4 ? a[3] : ""
		for e in table {
			if strings.contains(e.ref, sub) do fmt.printfln("%-24s % 8d", name(e), e.size)
		}
	} else if a[1] == "get" && len(a) >= 5 {
		want := make(map[string]bool)
		for w in a[4:] do want[w] = true
		for e in table {
			nm := name(e)
			if nm not_in want do continue
			path := strings.concatenate({a[3], "/", nm})
			if err := os.write_entire_file(path, data[e.off:e.off + e.size]); err != nil do common.die("%s: %v", path, err)
			delete_key(&want, nm)
		}
		if len(want) > 0 {
			left: [dynamic]string
			for w in want do append(&left, w)
			slice.sort(left[:])
			common.die("not found: %s", strings.join(left[:], " "))
		}
	} else do common.die(USAGE)
}
