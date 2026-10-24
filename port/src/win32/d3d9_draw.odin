// Draw calls: translate the device state (d3d9_state.odin) and bindings
// (d3d9_frame.odin) into GL state, then issue the draw. One VAO and one
// program pipeline serve every draw; vertex formats are re-specified when
// the (declaration, vertex shader) pair changes.
//
// Facing: under UPPER_LEFT clip control GL winding matches D3D's on-screen
// winding (observed: a D3D counterclockwise quad drawn with CULL_CW is
// culled under FrontFace(CCW)). FrontFace(CW) makes GL front = D3D
// clockwise: CULL_CW culls GL front faces, CULL_CCW back faces, and the
// two-sided stencil CCW ops apply to GL back faces.
package win32

import "core:fmt"
import "core:slice"
import gl "vendor:OpenGL"
import "../x86"

UP_SIZE :: 32 << 20 // ring for DrawPrimitiveUP data, bytes per buffer

Vs_Consts :: struct {
	f: [VS_F_MAX][4]f32,
	i: [INT_MAX][4]i32,
	b: [BOOL_MAX][4]u32,
}

Ps_Consts :: struct {
	f: [PS_F_MAX][4]f32,
	i: [INT_MAX][4]i32,
	b: [BOOL_MAX][4]u32,
}

// std140 mirror of the GLSL MISC block (d3d9_glsl.odin).
Misc :: struct {
	pos_fix:   [4]f32,
	fog_color: [4]f32,
	fog_param: [4]f32,
	mode:      [4]i32,
	tf:        [4]f32,
	sc:        [TSS_STAGES][4]f32,
	bump:      [TSS_STAGES][4]f32,
	bump_l:    [TSS_STAGES][4]f32,
	vp:        [4]f32,
	vp_z:      [4]f32,
	soft:      [4]f32,
}

Draw_GL :: struct {
	vao, pipe:     u32,
	misc_ubo:      u32, // MISC, binding 2
	ffvs_ubo:      u32, // FFVS, binding 3 (d3d9_ffvs.odin)
	const_ring:    u32, // packed constant blocks VSC (binding 0) and PSC (1), CONST_RING bytes
	const_off:     u32, // ring bytes used
	const_align:   u32, // UNIFORM_BUFFER_OFFSET_ALIGNMENT
	const_lay:     [2][2]u32, // per block: shader id + 1 and prefix length of the last pushed
	up_vb, up_ib:  u32,
	up_vb_off:     u32,
	up_ib_off:     u32,
	samplers:      [16]u32,
	samp_applied:  [16][SS_MAX]u32,
	samp_valid:    [16]bool,
	attr_key:      [2]u32, // (decl id + 1, vs id + 1) the VAO formats are for
	attr_on:       u32, // enabled attribute locations
	raster:        Raster_GL,
}

dg: Draw_GL

// Constant banks (vertex, pixel) set since the last draw. A draw packs the
// registers its shader reads into a fresh range of the constant ring: a write
// into a buffer range the GPU may still read makes the driver stage a copy
// (measured), a write past every range used since the last invalidation does
// not. WHY: docs/rendering.md §7
consts_dirty: [2]bool

CONST_RING :: 4 << 20

draw_init :: proc() {
	gl.GetFloatv(gl.MAX_TEXTURE_MAX_ANISOTROPY, &aniso_max)
	gl.CreateVertexArrays(1, &dg.vao)
	gl.BindVertexArray(dg.vao)
	gl.CreateProgramPipelines(1, &dg.pipe)
	gl.BindProgramPipeline(dg.pipe)
	gl.CreateBuffers(1, &dg.misc_ubo)
	gl.CreateBuffers(1, &dg.ffvs_ubo)
	gl.NamedBufferStorage(dg.misc_ubo, size_of(Misc), nil, gl.DYNAMIC_STORAGE_BIT)
	gl.NamedBufferStorage(dg.ffvs_ubo, size_of(Ffvs), nil, gl.DYNAMIC_STORAGE_BIT)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 2, dg.misc_ubo)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 3, dg.ffvs_ubo)
	gl.CreateBuffers(1, &dg.const_ring)
	gl.NamedBufferData(dg.const_ring, CONST_RING, nil, gl.STREAM_DRAW)
	a: i32
	gl.GetIntegerv(gl.UNIFORM_BUFFER_OFFSET_ALIGNMENT, &a)
	dg.const_align = u32(max(a, 16))
	gl.CreateBuffers(1, &dg.up_vb)
	gl.CreateBuffers(1, &dg.up_ib)
	gl.NamedBufferData(dg.up_vb, UP_SIZE, nil, gl.STREAM_DRAW)
	gl.NamedBufferData(dg.up_ib, UP_SIZE, nil, gl.STREAM_DRAW)
	gl.CreateSamplers(16, &dg.samplers[0])
	for i in 0 ..< u32(16) {gl.BindSampler(i, dg.samplers[i])}
	gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)
	gl.Enable(gl.PROGRAM_POINT_SIZE)
	gl.FrontFace(gl.CW)
	consts_dirty = {true, true}
}

