// Bakes hi-res glyph bitmaps that replace one of the game's 2-bit bitmap
// fonts, so the port needs no font file at run time. The source is either a
// TrueType/OpenType font or a Texmod glyph-cache image (a .png, e.g. the one in
// Dialogue Overhaul's JE-Fonts.tpf). Writes <game>/fonts_hd/<name>.abc (the
// original metrics, with A, B, C from the outline for a font) and
// <name>.glyphs (8-bit coverage per char at SCALE times the game's 32x32 cell).
// WHY: docs/rendering.md §4
//
// Build: odin build tools/fontbake -out:tools/fontbake/fontbake
// Usage: fontbake <game dir> <font file|cache .png> <name> [scale]   (name e.g. eurogui)
package fontbake

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import tt "vendor:stb/truetype"

ABC_HEADER :: 8 // .abc: header, then 8-byte entries for chars 1.. (entry c at 8 + (c-1)*8)
ABC_ENTRY :: 8 // u16 .sbm offset, 2 unused, u8 plane, s8 A, u8 B, s8 C (ABC widths)
GLYPH_CELL :: 32
CAP_REF :: 'H' // glyph that fixes size and baseline against the bitmap font
SCALE_DEFAULT :: 4
SCALE_MAX :: 8 // the port's RT_SCALE_MAX
GLYPHS_MAGIC :: "JEG1"
CACHE_SIDE :: 1024 // the game's glyph cache texture, 32 cells a row
// Chars of a Texmod cache image, in cache order, once per font: the cache as
// the game fills it from the main menu, eurogui first, then eurodialog.
TEXMOD_CHARS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+=`'\",.!@#$%^&*()<>:;/\\?"
TEXMOD_FONTS :: [?]string{"eurogui", "eurodialog"}

Font :: struct {
	info:  tt.fontinfo,
	scale: f32, // font units to guest pixels
	base:  i32, // baseline row in a cell
}

fatal :: proc(f: string, args: ..any) -> ! {
	fmt.eprintfln(f, ..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 4 && len(os.args) != 5 {
		fatal("usage: fontbake <game dir> <font file> <name> [scale]")
	}
	game, path, name := os.args[1], os.args[2], os.args[3]
	scale := SCALE_DEFAULT
	if len(os.args) == 5 {
		ok: bool
		scale, ok = strconv.parse_int(os.args[4])
		if !ok || scale < 1 || scale > SCALE_MAX {fatal("scale must be 1..%d", SCALE_MAX)}
	}
	abc, aerr := os.read_entire_file(fmt.tprintf("%s/fonts/%s.abc", game, name), context.allocator)
	sbm, serr := os.read_entire_file(fmt.tprintf("%s/fonts/%s.sbm", game, name), context.allocator)
	if aerr != nil || serr != nil {fatal("fontbake: need fonts/%s.abc and .sbm (%v %v)", name, aerr, serr)}
	glyphs: [dynamic]u8
	if strings.has_suffix(strings.to_lower(path), ".png") {
		glyphs = bake_texmod(path, name, i32(scale))
	} else {
		glyphs = bake_font(path, abc, sbm, i32(scale))
	}
	dir := fmt.tprintf("%s/fonts_hd", game)
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {fatal("fontbake: cannot make %s: %v", dir, err)}
	}
	write(fmt.tprintf("%s/%s.abc", dir, name), abc)
	write(fmt.tprintf("%s/%s.glyphs", dir, name), glyphs[:])
	fmt.printfln("%s: scale %d, %d bytes of glyphs", name, scale, len(glyphs))
}

// Glyphs from outlines; rewrites A, B, C in abc.
bake_font :: proc(path: string, abc, sbm: []u8, k: i32) -> [dynamic]u8 {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {fatal("fontbake: cannot read %s: %v", path, rerr)}
	f: Font
	if !tt.InitFont(&f.info, raw_data(data), tt.GetFontOffsetForIndex(raw_data(data), 0)) {
		fatal("fontbake: %s is not a font stb_truetype reads", path)
	}
	top, bottom := bitmap_ink_rows(abc, sbm, CAP_REF)
	g := tt.FindGlyphIndex(&f.info, CAP_REF)
	x0, y0, x1, y1: i32
	if g == 0 || tt.GetGlyphBox(&f.info, g, &x0, &y0, &x1, &y1) == 0 {
		fatal("fontbake: %s has no '%c'", path, CAP_REF)
	}
	f.scale = f32(bottom - top + 1) / f32(y1 - y0)
	f.base = bottom + 1
	fmt.printfln("%s: cap height %d px, baseline row %d", path, bottom - top + 1, f.base)
	return bake(&f, abc, k)
}

// Glyphs cut from a Texmod image of the whole glyph cache at a multiple of its
// size: each char's cell box-averaged down to scale k. The image was drawn over
// the original cells, so the original metrics stand.
bake_texmod :: proc(path, name: string, k: i32) -> (out: [dynamic]u8) {
	img, err := png.load_from_file(path, {.alpha_add_if_missing})
	if err != nil {fatal("fontbake: cannot load %s: %v", path, err)}
	if img.depth != 8 || img.channels != 4 || img.width != img.height || img.width % CACHE_SIDE != 0 {
		fatal("fontbake: %s is not an 8-bit RGBA square multiple of %d", path, CACHE_SIDE)
	}
	src := i32(img.width / CACHE_SIDE)
	if src % k != 0 {fatal("fontbake: image scale %d is not a multiple of %d", src, k)}
	first := -1
	for f, i in TEXMOD_FONTS {if f == name {first = i * len(TEXMOD_CHARS)}}
	if first < 0 {fatal("fontbake: a cache image holds only %v", TEXMOD_FONTS)}
	px := bytes.buffer_to_bytes(&img.pixels)
	append(&out, GLYPHS_MAGIC)
	put_u32(&out, u32(k))
	put_u32(&out, u32(len(TEXMOD_CHARS)))
	@(static) cell: [GLYPH_CELL * SCALE_MAX * GLYPH_CELL * SCALE_MAX]u8
	side := GLYPH_CELL * k
	for c, i in TEXMOD_CHARS {
		slot := i32(first + i)
		cell_box(px, i32(img.width), slot % (CACHE_SIDE / GLYPH_CELL), slot / (CACHE_SIDE / GLYPH_CELL), src / k, side, cell[:])
		put_trimmed(&out, c, cell[:side * side], side)
	}
	return
}

// Cell (cx, cy) of an RGBA image whose cells are side * f texels: alpha
// averaged over f x f boxes into cell.
cell_box :: proc(px: []u8, width, cx, cy, f, side: i32, cell: []u8) {
	x0, y0 := cx * side * f, cy * side * f
	for y in 0 ..< side {
		for x in 0 ..< side {
			sum: i32
			for dy in 0 ..< f {
				for dx in 0 ..< f {
					sum += i32(px[((y0 + y * f + dy) * width + x0 + x * f + dx) * 4 + 3])
				}
			}
			cell[y * side + x] = u8((sum + f * f / 2) / (f * f))
		}
	}
}

// Record for char c: the cell trimmed to its ink box (0x0 when blank).
put_trimmed :: proc(out: ^[dynamic]u8, c: rune, cell: []u8, side: i32) {
	x0, y0, x1, y1 := side, side, i32(0), i32(0)
	for y in 0 ..< side {
		for x in 0 ..< side {
			if cell[y * side + x] == 0 {continue}
			x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x + 1), max(y1, y + 1)
		}
	}
	if x1 == 0 {x0, y0 = 0, 0}
	put_u32(out, u32(c))
	put_u16(out, u16(x0))
	put_u16(out, u16(y0))
	put_u16(out, u16(x1 - x0))
	put_u16(out, u16(y1 - y0))
	for y in y0 ..< y1 {append(out, ..cell[y * side + x0:y * side + x1])}
}

write :: proc(path: string, data: []u8) {
	if err := os.write_entire_file(path, data); err != nil {fatal("fontbake: cannot write %s: %v", path, err)}
}

// First and last rows holding ink in the bitmap glyph for c.
bitmap_ink_rows :: proc(abc, sbm: []u8, c: rune) -> (top, bottom: i32) {
	e := abc[ABC_HEADER + (int(c) - 1) * ABC_ENTRY:]
	off, plane := int(e[0]) | int(e[1]) << 8, e[4]
	assert(off + GLYPH_CELL * GLYPH_CELL <= len(sbm))
	top, bottom = GLYPH_CELL, -1
	for y in 0 ..< i32(GLYPH_CELL) {
		for x in 0 ..< GLYPH_CELL {
			if (sbm[off + int(y) * GLYPH_CELL + x] >> (plane * 2)) & 3 == 0 {continue}
			top, bottom = min(top, y), max(bottom, y)
		}
	}
	if bottom < 0 {fatal("fontbake: bitmap '%c' is empty", c)}
	return
}

// Rewrites A, B, C in abc for every char the font has and returns the
// .glyphs file: magic, u32 scale, u32 count, then per char u32 char, i16 x,
// i16 y (ink box in the scaled cell), u16 w, u16 h, w*h coverage bytes. A char
// the bitmap font lacks keeps its entry (offset 0, plane 0: the first cell), so
// its upload still copies this font's .sbm and the baked glyph replaces it.
bake :: proc(f: ^Font, abc: []u8, k: i32) -> (out: [dynamic]u8) {
	append(&out, GLYPHS_MAGIC)
	put_u32(&out, u32(k))
	put_u32(&out, 0) // count, patched below
	n: u32
	side := GLYPH_CELL * k
	entries := (len(abc) - ABC_HEADER) / ABC_ENTRY
	for i in 0 ..< entries {
		c := rune(i + 1)
		g := tt.FindGlyphIndex(&f.info, c)
		if g == 0 {continue}
		a, b, cw := glyph_abc(f, g)
		e := abc[ABC_HEADER + i * ABC_ENTRY:]
		e[5], e[6], e[7] = u8(i8(a)), u8(b), u8(i8(cw))
		s := f.scale * f32(k)
		x0, y0, x1, y1: i32
		tt.GetGlyphBitmapBoxSubpixel(&f.info, g, s, s, 0, 0, &x0, &y0, &x1, &y1)
		w, h := max(min(x1 - x0, side), 0), max(min(y1 - y0, side), 0)
		put_u32(&out, u32(c))
		put_u16(&out, u16(i16(x0 - a * k)))
		put_u16(&out, u16(i16(f.base * k + y0)))
		put_u16(&out, u16(w))
		put_u16(&out, u16(h))
		at := len(out)
		resize(&out, at + int(w * h))
		if w > 0 && h > 0 {tt.MakeGlyphBitmapSubpixel(&f.info, &out[at], w, h, w, s, s, 0, 0, g)}
		n += 1
	}
	(^u32le)(&out[len(GLYPHS_MAGIC) + 4])^ = u32le(n)
	return
}

// ABC widths of glyph g in guest pixels: left bearing, ink width (at least 1,
// at most a cell), right bearing. The bitmap's ink starts at cell column 0.
glyph_abc :: proc(f: ^Font, g: i32) -> (a, b, c: i32) {
	adv, lsb, x0, y0, x1, y1: i32
	tt.GetGlyphHMetrics(&f.info, g, &adv, &lsb)
	tt.GetGlyphBitmapBoxSubpixel(&f.info, g, f.scale, f.scale, 0, 0, &x0, &y0, &x1, &y1)
	advance := i32(math.round(f32(adv) * f.scale))
	a, b = x1 > x0 ? x0 : 0, clamp(x1 - x0, 1, GLYPH_CELL)
	c = advance - a - b
	assert(a >= -128 && a <= 127 && c >= -128 && c <= 127, "fontbake: bearing outside s8")
	return
}

put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

put_u16 :: proc(out: ^[dynamic]u8, v: u16) {
	append(out, u8(v), u8(v >> 8))
}
