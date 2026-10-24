// HD textures (setting HDTEX, on when textures_hd/ exists). textures_hd/ holds
// .txb files, x4 upscales of the game's textures (tools/upscale_tex.py), and
// is laid over override/: its files are listed as override entries and
// opened in place of an override file of the same name, so the engine loads
// them as it loads the Special Edition's own override textures. The engine
// indexes override/ once at startup, so the switch applies after a restart.
// WHY: docs/modding.md §1
package win32

import "core:fmt"
import "core:os"
import "core:strings"

TEX_HD_DIR :: "textures_hd"
OVERRIDE_HOST :: "./override" // override/ as host_path resolves it

tex_hd_req: bool // the HD Textures setting, put in force before tex_hd_init (native/settings.odin)
tex_hd_on: bool
tex_hd_names: map[string]string // lower-case name -> name in TEX_HD_DIR

// Lists textures_hd/ once; before boot, in the game directory.
tex_hd_init :: proc() {
	if !tex_hd_req {return}
	infos, err := os.read_all_directory_by_path(TEX_HD_DIR, context.temp_allocator)
	if err != nil {return}
	for fi in infos {
		if fi.type == .Directory {continue}
		name := strings.clone(fi.name)
		tex_hd_names[strings.to_lower(name)] = name
	}
	tex_hd_on = len(tex_hd_names) > 0
	if tex_hd_on {fmt.eprintfln("textures_hd: %d textures", len(tex_hd_names))}
}

// Host path to open for host path p: an override file textures_hd/ replaces
// becomes the textures_hd one; any other path is returned as is.
tex_hd_open :: proc(p: string) -> string {
	if !tex_hd_on {return p}
	k := strings.last_index_byte(p, '/')
	if k < 0 || !strings.equal_fold(p[:k], OVERRIDE_HOST) {return p}
	name, ok := tex_hd_names[strings.to_lower(p[k + 1:], context.temp_allocator)]
	return ok ? strings.concatenate({TEX_HD_DIR, "/", name}, context.temp_allocator) : p
}

// Adds to a listing of host directory dir the textures_hd/ names matching
// pat that dir does not hold already, when dir is override/.
tex_hd_list :: proc(dir, pat: string, names: ^[dynamic]string) {
	if !tex_hd_on || !strings.equal_fold(dir, OVERRIDE_HOST) {return}
	l := dir_listing(dir)
	for low, name in tex_hd_names {
		if l != nil && low in l.names {continue}
		if wild_match(pat, name) {append(names, strings.clone(name))}
	}
}