gl_cmp :: proc(v: u32) -> u32 {return v >= 1 && v <= 8 ? gl.NEVER + v - 1 : gl.ALWAYS}

BLEND_GL := [16]u32 {
	gl.ZERO, gl.ZERO, gl.ONE, gl.SRC_COLOR, gl.ONE_MINUS_SRC_COLOR, gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA,
	gl.DST_ALPHA, gl.ONE_MINUS_DST_ALPHA, gl.DST_COLOR, gl.ONE_MINUS_DST_COLOR, gl.SRC_ALPHA_SATURATE,
	gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.CONSTANT_COLOR, gl.ONE_MINUS_CONSTANT_COLOR,
}
BLENDOP_GL := [6]u32{gl.FUNC_ADD, gl.FUNC_ADD, gl.FUNC_SUBTRACT, gl.FUNC_REVERSE_SUBTRACT, gl.MIN, gl.MAX}
STENCILOP_GL := [9]u32{gl.KEEP, gl.KEEP, gl.ZERO, gl.REPLACE, gl.INCR, gl.DECR, gl.INVERT, gl.INCR_WRAP, gl.DECR_WRAP}

// D3DBLEND pair -> GL factors; BOTHSRCALPHA/BOTHINVSRCALPHA set both.
blend_pair :: proc(src, dst: u32) -> (u32, u32) {
	switch src {
	case 12: return gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA
	case 13: return gl.ONE_MINUS_SRC_ALPHA, gl.SRC_ALPHA
	}
	return BLEND_GL[src & 15], BLEND_GL[dst & 15]
}

// GL state as apply_raster last set it, and the MISC block it last
// uploaded. A draw sets only what differs: each GL call is marshalled on the
// main thread, and most draws change little of it. Code that sets any of it
// directly calls raster_lost, and the next draw sets it all again.
Raster_GL :: struct {
	valid:        bool,
	cull:         u32, // the face culled, 0 when off
	poly:         u32,
	scissor_on:   bool,
	scissor:      [4]i32,
	viewport:     [4]i32,
	depth_range:  [2]f32,
	blend_on:     bool,
	blend_func:   [4]u32,
	blend_eq:     [2]u32,
	blend_color:  [4]f32,
	color_mask:   [RT_MAX]u32,
	depth_on:     bool,
	depth_func:   u32,
	depth_mask:   bool,
	stencil_on:   bool,
	stencil:      [2][6]u32, // front, back: func, ref, mask, fail, zfail, pass
	stencil_mask: u32,
	offset_on:    bool,
	offset:       [2]f32,
	misc:         Misc,
}

raster_lost :: proc() {dg.raster.valid = false}

gl_cap :: proc(cap: u32, on: bool) {
	if on {gl.Enable(cap)} else {gl.Disable(cap)}
}

apply_blend :: proc() {
	rs := &ds.rs
	c := &dg.raster
	on := rs[27] != 0
	if !c.valid || on != c.blend_on {gl_cap(gl.BLEND, on)}
	c.blend_on = on
	if on {
		s, d := blend_pair(rs[19], rs[20])
		sa, da, opa := s, d, rs[171]
		if rs[206] != 0 {
			sa, da = blend_pair(rs[207], rs[208])
			opa = rs[209]
		}
		f := [4]u32{s, d, sa, da}
		if !c.valid || f != c.blend_func {gl.BlendFuncSeparate(s, d, sa, da)}
		eq := [2]u32{BLENDOP_GL[min(rs[171], 5)], BLENDOP_GL[min(opa, 5)]}
		if !c.valid || eq != c.blend_eq {gl.BlendEquationSeparate(eq[0], eq[1])}
		col := argb_vec(rs[193])
		if !c.valid || col != c.blend_color {gl.BlendColor(col[0], col[1], col[2], col[3])}
		c.blend_func, c.blend_eq, c.blend_color = f, eq, col
	}
	for i in 0 ..< u32(RT_MAX) {
		m := (i == 0 ? rs[168] : rs[189 + i]) & 15
		if !c.valid || m != c.color_mask[i] {gl.ColorMaski(i, m & 1 != 0, m & 2 != 0, m & 4 != 0, m & 8 != 0)}
		c.color_mask[i] = m
	}
}

