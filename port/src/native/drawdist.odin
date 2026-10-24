// Draw distance (JE_DRAW), a deliberate change rather than a bit-exact
// replacement. The scene's far plane is 10000 units away, so what limits the
// view is a set of per-area distances: creatures fade out between a near and
// a far distance, animation, dangly bones, cloth, wind and shadows stop being
// updated past their LOD distances, and each grass type fades out between two
// distances. The area's values are read when it loads (0x4acf30, the grass
// types at 0x6130a0); the port multiplies them by the setting's scale there
// and again whenever the setting changes. WHY: docs/rendering.md §16
package native

import "../x86"

guest_area_lod: x86.Func
guest_grass_set: x86.Func

// The globals 0x4acf30 sets, each a distance (metres, or metres per unit of
// object size for the LOD ones).
DRAW_GLOBALS := [?]u32 {
	0x0075d08c, // creature fade start
	0x0075d090, // creature fade end, twice the area's characterfadefar
	0x0075f2cc, // animatehierarchylodfar
	0x0075f2d0, // danglybonelodfar
	0x0075f2d4, // windupdatelodfar
	0x0079e178, // shadowlodfar
	0x0079e180, // clothlodfar
}
GRASS_TYPES :: 0x0079e448 // CExoArrayList data of the grass types, count at +4
GRASS_STRIDE :: 0x6c
GRASS_FALLOFF :: 0x50 // f32 squared fade start and end
GRASS_FALLOFF_MAX :: 0x0075f2dc // f32 the largest squared fade end

draw_scale: f32 = 1 // the setting's scale

// The area's values of DRAW_GLOBALS, once an area has loaded.
@(private = "file")
draw_base: [len(DRAW_GLOBALS)]f32
@(private = "file")
draw_loaded: bool
// The scale the grass types' falloffs carry now.
@(private = "file")
grass_scale: f32 = 1

// cdecl(area name): reads the area's LOD distances into DRAW_GLOBALS.
Area_Lod_004acf30 :: proc() {
	guest_area_lod()
	for g, i in DRAW_GLOBALS {draw_base[i] = lf(g)}
	draw_loaded = true
	draw_apply()
}

// cdecl(index, params): sets grass type index from params.
Grass_Set_006130a0 :: proc() {
	i := ld(x86.cpu.esp + 4)
	guest_grass_set()
	grass_rescale(i, i + 1, grass_scale * grass_scale)
}

// Puts draw_scale in force.
draw_apply :: proc() {
	if draw_loaded {
		for g, i in DRAW_GLOBALS {st(g, transmute(u32)(draw_base[i] * draw_scale))}
	}
	r := draw_scale / grass_scale
	grass_rescale(0, ld(GRASS_TYPES + 4), r * r)
	grass_scale = draw_scale
}

// Multiplies the falloffs of grass types [lo, hi) by k.
@(private = "file")
grass_rescale :: proc(lo, hi: u32, k: f32) {
	if k == 1 {return}
	data := ld(GRASS_TYPES)
	for i in lo ..< hi {
		a := data + i * GRASS_STRIDE + GRASS_FALLOFF
		st(a, transmute(u32)(lf(a) * k))
		end := lf(a + 4) * k
		st(a + 4, transmute(u32)end)
		if end > lf(GRASS_FALLOFF_MAX) {st(GRASS_FALLOFF_MAX, transmute(u32)end)}
	}
}
