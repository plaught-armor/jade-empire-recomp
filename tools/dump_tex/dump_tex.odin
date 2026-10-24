// Dump every texture the game can load, as NAME.tpc, for upscale_tex.py.
// WHY: docs/modding.md §1
//
// Usage:
//   dump_tex GAMEDIR OUTDIR
//
// Sources, in order: TPCs (type 3017) in the BIFs chitin.key lists, then TPCs
// in data/**/*.rim not already dumped (first RIM in sorted path order wins),
// then override/*.txb written over the same names (override wins in game).
// KEY V1 layout (little endian): u32 bif count, res count, bif table offset,
// res table offset at 8; bif entries 12 bytes (u32 size, u32 name offset,
// u16 name length, u16 drives); res entries 22 bytes (char resref[16], u16
// type, u32 id = bif << 20 | index). BIFF V1: u32 resource count at 8, table
// offset at 16; entries 16 bytes (u32 id, offset, size, type).
package dump_tex

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../common"
import "../pe"
import "../rim"

USAGE :: `Usage:
  dump_tex GAMEDIR OUTDIR`

TPC :: 3017

// Bif paths and id -> resref of a chitin.key image.
key_names :: proc(key: []u8) -> (bifs: []string, names: map[u32]string) {
	nbif, nres := int(pe.le32(key, 8)), int(pe.le32(key, 12))
	off_b, off_r := int(pe.le32(key, 16)), int(pe.le32(key, 20))
	bifs = make([]string, nbif)
	for i in 0 ..< nbif {
		e := off_b + 12 * i
		noff, nlen := int(pe.le32(key, e + 4)), int(pe.le16(key, e + 8))
		s := strings.trim_right(string(key[noff:noff + nlen]), "\x00")
		bifs[i], _ = strings.replace_all(s, "\\", "/")
	}
	for i in 0 ..< nres {
		e := off_r + 22 * i
		raw := key[e:e + 16]
		if z, ok := slice.linear_search(raw, 0); ok do raw = raw[:z]
		names[pe.le32(key, e + 18)] = strings.to_lower(common.latin1(raw))
	}
	return
}

read :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do common.die("%s: %v", path, err)
	return data
}

save :: proc(out, ref: string, blob: []u8) {
	path := strings.concatenate({out, "/", ref, ".tpc"})
	if err := os.write_entire_file(path, blob); err != nil do common.die("%s: %v", path, err)
}

// Paths of the *.rim files under dir, at any depth, as glob's ** finds them.
rims :: proc(dir: string, out: ^[dynamic]string) {
	fis, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return
	for fi in fis {
		if strings.has_prefix(fi.name, ".") do continue
		path := strings.concatenate({dir, "/", fi.name})
		if fi.type == .Directory do rims(path, out)
		else if strings.has_suffix(fi.name, ".rim") do append(out, path)
	}
}

main :: proc() {
	if len(os.args) != 3 do common.die(USAGE)
	game, out := os.args[1], os.args[2]
	if err := os.make_directory_all(out); err != nil && err != .Exist do common.die("%s: %v", out, err)
	bifs, names := key_names(read(strings.concatenate({game, "/chitin.key"})))
	done: map[string]bool
	for path, bi in bifs {
		b := read(strings.concatenate({game, "/", path}))
		if len(b) < 20 || string(b[:8]) != "BIFFV1  " do common.die("%s: not a BIFF V1 file", path)
		n, table := int(pe.le32(b, 8)), int(pe.le32(b, 16))
		for j in 0 ..< n {
			e := table + 16 * j
			off, size, ty := int(pe.le32(b, e + 4)), int(pe.le32(b, e + 8)), pe.le32(b, e + 12)
			ref := names[u32(bi << 20 | j)]
			if ty == TPC && ref != "" && ref not_in done {
				save(out, ref, b[off:off + size])
				done[ref] = true
			}
		}
		delete(b)
	}
	nbif := len(done)
	paths: [dynamic]string
	rims(strings.concatenate({game, "/data"}), &paths)
	slice.sort(paths[:])
	for path in paths {
		data := rim.read(path)
		for e in rim.entries(data) {
			ref := strings.to_lower(e.ref)
			if e.type == TPC && ref not_in done {
				save(out, ref, data[e.off:e.off + e.size])
				done[ref] = true
			}
		}
		delete(data)
	}
	nrim := len(done) - nbif
	over := strings.concatenate({game, "/override"})
	fis, err := os.read_all_directory_by_path(over, context.allocator)
	if err != nil do common.die("%s: %v", over, err)
	ntxb := 0
	for fi in fis {
		if !strings.has_suffix(fi.name, ".txb") || strings.has_prefix(fi.name, ".") do continue
		ref := strings.to_lower(fi.name[:len(fi.name) - 4])
		data := read(strings.concatenate({over, "/", fi.name}))
		save(out, ref, data)
		delete(data)
		done[ref] = true
		ntxb += 1
	}
	fmt.printf("%d from BIFs, %d from RIMs, %d override, %d files\n", nbif, nrim, ntxb, len(done))
}