apply_depth_stencil :: proc() {
	rs := &ds.rs
	c := &dg.raster
	on := rs[7] != 0
	if !c.valid || on != c.depth_on {gl_cap(gl.DEPTH_TEST, on)}
	c.depth_on = on
	if on {
		f := gl_cmp(rs[23])
		if !c.valid || f != c.depth_func {gl.DepthFunc(f)}
		c.depth_func = f
	}
	zw := rs[14] != 0
	if !c.valid || zw != c.depth_mask {gl.DepthMask(zw)}
	c.depth_mask = zw
	on = rs[52] != 0
	if !c.valid || on != c.stencil_on {gl_cap(gl.STENCIL_TEST, on)}
	c.stencil_on = on
	if on {
		ref, mask := rs[57], rs[58]
		// D3D counterclockwise faces are GL back faces (see the file comment)
		back := rs[185] != 0 ? [4]u32{rs[186], rs[187], rs[188], rs[189]} : [4]u32{rs[53], rs[54], rs[55], rs[56]}
		st := [2][6]u32 {
			{gl_cmp(rs[56]), ref, mask, STENCILOP_GL[min(rs[53], 8)], STENCILOP_GL[min(rs[54], 8)], STENCILOP_GL[min(rs[55], 8)]},
			{gl_cmp(back[3]), ref, mask, STENCILOP_GL[min(back[0], 8)], STENCILOP_GL[min(back[1], 8)], STENCILOP_GL[min(back[2], 8)]},
		}
		FACE := [2]u32{gl.FRONT, gl.BACK}
		for s, i in st {
			if c.valid && s == c.stencil[i] {continue}
			gl.StencilFuncSeparate(FACE[i], s[0], i32(s[1]), s[2])
			gl.StencilOpSeparate(FACE[i], s[3], s[4], s[5])
		}
		if !c.valid || rs[59] != c.stencil_mask {gl.StencilMask(rs[59])}
		c.stencil, c.stencil_mask = st, rs[59]
	}
	bias, slope := transmute(f32)rs[195], transmute(f32)rs[175]
	on = bias != 0 || slope != 0
	if !c.valid || on != c.offset_on {gl_cap(gl.POLYGON_OFFSET_FILL, on)}
	c.offset_on = on
	if on {
		// D3D bias is in depth units; GL units are the format's resolution
		scale: f32 = bind.depth != 0 && res_of(bind.depth).format == D3DFMT_D16 ? 65535 : 16777215
		o := [2]f32{slope, bias * scale}
		if !c.valid || o != c.offset {gl.PolygonOffset(o[0], o[1])}
		c.offset = o
	}
}

