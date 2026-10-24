// Hi-res fonts. The game draws text from 2-bit 32x32 bitmap glyphs (.abc
// metrics, .sbm bitmaps) cached in one 1024x1024 texture. At render scale k > 1
// the cache gets k-times storage. A font baked by tools/fontbake replaces one
// bitmap font: fonts_hd/<name>.abc gives the guest its metrics and
// fonts_hd/<name>.glyphs the pre-rendered glyphs drawn into the cache. Any
// other glyph is rebuilt from the guest's own cell: coverage resampled with a
// Gaussian, then a smoothstep around a threshold that leaves an edge about one
// output pixel wide.
// WHY: docs/rendering.md §4
package win32

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import "../x86"

FONT_HD_DIR :: "fonts_hd"
FONT_HD_MAX :: 8
FONT_CACHE_CREATE_RA :: 0x646847 // return address of the glyph cache's CreateTexture
GLYPH_LOCK_RA :: 0x644f5e // return address of LockRect in the glyph upload (0x644f00)
GLYPH_REQ_SRC :: 0x4 // glyph upload request (esi): .sbm bytes at [+0x4] + [+0x14], [+0xc] of them
GLYPH_REQ_LEN :: 0xc
GLYPH_REQ_OFF :: 0x14
GLYPH_REQ_CHAR :: 0x18 // u16
GLYPH_NODE_Y :: 0x6 // cache node (ebp): u16 cell y, u16 cell x
GLYPH_NODE_X :: 0x8
ABC_HEADER :: 8 // .abc: header, then 8-byte entries for chars 1.. (entry c at 8 + (c-1)*8)
ABC_ENTRY :: 8 // u16 .sbm offset, 2 unused, u8 plane, s8 A, u8 B, s8 C (ABC widths)
GLYPHS_MAGIC :: "JEG1" // .glyphs: magic, u32 scale, u32 count, then records
GLYPHS_RECORD :: 12 // u32 char, i16 x, i16 y, u16 w, u16 h, then w*h coverage bytes
GLYPH_CELL :: 32
GLYPH_HD_MAX :: GLYPH_CELL * RT_SCALE_MAX
GLYPH_SIGMA :: 0.55 // resampling Gaussian, in cell texels
GLYPH_RADIUS :: 2 // cell texels a tap reaches
GLYPH_TAPS :: 2 * GLYPH_RADIUS + 1
GLYPH_EDGE :: 0.4 // coverage the edge sits at
GLYPH_SOFT :: 0.6 // smoothstep half-width in coverage, divided by k

// A baked glyph: ink box in the font's scaled cell, coverage at data[off:].
Baked_Glyph :: struct {
	x, y, w, h: i32,
	off:        int,
}

Hd_Font :: struct {
	name:   string, // .abc base name, lower case
	abc:    []u8, // the bitmap font's .abc and .sbm, to tell its glyph uploads apart
	sbm:    []u8,
	data:   []u8, // the .glyphs file
	scale:  i32, // baked cell is GLYPH_CELL * scale texels
	glyphs: map[rune]Baked_Glyph,
}

Glyph_Lock :: struct {
	font: int, // hd_fonts index, -1 none
	char: rune,
	x, y: u32, // cell, in texels
}

// One output column's (or row's) taps: weights for cell texels first.. on.
Glyph_Taps :: struct {
	first: i32,
	w:     [GLYPH_TAPS]f32,
}

hd_fonts: [dynamic]Hd_Font
font_cache_obj: u32 // the glyph cache texture's COM object, 0 until created
glyph_lock: Maybe(Glyph_Lock) // the glyph upload's open lock

// Loads every baked font. Runs in the game directory before boot.
font_hd_init :: proc() {
	infos, err := os.read_all_directory_by_path(FONT_HD_DIR, context.temp_allocator)
	if err == .Not_Exist {return}
	if err != nil {x86.fatal("font_hd: cannot list %s: %v", FONT_HD_DIR, err)}
	for fi in infos {
		if !strings.has_suffix(fi.name, ".glyphs") {continue}
		if len(hd_fonts) == FONT_HD_MAX {x86.fatal("font_hd: more than %d fonts", FONT_HD_MAX)}
		font_hd_load(strings.to_lower(strings.trim_suffix(fi.name, ".glyphs")))
	}
}

