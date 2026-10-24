// Generated resources: files the port writes itself (the online partner's
// creature templates, native/coop_hero.odin), laid over override/ as
// textures_hd/ is. A name is listed as an override entry and an open of it
// gets an unlinked temporary file holding the bytes, so the engine loads it
// as any override file. The engine indexes override/ once at startup, so
// every name is set before boot.
// WHY: docs/modding.md §1
package win32

import "core:os"
import "core:strings"
import "../x86"

res_gen_files: map[string][]u8 // lower-case name -> contents

// Sets generated file name to data, which is kept; before boot.
res_gen_set :: proc(name: string, data: []u8) {
	res_gen_files[strings.to_lower(name)] = data
}

// The generated contents for host path p, if p names one in override/.
res_gen_get :: proc(p: string) -> ([]u8, bool) {
	if len(res_gen_files) == 0 {return nil, false}
	k := strings.last_index_byte(p, '/')
	if k < 0 || !strings.equal_fold(p[:k], OVERRIDE_HOST) {return nil, false}
	data, ok := res_gen_files[strings.to_lower(p[k + 1:], context.temp_allocator)]
	return data, ok
}

// The file for a guest open of host path p, or nil to open p itself.
res_gen_open :: proc(p: string) -> ^os.File {
	data, ok := res_gen_get(p)
	if !ok {return nil}
	f, err := os.create_temp_file("", "je-gen-*")
	if err != nil {x86.fatal("res_gen: temp file: %v", err)}
	_ = os.remove(os.name(f))
	if _, werr := os.write(f, data); werr != nil {x86.fatal("res_gen: write: %v", werr)}
	return f
}

// Adds to a listing of host directory dir the generated names matching pat
// that dir does not hold already, when dir is override/.
res_gen_list :: proc(dir, pat: string, names: ^[dynamic]string) {
	if len(res_gen_files) == 0 || !strings.equal_fold(dir, OVERRIDE_HOST) {return}
	l := dir_listing(dir)
	for low in res_gen_files {
		if l != nil && low in l.names {continue}
		if wild_match(pat, low) {append(names, strings.clone(low))}
	}
}