apply_raster :: proc() {
	rs := &ds.rs
	c := &dg.raster
	cull: u32 = rs[22] == 2 ? gl.FRONT : rs[22] == 3 ? gl.BACK : 0
	if !c.valid || cull != c.cull {
		gl_cap(gl.CULL_FACE, cull != 0)
		if cull != 0 {gl.CullFace(cull)}
	}
	c.cull = cull
	poly: u32 = rs[8] == 1 ? gl.POINT : rs[8] == 2 ? gl.LINE : gl.FILL
	if !c.valid || poly != c.poly {gl.PolygonMode(gl.FRONT_AND_BACK, poly)}
	c.poly = poly
	// D3D pixels to GL pixels; the uniforms below stay in D3D pixels.
	k := fb_scale()
	on := rs[174] != 0
	if !c.valid || on != c.scissor_on {gl_cap(gl.SCISSOR_TEST, on)}
	c.scissor_on = on
	if on {
		s := ds.scissor
		r := [4]i32{s[0] * k, s[1] * k, max(s[2] - s[0], 0) * k, max(s[3] - s[1], 0) * k}
		if !c.valid || r != c.scissor {gl.Scissor(r[0], r[1], r[2], r[3])}
		c.scissor = r
	}
	vp := ds.viewport
	v := [4]i32{i32(vp.x) * k, i32(vp.y) * k, i32(vp.w) * k, i32(vp.h) * k}
	if !c.valid || v != c.viewport {gl.Viewport(v[0], v[1], v[2], v[3])}
	c.viewport = v
	z := [2]f32{vp.min_z, vp.max_z}
	if !c.valid || z != c.depth_range {gl.DepthRangef(z[0], z[1])}
	c.depth_range = z
	apply_blend()
	apply_depth_stencil()

	m: Misc
	// Half a host pixel, not half a D3D pixel. WHY: docs/rendering.md §1
	m.pos_fix = {1 / (f32(max(vp.w, 1)) * f32(k)), -1 / (f32(max(vp.h, 1)) * f32(k)), 0, 0}
	m.vp = {f32(vp.x), f32(vp.y), 2 / f32(max(vp.w, 1)), 2 / f32(max(vp.h, 1))}
	zr := vp.max_z - vp.min_z
	m.vp_z = {vp.min_z, abs(zr) > 1e-6 ? 1 / zr : 0, f32(k), 0} // z: point size scale
	m.fog_color = argb_vec(rs[34])
	// Table fog runs on eye w, not z, under a W-friendly projection.
	// WHY: docs/hle.md
	proj := &ds.xf[XF_PROJECTION]
	wfog: f32 = proj[2][3] != 0 && proj[3][3] == 0 ? 1 : 0
	m.fog_param = {transmute(f32)rs[36], transmute(f32)rs[37], transmute(f32)rs[38], wfog}
	if rs[28] != 0 {
		// FOGTABLEMODE NONE uses the vertex fog factor; EXP 1, EXP2 2, LINEAR 3
		TABLE := [4]i32{1, 3, 4, 2}
		m.mode.x = TABLE[min(rs[35], 3)]
	}
	m.mode.y = rs[15] != 0 ? i32(rs[25]) : 8
	m.mode.z = i32(rs[24] & 0xff)
	// GREATER / GREATEREQUAL tests on the MSAA twins become alpha to coverage.
	// WHY: docs/rendering.md §8
	if ms_bound && (m.mode.y == 5 || m.mode.y == 7) {m.mode.w = ms_samples}
	m.tf = argb_vec(rs[60])
	m.soft = soft.param
	for &t, s in ds.tss {
		m.sc[s] = argb_vec(t[32])
		m.bump[s] = {transmute(f32)t[7], transmute(f32)t[8], transmute(f32)t[9], transmute(f32)t[10]}
		m.bump_l[s] = {transmute(f32)t[22], transmute(f32)t[23], 0, 0}
	}
	// Compared as bytes: a float compare would miss -0 and repeat NaN.
	MISC_BYTES :: [size_of(Misc)]u8
	if !c.valid || transmute(MISC_BYTES)m != transmute(MISC_BYTES)c.misc {
		gl.NamedBufferSubData(dg.misc_ubo, 0, size_of(Misc), &m)
		c.misc = m
	}
	c.valid = true
}

// Minimum anisotropy for linear mipmapped sampling (JE_ANISO; 1 = as the
// game sets it) and the driver limit, read in draw_init.
aniso_force: u32 = 16
aniso_max: f32 = 1

sampler_apply :: proc(s: u32) {
	ss := &ds.ss[s]
	smp := dg.samplers[s]
	ADDR := [6]i32{gl.REPEAT, gl.REPEAT, gl.MIRRORED_REPEAT, gl.CLAMP_TO_EDGE, gl.CLAMP_TO_BORDER, gl.MIRROR_CLAMP_TO_EDGE}
	WRAP := [3]u32{gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R}
	for p, i in WRAP {
		gl.SamplerParameteri(smp, p, ADDR[min(ss[1 + i], 5)])
	}
	bc := argb_vec(ss[4])
	gl.SamplerParameterfv(smp, gl.TEXTURE_BORDER_COLOR, &bc[0])
	mag, mn, mip := ss[5], ss[6], ss[7]
	gl.SamplerParameteri(smp, gl.TEXTURE_MAG_FILTER, mag <= 1 ? gl.NEAREST : gl.LINEAR)
	lin := mn >= 2
	mf: i32
	switch mip {
	case 0: mf = lin ? gl.LINEAR : gl.NEAREST
	case 1: mf = lin ? gl.LINEAR_MIPMAP_NEAREST : gl.NEAREST_MIPMAP_NEAREST
	case: mf = lin ? gl.LINEAR_MIPMAP_LINEAR : gl.NEAREST_MIPMAP_LINEAR
	}
	gl.SamplerParameteri(smp, gl.TEXTURE_MIN_FILTER, mf)
	gl.SamplerParameterf(smp, gl.TEXTURE_LOD_BIAS, transmute(f32)ss[8])
	gl.SamplerParameterf(smp, gl.TEXTURE_MIN_LOD, f32(ss[9]))
	aniso: f32 = mn == 3 || mag == 3 ? f32(clamp(ss[10], 1, 16)) : 1
	if lin && mip != 0 {aniso = max(aniso, f32(aniso_force))} // WHY: docs/rendering.md §2
	aniso = min(aniso, aniso_max)
	gl.SamplerParameterf(smp, gl.TEXTURE_MAX_ANISOTROPY, aniso)
	dg.samp_applied[s] = ss^
	dg.samp_valid[s] = true
}