font_hd_load :: proc(name: string) {
	files := [?]string {
		fmt.tprintf("%s/%s.glyphs", FONT_HD_DIR, name),
		fmt.tprintf("%s/%s.abc", FONT_HD_DIR, name),
		host_path(fmt.tprintf("fonts/%s.abc", name)),
		host_path(fmt.tprintf("fonts/%s.sbm", name)),
	}
	read: [len(files)][]u8
	for path, i in files {
		data, rerr := os.read_entire_file(path, context.allocator)
		if rerr != nil {x86.fatal("font_hd: cannot read %s: %v", path, rerr)}
		read[i] = data
	}
	delete(read[1]) // read only to fail early; CreateFileA serves it
	f := Hd_Font{name = name, data = read[0], abc = read[2], sbm = read[3]}
	glyphs_parse(&f)
	append(&hd_fonts, f)
	fmt.eprintf("font_hd: %s, %d baked glyphs at %dx\n", name, len(f.glyphs), f.scale)
}

// Indexes a .glyphs file (format in tools/fontbake).
glyphs_parse :: proc(f: ^Hd_Font) {
	d := f.data
	head := len(GLYPHS_MAGIC) + 8
	if len(d) < head || string(d[:len(GLYPHS_MAGIC)]) != GLYPHS_MAGIC {
		x86.fatal("font_hd: %s.glyphs is not a baked font", f.name)
	}
	f.scale = i32((^u32le)(&d[4])^)
	count := int((^u32le)(&d[8])^)
	if f.scale < 1 || f.scale > RT_SCALE_MAX {x86.fatal("font_hd: %s.glyphs scale %d", f.name, f.scale)}
	at := head
	for _ in 0 ..< count {
		if at + GLYPHS_RECORD > len(d) {x86.fatal("font_hd: %s.glyphs truncated", f.name)}
		c := rune((^u32le)(&d[at])^)
		g := Baked_Glyph {
			x   = i32((^i16le)(&d[at + 4])^),
			y   = i32((^i16le)(&d[at + 6])^),
			w   = i32((^u16le)(&d[at + 8])^),
			h   = i32((^u16le)(&d[at + 10])^),
			off = at + GLYPHS_RECORD,
		}
		at = g.off + int(g.w * g.h)
		if at > len(d) {x86.fatal("font_hd: %s.glyphs truncated", f.name)}
		f.glyphs[c] = g
	}
	if at != len(d) {x86.fatal("font_hd: %s.glyphs has %d trailing bytes", f.name, len(d) - at)}
}