// Binds textures and samplers 0..15; returns the ps_1_x variant key.
apply_textures :: proc() -> (key: u32) {
	names: [16]u32
	for s in 0 ..< u32(16) {
		if obj := bind.tex[s]; obj != 0 {
			r := res_of(obj)
			names[s] = r.gl
			if r.kind == .Cube && s < PS1_STAGES {key |= u32(Samp_Type.CUBE) << (2 * s)}
		}
		if !dg.samp_valid[s] || dg.samp_applied[s] != ds.ss[s] {sampler_apply(s)}
	}
	gl.BindTextures(0, 16, &names[0])
	for s in 0 ..< u32(PS1_STAGES) {
		// D3DTSS_TEXTURETRANSFORMFLAGS: D3DTTFF_PROJECTED divides by the last coordinate
		f := ds.tss[s][24]
		if f & 0x100 != 0 {key |= (f & 0xff == 4 ? 2 : 1) << (8 + 2 * s)}
	}
	return
}

// Variant key bits of shader s's constant block: 0, or with relative reads
// the prefix length n << 16 (glsl const_block), n covering every register
// written and every one read by static index, in steps of 16 so new writes
// rarely add a variant.
const_key :: proc(s: ^Shader) -> u32 {
	if !s.crel {return 0}
	u := int(s.prog.ps)
	top := len(s.cregs) > 0 ? u32(s.cregs[len(s.cregs) - 1]) + 1 : 1
	n := min((max(const_hw[u], top) + 15) &~ 15, u == 0 ? VS_F_MAX : PS_F_MAX)
	return n << 16
}

// The registers shader s reads from bank f under variant key, packed as its
// block declares them: its cregs gathered into buf, or the prefix the key
// names, in place.
const_pack :: proc(s: ^Shader, key: u32, f: [][4]f32, buf: ^[VS_F_MAX][4]f32) -> [][4]f32 {
	if s.crel {return f[:key >> 16]}
	for r, i in s.cregs {buf[i] = f[r]}
	return buf[:len(s.cregs)]
}

// Where register r sits in shader s's packed block, ok false if it reads none.
const_slot :: proc(s: ^Shader, r: int) -> (int, bool) {
	if s.crel {return r, true}
	return slice.binary_search(s.cregs, u8(r))
}

// Starts the ring over; the ranges bound so far are gone, so every block is
// pushed again.
const_wrap :: proc() {
	gl.InvalidateBufferData(dg.const_ring)
	dg.const_off = 0
	dg.const_lay = {}
}

const_aligned :: proc() -> u32 {return (dg.const_off + dg.const_align - 1) &~ (dg.const_align - 1)}

// Writes block u (0 VSC, 1 PSC) into the next ring range and binds it; the
// caller has made room.
const_write :: proc(u: int, c: [][4]f32) {
	if len(c) == 0 {return}
	o, sz := const_aligned(), u32(len(c) * 16)
	gl.NamedBufferSubData(dg.const_ring, int(o), int(sz), &c[0])
	gl.BindBufferRange(gl.UNIFORM_BUFFER, u32(u), dg.const_ring, int(o), int(sz))
	dg.const_off = o + sz
}

// The blocks of the stages on (shader ids[u] under keys[u]) whose bank was
// set or whose layout changed since their last push. Room is made for both,
// so a wrap, which loses the other block's range too, pushes both.
upload_consts :: proc(ids, keys: [2]u32, on: [2]bool) {
	need: [2]bool
	room: u32
	for u in 0 ..< 2 {
		if !on[u] {continue}
		s := &shaders[ids[u]]
		need[u] = consts_dirty[u] || dg.const_lay[u] != {ids[u] + 1, keys[u] >> 16}
		room += (s.crel ? keys[u] >> 16 : u32(len(s.cregs))) * 16 + dg.const_align
	}
	if !need[0] && !need[1] {return}
	if const_aligned() + room > CONST_RING {
		const_wrap()
		need = on
	}
	for u in 0 ..< 2 {
		if !need[u] {continue}
		buf: [VS_F_MAX][4]f32
		const_write(u, const_pack(&shaders[ids[u]], keys[u], u == 0 ? ds.vs.f[:] : ds.ps.f[:], &buf))
		consts_dirty[u] = false
		dg.const_lay[u] = {ids[u] + 1, keys[u] >> 16}
	}
}

Attr_Fmt :: struct {
	size: i32,
	type: u32,
	norm: bool,
}

ATTR_FMT := [Decl_Type]Attr_Fmt {
	.FLOAT1 = {1, gl.FLOAT, false}, .FLOAT2 = {2, gl.FLOAT, false}, .FLOAT3 = {3, gl.FLOAT, false},
	.FLOAT4 = {4, gl.FLOAT, false}, .D3DCOLOR = {gl.BGRA, gl.UNSIGNED_BYTE, true},
	.UBYTE4 = {4, gl.UNSIGNED_BYTE, false}, .SHORT2 = {2, gl.SHORT, false}, .SHORT4 = {4, gl.SHORT, false},
	.UBYTE4N = {4, gl.UNSIGNED_BYTE, true}, .SHORT2N = {2, gl.SHORT, true}, .SHORT4N = {4, gl.SHORT, true},
	.USHORT2N = {2, gl.UNSIGNED_SHORT, true}, .USHORT4N = {4, gl.UNSIGNED_SHORT, true},
	.UDEC3 = {}, .DEC3N = {}, .FLOAT16_2 = {2, gl.HALF_FLOAT, false}, .FLOAT16_4 = {4, gl.HALF_FLOAT, false},
	.UNUSED = {},
}

// Matches the vertex shader's dcl inputs to declaration elements by
// (usage, index) and points each attribute location at its element.
// vs_id FFVS_ID: the fixed-function locations (d3d9_ffvs.odin).
apply_attribs :: proc(decl_id, vs_id: u32) {
	if dg.attr_key == {decl_id + 1, vs_id + 1} {return}
	d := &decls[decl_id]
	on: u32
	if vs_id == FFVS_ID {
		for e in d.elems {
			if loc, ok := ffvs_loc(e); ok {on |= attr_point(e, loc)}
		}
	} else {
		for ins in shaders[vs_id].prog.insns {
			if ins.op != .DCL || ins.dst.reg != .INPUT {continue}
			usage, index, loc := ins.extra[0] & 0x1f, (ins.extra[0] >> 16) & 0xf, u32(ins.dst.num)
			for e in d.elems {
				if u32(e.usage) != usage || u32(e.index) != index {continue}
				on |= attr_point(e, loc)
				break
			}
		}
	}
	for loc in 0 ..< u32(16) {
		bit := u32(1) << loc
		if on & bit != 0 && dg.attr_on & bit == 0 {gl.EnableVertexArrayAttrib(dg.vao, loc)}
		if on & bit == 0 && dg.attr_on & bit != 0 {gl.DisableVertexArrayAttrib(dg.vao, loc)}
	}
	dg.attr_on = on
	dg.attr_key = {decl_id + 1, vs_id + 1}
}

// Points attribute location loc at element e; returns its enable bit.
attr_point :: proc(e: Decl_Elem, loc: u32) -> u32 {
	f := ATTR_FMT[e.type]
	if f.size == 0 {x86.fatal("d3d9: vertex element type %v unsupported", e.type)}
	gl.VertexArrayAttribFormat(dg.vao, loc, f.size, f.type, f.norm, u32(e.offset))
	gl.VertexArrayAttribBinding(dg.vao, loc, u32(e.stream))
	return 1 << loc
}

// Points each stream the declaration reads at its buffer; up_stride != 0
// substitutes the UP ring for stream 0.
apply_streams :: proc(up_off, up_stride: u32) {
	used := streams_used()
	for s in 0 ..< u32(STREAMS) {
		if used & (1 << s) == 0 {continue}
		if s == 0 && up_stride != 0 {
			gl.VertexArrayVertexBuffer(dg.vao, 0, dg.up_vb, int(up_off), i32(up_stride))
			continue
		}
		st := bind.streams[s]
		if st.vb == 0 {x86.fatal("d3d9: draw reads unbound stream %d", s)}
		gl.VertexArrayVertexBuffer(dg.vao, s, res_of(st.vb).gl, int(st.offset), i32(st.stride))
	}
}

// Bit mask of the streams the declaration reads.
streams_used :: proc() -> (used: u32) {
	for e in decls[bind.decl - 1].elems {used |= 1 << e.stream}
	return
}