// Host path to open for guest file path: a .abc a baked font replaces
// becomes the baked one; any other path is returned as is.
font_hd_open :: proc(path: string) -> string {
	if !strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".abc") {return path}
	base := path[max(strings.last_index_any(path, `/\`), 0):]
	base = strings.trim_left(base, `/\`)
	for &f in hd_fonts {
		if strings.equal_fold(base[:len(base) - 4], f.name) {
			return fmt.tprintf("%s/%s.abc", FONT_HD_DIR, f.name)
		}
	}
	return path
}

// Called on each CreateTexture with its return address: gives the glyph
// cache render-scale storage when rendering above 1x or a font is baked.
font_hd_texture :: proc(ra, hr, out: u32) {
	if hr != D3D_OK {return}
	obj := x86.rd32(out)
	if ra != FONT_CACHE_CREATE_RA || (rt_scale <= 1 && len(hd_fonts) == 0) {
		if obj == font_cache_obj {font_cache_obj = 0} // a recycled object
		return
	}
	r := res_of(obj)
	assert(r.levels == 1 && r.format == D3DFMT_A8R8G8B8, "font_hd: unexpected glyph cache")
	k := max(rt_scale, 1)
	gl.DeleteTextures(1, &r.gl)
	r.gl = tex_gl_create(gl.TEXTURE_2D, fmt_must(r.format), r.w * k, r.h * k, 1)
	r.scale = k
	font_cache_obj = obj
}

// Called on each texture LockRect: notes which cell the glyph upload writes.
font_hd_lock :: proc(r: ^Res, ra: u32) {
	if r.obj != font_cache_obj || ra != GLYPH_LOCK_RA {return}
	req, node := x86.cpu.esi, x86.cpu.ebp
	c := rune(x86.rd16(req + GLYPH_REQ_CHAR))
	glyph_lock = Glyph_Lock {
		font = glyph_source_font(req, c),
		char = c,
		x    = u32(x86.rd16(node + GLYPH_NODE_X)),
		y    = u32(x86.rd16(node + GLYPH_NODE_Y)),
	}
}

// Called on each texture unlock; true when it uploaded the glyph cell itself.
font_hd_unlock :: proc(r: ^Res) -> bool {
	gk, ok := glyph_lock.?
	if r.obj != font_cache_obj || !ok {return false}
	glyph_lock = nil
	assert(gk.x + GLYPH_CELL <= r.w && gk.y + GLYPH_CELL <= r.h)
	if gk.font >= 0 {
		f := &hd_fonts[gk.font]
		if g, baked := f.glyphs[gk.char]; baked {
			glyph_cell_baked(r, f, g, gk)
			return true
		}
	}
	if res_scale(r) == 1 {
		glyph_cell_guest(r, gk)
	} else {
		glyph_cell_upscaled(r, gk)
	}
	return true
}

// The guest's cell uploaded as is (render scale 1). Only the cell: a whole-
// texture upload would overwrite baked glyphs in other cells.
glyph_cell_guest :: proc(r: ^Res, gk: Glyph_Lock) {
	fi := fmt_must(r.format)
	pitch := level_pitch(fi, r.w)
	cell: [GLYPH_CELL * GLYPH_CELL]u32
	for y in 0 ..< u32(GLYPH_CELL) {
		src := (^[GLYPH_CELL]u32)(x86.ptr(r.shadow + (gk.y + y) * pitch + gk.x * 4))
		copy(cell[y * GLYPH_CELL:][:GLYPH_CELL], src[:])
	}
	gl.TextureSubImage2D(r.gl, 0, i32(gk.x), i32(gk.y), GLYPH_CELL, GLYPH_CELL, fi.format, fi.type, &cell[0])
}

// hd_fonts index of the bitmap font whose cell for c the upload request req
// copies, -1 when none. The request names its font only by a key internal to
// the glyph cache, so the cell bytes are matched against each .sbm.
glyph_source_font :: proc(req: u32, c: rune) -> int {
	n := int(x86.rd32(req + GLYPH_REQ_LEN))
	src := x86.rd32(req + GLYPH_REQ_SRC) + x86.rd32(req + GLYPH_REQ_OFF)
	assert(n == GLYPH_CELL * GLYPH_CELL, "font_hd: unexpected glyph upload size")
	for &f, i in hd_fonts {
		e := ABC_HEADER + (int(c) - 1) * ABC_ENTRY
		if c < 1 || e + ABC_ENTRY > len(f.abc) {continue}
		off := int(f.abc[e]) | int(f.abc[e + 1]) << 8
		if off + n > len(f.sbm) {continue}
		if mem.compare_ptrs(x86.ptr(src), &f.sbm[off], n) == 0 {return i}
	}
	return -1
}

// Baked glyph g drawn into its cell: coverage to all four channels, as the
// guest writes its 2-bit levels; resampled linearly when the font was baked
// at another scale than the cache's.
glyph_cell_baked :: proc(r: ^Res, f: ^Hd_Font, g: Baked_Glyph, gk: Glyph_Lock) {
	@(static) cell: [GLYPH_HD_MAX * GLYPH_HD_MAX]u32
	side := GLYPH_CELL * f.scale
	for &p in cell[:side * side] {p = 0}
	for y in max(0, -g.y) ..< min(g.h, side - g.y) {
		for x in max(0, -g.x) ..< min(g.w, side - g.x) {
			v := u32(f.data[g.off + int(y * g.w + x)])
			cell[(g.y + y) * side + g.x + x] = v * 0x01010101
		}
	}
	k := i32(res_scale(r))
	fi := fmt_must(r.format)
	x, y := i32(gk.x) * k, i32(gk.y) * k
	if f.scale == k {
		gl.TextureSubImage2D(r.gl, 0, x, y, side, side, fi.format, fi.type, &cell[0])
		return
	}
	tmp := tex_gl_create(gl.TEXTURE_2D, fi, u32(side), u32(side), 1)
	gl.TextureSubImage2D(tmp, 0, 0, 0, side, side, fi.format, fi.type, &cell[0])
	gl_blit({tmp, 0, -1}, {r.gl, 0, -1}, {0, 0, side, side}, {x, y, x + GLYPH_CELL * k, y + GLYPH_CELL * k}, r.format, true)
	gl.DeleteTextures(1, &tmp)
}

// Taps for output texel o of k per cell texel: a Gaussian centred on o's
// centre in cell space, normalized over the texels inside the cell.
glyph_taps :: proc(o, k: i32) -> (t: Glyph_Taps) {
	c := (f32(o) + 0.5) / f32(k) - 0.5
	t.first = i32(math.ceil(c - GLYPH_RADIUS))
	sum: f32
	for i in 0 ..< i32(GLYPH_TAPS) {
		j := t.first + i
		d := c - f32(j)
		if j < 0 || j >= GLYPH_CELL || abs(d) > GLYPH_RADIUS {continue}
		t.w[i] = math.exp(-d * d / (2 * GLYPH_SIGMA * GLYPH_SIGMA))
		sum += t.w[i]
	}
	assert(sum > 0)
	for &w in t.w {w /= sum}
	return
}

// The guest's cell from the shadow as coverage 0..1 (the alpha byte of
// texels the guest writes as plane value * 0x55 in all four bytes).
glyph_cell_coverage :: proc(r: ^Res, gk: Glyph_Lock, cov: ^[GLYPH_CELL * GLYPH_CELL]f32) {
	pitch := level_pitch(fmt_must(r.format), r.w)
	for y in 0 ..< u32(GLYPH_CELL) {
		src := (^[GLYPH_CELL]u32)(x86.ptr(r.shadow + (gk.y + y) * pitch + gk.x * 4))
		for x in 0 ..< u32(GLYPH_CELL) {cov[y * GLYPH_CELL + x] = f32(src[x] >> 24) / 255}
	}
}

// The guest's cell rebuilt at render scale into the scaled cache: separable
// Gaussian resample, then smoothstep about GLYPH_EDGE.
glyph_cell_upscaled :: proc(r: ^Res, gk: Glyph_Lock) {
	k := i32(res_scale(r))
	side := GLYPH_CELL * k
	assert(side <= GLYPH_HD_MAX)
	@(static) cov: [GLYPH_CELL * GLYPH_CELL]f32
	@(static) taps: [GLYPH_HD_MAX]Glyph_Taps
	@(static) rows: [GLYPH_CELL * GLYPH_HD_MAX]f32 // resampled across, cell rows tall
	@(static) cell: [GLYPH_HD_MAX * GLYPH_HD_MAX]u32
	glyph_cell_coverage(r, gk, &cov)
	for o in 0 ..< side {taps[o] = glyph_taps(o, k)}
	for y in 0 ..< i32(GLYPH_CELL) {
		for ox in 0 ..< side {
			t, v := taps[ox], f32(0)
			for w, i in t.w {if w > 0 {v += w * cov[y * GLYPH_CELL + t.first + i32(i)]}}
			rows[y * side + ox] = v
		}
	}
	soft := f32(GLYPH_SOFT) / f32(k)
	for oy in 0 ..< side {
		t := taps[oy]
		for ox in 0 ..< side {
			v: f32
			for w, i in t.w {if w > 0 {v += w * rows[(t.first + i32(i)) * side + ox]}}
			a := math.smoothstep(f32(GLYPH_EDGE) - soft, f32(GLYPH_EDGE) + soft, v)
			cell[oy * side + ox] = u32(a * 255 + 0.5) * 0x01010101
		}
	}
	fi := fmt_must(r.format)
	gl.TextureSubImage2D(r.gl, 0, i32(gk.x) * k, i32(gk.y) * k, side, side, fi.format, fi.type, &cell[0])
}