// Uploads the dirty bytes of vertices [first, first + n) of each bound
// stream the declaration reads; a stream of stride 0 reads its whole buffer.
// WHY: docs/rendering.md §6
sync_streams :: proc(first, n: i64) {
	used := streams_used()
	for s in 0 ..< u32(STREAMS) {
		st := bind.streams[s]
		if used & (1 << s) == 0 || st.vb == 0 {continue}
		r := res_of(st.vb)
		if st.stride == 0 {
			buf_sync(r, 0, i64(r.w))
			continue
		}
		base := i64(st.offset)
		buf_sync(r, base + first * i64(st.stride), base + (first + n) * i64(st.stride))
	}
}

draw_prepare :: proc() {
	if bind.decl == 0 {x86.fatal("d3d9: draw without a vertex declaration")}
	decl_id := bind.decl - 1
	pretransformed := decl_pretransformed(decl_id)
	ff := bind.vs == 0 || pretransformed
	fb_bind()
	soft_prepare(decl_id, pretransformed)
	apply_raster()
	key := apply_textures()
	vs_id: u32 = ff ? FFVS_ID : bind.vs - 1
	vs_key := ff ? 0 : const_key(&shaders[vs_id])
	pv := ff ? 0 : ppl_draw(vs_id)
	if pv != 0 {vs_key |= 1}
	vs := ff ? ffvs_program(decl_id) : shader_program(vs_id, vs_key)
	if ff && !pretransformed {ffvs_upload(decl_id)}
	gl.UseProgramStages(dg.pipe, gl.VERTEX_SHADER_BIT, vs)
	fs, ps_id, ps_key: u32
	if bind.ps == 0 {
		fs = ff_program(pv, vs_key)
	} else {
		ps_id = bind.ps - 1
		s := &shaders[ps_id]
		ps_key = (s.prog.major == 1 ? key : 0) | const_key(s)
		fs = shader_program(ps_id, ps_key, pv, vs_key)
	}
	gl.UseProgramStages(dg.pipe, gl.FRAGMENT_SHADER_BIT, fs)
	upload_consts({vs_id, ps_id}, {vs_key, ps_key}, {!ff, bind.ps != 0})
	apply_attribs(decl_id, vs_id)
	if x86.hle_trace {draw_trace(decl_id)}
}

// Per-draw state line for JE_HLE_TRACE / JE_TRACE_FRAME, inside the draw's trace line.
draw_trace :: proc(decl_id: u32) {
	fmt.eprintf("\n\tdraw: vs %d ps %d rt %08x ds %08x vp %v decl", bind.vs, bind.ps, bind.rt[0], bind.depth, ds.viewport)
	for e in decls[decl_id].elems {fmt.eprintf(" %d:%v%d/%v@%d", e.stream, e.usage, e.index, e.type, e.offset)}
	// z, zwrite, atest, src, dst, cull, zfunc, aref, afunc, blend, fog, stencil, colorwrite, scissor
	RS_TRACE :: [?]u32{7, 14, 15, 19, 20, 22, 23, 24, 25, 27, 28, 52, 168, 174}
	fmt.eprintf("\n\t      rs")
	for r in RS_TRACE {fmt.eprintf(" %d=%x", r, ds.rs[r])}
	fmt.eprintf("\n\t      tex")
	for s in 0 ..< 4 {
		if obj := bind.tex[s]; obj != 0 {
			r := res_of(obj)
			fmt.eprintf(" %d:%v/%x/%dx%d", s, r.kind, r.format, r.w, r.h)
		} else {
			fmt.eprintf(" %d:-", s)
		}
	}
	fmt.eprintf(" pc0 %v pc1 %v vc94 %v\n", ds.ps.f[0], ds.ps.f[1], ds.vs.f[94])
}

PRIM_GL := [7]u32{gl.POINTS, gl.POINTS, gl.LINES, gl.LINE_STRIP, gl.TRIANGLES, gl.TRIANGLE_STRIP, gl.TRIANGLE_FAN}

prim_verts :: proc(t, n: u32) -> u32 {
	switch t {
	case 1: return n
	case 2: return 2 * n
	case 3: return n + 1
	case 4: return 3 * n
	}
	return n + 2
}

index_type :: proc(fmt: u32) -> (u32, u32) {
	return fmt == D3DFMT_INDEX32 ? gl.UNSIGNED_INT : gl.UNSIGNED_SHORT, fmt == D3DFMT_INDEX32 ? 4 : 2
}

// Copies n guest bytes at src into a UP ring; returns their offset.
up_push :: proc(buf: u32, off: ^u32, src, n: u32) -> u32 {
	if n > UP_SIZE {x86.fatal("d3d9: %d bytes of UP draw data", n)}
	o := (off^ + 63) &~ 63
	if o + n > UP_SIZE {
		gl.InvalidateBufferData(buf)
		o = 0
	}
	gl.NamedBufferSubData(buf, int(o), int(n), x86.ptr(src))
	off^ = o + n
	return o
}

// While set, draws, clears and copies between surfaces check their arguments
// and return as they would, but draw nothing: a pass of the frame that is not
// shown (online co-op draws each player's view, native/coop_camera.odin).
// Nothing the guest can read back changes.
null_render: bool

// (this, PrimitiveType, StartVertex, PrimitiveCount)
Dev_DrawPrimitive :: proc() {
	t := arg(1)
	if t < 1 || t > 6 {
		ret(4, D3DERR_INVALIDCALL)
		return
	}
	n := prim_verts(t, arg(3))
	if null_render {
		ret(4, D3D_OK)
		return
	}
	if shadow_draw(t, arg(2), n, false, 0, 0, 0) {
		ret(4, D3D_OK)
		return
	}
	draw_prepare()
	apply_streams(0, 0)
	sync_streams(i64(arg(2)), i64(n))
	gl.DrawArrays(PRIM_GL[t], i32(arg(2)), i32(n))
	ret(4, D3D_OK)
}

// (this, Type, BaseVertexIndex, MinVertexIndex, NumVertices, startIndex, primCount)
Dev_DrawIndexedPrimitive :: proc() {
	t := arg(1)
	if t < 1 || t > 6 || bind.indices == 0 {
		ret(7, D3DERR_INVALIDCALL)
		return
	}
	n := prim_verts(t, arg(6))
	base := i64(i32(arg(2)))
	if null_render {
		ret(7, D3D_OK)
		return
	}
	if shadow_draw(t, arg(5), n, true, i32(arg(2)), arg(3), arg(4)) {
		ret(7, D3D_OK)
		return
	}
	draw_prepare()
	apply_streams(0, 0)
	ib := res_of(bind.indices)
	ty, sz := index_type(ib.format)
	// The draw reads vertices MinVertexIndex .. + NumVertices past BaseVertexIndex.
	sync_streams(base + i64(arg(3)), i64(arg(4)))
	buf_sync(ib, i64(arg(5) * sz), i64((arg(5) + n) * sz))
	gl.VertexArrayElementBuffer(dg.vao, ib.gl)
	gl.DrawElementsBaseVertex(PRIM_GL[t], i32(n), ty, rawptr(uintptr(arg(5) * sz)), i32(arg(2)))
	ret(7, D3D_OK)
}

// (this, PrimitiveType, PrimitiveCount, pVertexStreamZeroData, VertexStreamZeroStride);
// stream 0 is unset afterwards, as in D3D9.
Dev_DrawPrimitiveUP :: proc() {
	t, stride := arg(1), arg(4)
	if t < 1 || t > 6 || stride == 0 {
		ret(5, D3DERR_INVALIDCALL)
		return
	}
	n := prim_verts(t, arg(2))
	if null_render {
		bind.streams[0] = {}
		ret(5, D3D_OK)
		return
	}
	off := up_push(dg.up_vb, &dg.up_vb_off, arg(3), n * stride)
	draw_prepare()
	apply_streams(off, stride)
	gl.DrawArrays(PRIM_GL[t], 0, i32(n))
	bind.streams[0] = {}
	ret(5, D3D_OK)
}

// (this, Type, MinVertexIndex, NumVertices, PrimitiveCount, pIndexData, IndexDataFormat,
//  pVertexStreamZeroData, VertexStreamZeroStride); stream 0 and indices are unset afterwards.
Dev_DrawIndexedPrimitiveUP :: proc() {
	t, stride := arg(1), arg(8)
	if t < 1 || t > 6 || stride == 0 {
		ret(9, D3DERR_INVALIDCALL)
		return
	}
	n := prim_verts(t, arg(4))
	if null_render {
		bind.streams[0] = {}
		bind.indices = 0
		ret(9, D3D_OK)
		return
	}
	ty, sz := index_type(arg(6))
	voff := up_push(dg.up_vb, &dg.up_vb_off, arg(7), (arg(2) + arg(3)) * stride)
	ioff := up_push(dg.up_ib, &dg.up_ib_off, arg(5), n * sz)
	draw_prepare()
	apply_streams(voff, stride)
	gl.VertexArrayElementBuffer(dg.vao, dg.up_ib)
	gl.DrawElements(PRIM_GL[t], i32(n), ty, rawptr(uintptr(ioff)))
	bind.streams[0] = {}
	bind.indices = 0
	ret(9, D3D_OK)
}
