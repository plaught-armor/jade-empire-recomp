// Shadow maps (JE_SHADOW): replace the game's creature shadows. The game
// draws a stencil shadow volume per creature (vertex shaders that extrude
// back faces away from the light in vc14), then fills a mask target with the
// shadow opacity where the stencil count is above 0x7f (0x5e5800) and blends
// a 4-tap blur of the mask over the frame. Volumes give hard, aliased edges
// and fail where the camera enters one. Here each volume draw is recorded
// instead of drawn; at the mask draw the recorded casters are rendered into
// an orthographic depth map from the light, with the volume's own vertex
// shader (so skinning still runs) and extrusion turned off, and the mask is
// filled by a full-screen pass that rebuilds each pixel's world position from
// the scene depth the game copied and filters the map with percentage-closer
// soft shadows. The game's blur and composite then run unchanged.
// WHY: docs/rendering.md §12
package win32

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"
import "../x86"

shadow_on := true // JE_SHADOW; 0 = the game's stencil volumes

SHADOW_SIZE :: 2048 // depth map texels per side
SHADOW_CASTERS :: 64 // recorded volume draws per frame; more are dropped
SHADOW_BOUND_VERTS :: 256 // vertices sampled per caster bound
SHADOW_BOUND_PAD :: 0.1 // world units added to a sampled bound
SHADOW_RADIUS :: 2.5 // world units: bound of a mesh whose vertices are unknown
SHADOW_MIN_EXTENT :: 4.0 // world units: smallest side of the map
SHADOW_SOFT :: 0.04 // penumbra width per unit from blocker to receiver
SHADOW_SEARCH :: 0.35 // world units: blocker search radius
SHADOW_MAX_PEN :: 0.35 // world units: widest penumbra
SHADOW_MIN_PEN :: 1.5 // texels: narrowest filter radius

Mat4 :: matrix[4, 4]f64

Shadow_Caster :: struct {
	streams:  [STREAMS]Stream,
	indices:  u32,
	decl, vs: u32, // decl id + 1, shader id + 1
	prim, n:  u32, // primitive type, vertex count
	first:    u32, // first vertex, or first index
	base:     i32, // base vertex
	world:    Mat4, // object to world
	center:   [3]f64, // world bound
	radius:   f64,
	row0:     [4]f32, // vc0 and vc3 at record: the same mesh drawn again is skipped
	row3:     [4]f32,
	ckey:     u32, // the shader's constant variant key at record (const_key)
	cs:       [2]u32, // its packed constants: shadow.consts[cs[0]:cs[1]]
}

Shadow :: struct {
	ready:          bool,
	map_tex, fbo:   u32,
	mask_fbo:       u32,
	depth_fs, fs:   u32, // empty depth-pass program, mask program
	vs, pipe, vao:  u32, // full-screen pipeline (BLOOM_VS)
	near_smp:       u32,
	cmp_smp:        u32,
	casters:        [SHADOW_CASTERS]Shadow_Caster,
	n:              int,
	frame:          u32, // frame the casters were recorded in
	consts:         [dynamic][4]f32, // the casters' packed constant blocks
	cam:            Mat4, // world to camera clip, from the first caster
	light:          [3]f64, // world light position, vc14
}

shadow: Shadow

// Mask pass: o.a = vertex alpha times the shadow. Light clip space matches
// the depth pass: UPPER_LEFT puts clip y = +1 at texture row 0.
SHADOW_PS :: `#version 460 core
layout(binding = 0) uniform sampler2D scene;
layout(binding = 1) uniform sampler2D smap;
layout(binding = 2) uniform sampler2DShadow scmp;
layout(location = 0) uniform mat4 inv_cam; // camera clip to world
layout(location = 4) uniform mat4 light;   // world to light clip
layout(location = 8) uniform vec4 param;   // texel (uv), search (uv), soft (uv per depth), bias (depth)
layout(location = 9) uniform vec4 pen;     // min, max filter radius (uv), normal offset (world)
layout(location = 10) uniform vec4 color;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o;

const vec2 DISK[16] = vec2[](
	vec2(-0.94201624, -0.39906216), vec2(0.94558609, -0.76890725), vec2(-0.09418410, -0.92938870),
	vec2(0.34495938, 0.29387760), vec2(-0.91588581, 0.45771432), vec2(-0.81544232, -0.87912464),
	vec2(-0.38277543, 0.27676845), vec2(0.97484398, 0.75648379), vec2(0.44323325, -0.97511554),
	vec2(0.53742981, -0.47373420), vec2(-0.26496911, -0.41893023), vec2(0.79197514, 0.19090188),
	vec2(-0.24188840, 0.99706507), vec2(-0.81409955, 0.91437590), vec2(0.19984126, 0.78641367),
	vec2(0.14383161, -0.14100790));

vec3 world_at(ivec2 p, ivec2 size) {
	p = clamp(p, ivec2(0), size - 1);
	float z = texelFetch(scene, p, 0).r;
	vec2 t = (vec2(p) + 0.5) / vec2(size);
	vec4 w = inv_cam * vec4(t.x * 2.0 - 1.0, 1.0 - t.y * 2.0, z, 1.0);
	return w.xyz / w.w;
}

// Of the two neighbours along one axis, the step to the nearer in depth, so
// an edge does not bend the normal.
vec3 near_step(vec3 p, vec3 a, vec3 b) {
	vec3 da = a - p, db = p - b;
	return dot(da, da) < dot(db, db) ? da : db;
}

void main() {
	ivec2 size = textureSize(scene, 0);
	ivec2 q = ivec2(uv * vec2(size));
	q = clamp(q, ivec2(0), size - 1);
	if (texelFetch(scene, q, 0).r >= 1.0) { o = vec4(color.rgb, 0.0); return; }
	vec3 p = world_at(q, size);
	vec3 dx = near_step(p, world_at(q + ivec2(1, 0), size), world_at(q - ivec2(1, 0), size));
	vec3 dy = near_step(p, world_at(q + ivec2(0, 1), size), world_at(q - ivec2(0, 1), size));
	vec3 n = normalize(cross(dx, dy));
	vec4 e = inv_cam * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
	if (dot(n, e.xyz / e.w - p) < 0.0) n = -n;
	vec4 lc = light * vec4(p + n * pen.z, 1.0);
	vec2 s = vec2(lc.x * 0.5 + 0.5, 0.5 - lc.y * 0.5);
	if (any(lessThan(s, vec2(0.0))) || any(greaterThan(s, vec2(1.0)))) { o = vec4(color.rgb, 0.0); return; }
	float dr = min(lc.z, 0.99999) - param.w;
	float a = 6.2831853 * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
	mat2 rot = mat2(cos(a), sin(a), -sin(a), cos(a));
	float sum = 0.0, nb = 0.0;
	for (int i = 0; i < 16; i++) {
		float d = textureLod(smap, s + rot * DISK[i] * param.y, 0.0).r;
		if (d < dr) { sum += d; nb += 1.0; }
	}
	if (nb == 0.0) { o = vec4(color.rgb, 0.0); return; }
	float r = clamp((dr - sum / nb) * param.z, pen.x, pen.y);
	float lit = 0.0;
	for (int i = 0; i < 16; i++) lit += texture(scmp, vec3(s + rot * DISK[i] * r, dr));
	o = vec4(color.rgb, color.a * (1.0 - lit / 16.0));
}
`

SHADOW_DEPTH_FS :: `#version 460 core
void main() {}
`

@(private = "file")
shadow_init :: proc() {
	gl.CreateTextures(gl.TEXTURE_2D, 1, &shadow.map_tex)
	gl.TextureStorage2D(shadow.map_tex, 1, gl.DEPTH_COMPONENT32F, SHADOW_SIZE, SHADOW_SIZE)
	gl.CreateFramebuffers(1, &shadow.fbo)
	gl.NamedFramebufferTexture(shadow.fbo, gl.DEPTH_ATTACHMENT, shadow.map_tex, 0)
	gl.NamedFramebufferDrawBuffer(shadow.fbo, gl.NONE)
	gl.CreateFramebuffers(1, &shadow.mask_fbo)
	shadow.depth_fs = glsl_compile(SHADOW_DEPTH_FS, true)
	shadow.fs = glsl_compile(SHADOW_PS, true)
	shadow.vs = glsl_compile(BLOOM_VS, false)
	gl.CreateProgramPipelines(1, &shadow.pipe)
	gl.UseProgramStages(shadow.pipe, gl.VERTEX_SHADER_BIT, shadow.vs)
	gl.UseProgramStages(shadow.pipe, gl.FRAGMENT_SHADER_BIT, shadow.fs)
	gl.CreateVertexArrays(1, &shadow.vao)
	gl.CreateSamplers(1, &shadow.near_smp)
	gl.CreateSamplers(1, &shadow.cmp_smp)
	for s in ([2]u32{shadow.near_smp, shadow.cmp_smp}) {
		gl.SamplerParameteri(s, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.SamplerParameteri(s, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	}
	gl.SamplerParameteri(shadow.near_smp, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.SamplerParameteri(shadow.near_smp, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.SamplerParameteri(shadow.cmp_smp, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.SamplerParameteri(shadow.cmp_smp, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.SamplerParameteri(shadow.cmp_smp, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE)
	gl.SamplerParameteri(shadow.cmp_smp, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL)
	shadow.ready = true
}

// The rows of vc[base .. base + 3] as a matrix: clip = m * p.
@(private = "file")
vc_rows :: proc(c: ^Vs_Consts, base: int) -> (m: Mat4) {
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {m[i, j] = f64(c.f[base + i][j])}
	}
	return
}

@(private = "file")
mat_f32 :: proc(m: Mat4) -> (r: matrix[4, 4]f32) {
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {r[i, j] = f32(m[i, j])}
	}
	return
}

// The draw being issued is a shadow volume: stencil counting with color
// writes off, from a vertex shader over positions and normals.
@(private = "file")
shadow_is_volume :: proc() -> bool {
	rs := &ds.rs
	if rs[52] == 0 || rs[168] != 0 || bind.vs == 0 || bind.decl == 0 {return false}
	if op := rs[55]; op != 4 && op != 5 && op != 7 && op != 8 {return false}
	normal := false
	for e in decls[bind.decl - 1].elems {
		if e.usage == .NORMAL {normal = true}
	}
	return normal
}

// The draw being issued is the mask quad of 0x5e5800: stencil above 0x7f,
// depth off, colour on, into a render target texture.
@(private = "file")
shadow_is_mask :: proc() -> bool {
	rs := &ds.rs
	return rs[52] != 0 && rs[56] == 4 && rs[57] == 0x80 && rs[168] == 0xf && rs[7] == 0 &&
		bind.rt[0] != 0 && bind.rt[0] != backbuf && bind.depth != 0 && bind.depth != autodepth &&
		bind.streams[0].vb != 0
}

// Takes over a DrawPrimitive (indexed false) or DrawIndexedPrimitive when it
// is a volume or the mask quad; true: the draw is done. first is the start
// vertex or start index, n the vertex count, base, lo and num the indexed
// draw's BaseVertexIndex, MinVertexIndex and NumVertices.
shadow_draw :: proc(prim, first, n: u32, indexed: bool, base: i32, lo, num: u32) -> bool {
	if !shadow_on {return false}
	if shadow.frame != frame_count {
		shadow.n, shadow.frame = 0, frame_count
		clear(&shadow.consts)
	}
	if shadow_is_volume() {
		if indexed {
			sync_streams(i64(base) + i64(lo), i64(num))
			ib := res_of(bind.indices)
			_, sz := index_type(ib.format)
			buf_sync(ib, i64(first * sz), i64((first + n) * sz))
		} else {
			sync_streams(i64(first), i64(n))
		}
		vlo, vnum := indexed ? u32(i64(base) + i64(lo)) : first, indexed ? num : n
		shadow_record(prim, first, n, base, indexed ? bind.indices : 0, vlo, vnum)
		return true
	}
	if shadow_is_mask() && shadow.n > 0 {
		shadow_mask(first)
		shadow.n = 0
		clear(&shadow.consts)
		return true
	}
	return false
}

// Records the volume draw being issued; the same mesh drawn again for its
// other faces is skipped.
@(private = "file")
shadow_record :: proc(prim, first, n: u32, base: i32, indices, vlo, vnum: u32) {
	c := &ds.vs
	if shadow.n > 0 {
		l := &shadow.casters[shadow.n - 1]
		if l.streams == bind.streams && l.indices == indices && l.first == first && l.n == n && l.base == base &&
		   l.row0 == c.f[0] && l.row3 == c.f[3] {return}
	}
	if shadow.n == SHADOW_CASTERS {return}
	inv := vc_rows(c, 4) // world to object
	if abs(linalg.determinant(inv)) < 1e-12 {return}
	world := linalg.inverse(inv)
	if shadow.n == 0 {
		shadow.cam = vc_rows(c, 0) * inv
		l := c.f[14]
		shadow.light = {f64(l[0]), f64(l[1]), f64(l[2])}
	}
	k := &shadow.casters[shadow.n]
	shadow.n += 1
	k.streams, k.indices, k.decl, k.vs = bind.streams, indices, bind.decl, bind.vs
	k.prim, k.n, k.first, k.base = prim, n, first, base
	k.world = world
	k.row0, k.row3 = c.f[0], c.f[3]
	s := &shaders[k.vs - 1]
	k.ckey = const_key(s)
	buf: [VS_F_MAX][4]f32
	p := const_pack(s, k.ckey, c.f[:], &buf)
	k.cs = {u32(len(shadow.consts)), u32(len(shadow.consts) + len(p))}
	append(&shadow.consts, ..p)
	bc, br := shadow_bound(vlo, vnum)
	wc := world * [4]f64{bc.x, bc.y, bc.z, 1}
	k.center = wc.xyz
	sc: f64
	for j in 0 ..< 3 {sc = max(sc, linalg.length([3]f64{world[0, j], world[1, j], world[2, j]}))}
	k.radius = br * sc
}

// The object-space bound of vertices [first, first + n) of the bound
// streams, read from the buffers' shadow copies. A skinned mesh (weights and
// indices beside the position) is posed as the volume shaders pose it: each
// vertex is the weighted sum of its first three bones, each bone the three
// rows of vc starting at its index. Large meshes are sampled.
@(private = "file")
shadow_bound :: proc(first, n: u32) -> (center: [3]f64, radius: f64) {
	// Guest address of element e of vertex first and the stride, ok false
	// unless vertices [first, first + n) all lie in the buffer.
	Elem_Walk :: struct {
		a, stride: u32,
	}
	walk :: proc(e: Decl_Elem, first, n, size: u32) -> (w: Elem_Walk, ok: bool) {
		st := bind.streams[e.stream]
		if st.vb == 0 || st.stride == 0 {return}
		r := res_of(st.vb)
		off := u64(st.offset) + u64(first) * u64(st.stride) + u64(e.offset)
		if r.shadow == 0 || off + u64(n - 1) * u64(st.stride) + u64(size) > u64(r.w) {return}
		return {r.shadow + u32(off), st.stride}, true
	}
	pos, wt, ix: Maybe(Decl_Elem)
	for e in decls[bind.decl - 1].elems {
		#partial switch e.usage {
		case .POSITION: if e.index == 0 && e.type == .FLOAT3 {pos = e}
		case .BLENDWEIGHT: if e.type == .SHORT4N {wt = e}
		case .BLENDINDICES: if e.type == .UBYTE4 {ix = e}
		}
	}
	pe, has_pos := pos.?
	if !has_pos || n == 0 {return {}, SHADOW_RADIUS}
	pw, ok := walk(pe, first, n, 12)
	if !ok {return {}, SHADOW_RADIUS}
	we, skinned := wt.?
	ie, has_ix := ix.?
	ww, iw: Elem_Walk
	if skinned && has_ix {
		ok_w, ok_i: bool
		ww, ok_w = walk(we, first, n, 8)
		iw, ok_i = walk(ie, first, n, 4)
		if !ok_w || !ok_i {return {}, SHADOW_RADIUS}
	} else {
		skinned = false
	}
	c := &ds.vs
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := -lo
	step := max(n / SHADOW_BOUND_VERTS, 1)
	#no_bounds_check for v: u32 = 0; v < n; v += step {
		p := intrinsics.unaligned_load((^[3]f32)(x86.ptr(pw.a + v * pw.stride)))
		if skinned {
			wa, ia := ww.a + v * ww.stride, iw.a + v * iw.stride
			q: [3]f32
			for j in 0 ..< u32(3) {
				w := f32(i16(x86.rd16(wa + j * 2))) / 32767
				b := c.f[min(u32(x86.rd8(ia + j)), 253):][:3]
				for k in 0 ..< 3 {q[k] += w * (b[k].x * p.x + b[k].y * p.y + b[k].z * p.z + b[k].w)}
			}
			p = q
		}
		lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	}
	for j in 0 ..< 3 {center[j] = f64(lo[j] + hi[j]) / 2}
	d := hi - lo
	radius = linalg.length([3]f64{f64(d.x), f64(d.y), f64(d.z)}) * 0.5 + SHADOW_BOUND_PAD
	return
}

// Renders the recorded casters into the depth map and fills the bound mask
// target in place of the mask quad starting at vertex first. Every state
// touched here is restored by the next draw (apply_raster, upload_consts,
// apply_attribs, apply_textures), except the pipeline's VAO, the program
// pipeline and the samplers of units 0 to 2, restored below.
@(private = "file")
shadow_mask :: proc(first: u32) {
	if !shadow.ready {shadow_init()}
	// Light: a direction from vc14 to the casters, an orthographic box
	// around their bounds.
	mid: [3]f64
	for i in 0 ..< shadow.n {mid += shadow.casters[i].center}
	mid /= f64(shadow.n)
	f := linalg.normalize(mid - shadow.light)
	up := abs(f.z) < 0.99 ? [3]f64{0, 0, 1} : [3]f64{0, 1, 0}
	rt := linalg.normalize(linalg.cross(f, up))
	u := linalg.cross(rt, f)
	lo := [3]f64{max(f64), max(f64), max(f64)}
	hi := -lo
	for i in 0 ..< shadow.n {
		k := &shadow.casters[i]
		p := [3]f64{linalg.dot(rt, k.center), linalg.dot(u, k.center), linalg.dot(f, k.center)}
		lo, hi = linalg.min(lo, p - k.radius), linalg.max(hi, p + k.radius)
	}
	// Side in powers of two and centre on whole texels, so the map's texel
	// grid holds still while the casters move.
	side := math.pow(2, math.ceil(math.log2(max(hi.x - lo.x, hi.y - lo.y, SHADOW_MIN_EXTENT))))
	texel := side / SHADOW_SIZE
	cx := math.round((lo.x + hi.x) / 2 / texel) * texel
	cy := math.round((lo.y + hi.y) / 2 / texel) * texel
	near, far := lo.z - 0.5, hi.z + 0.5
	range := far - near
	s := 2 / side
	light := Mat4 {
		rt.x * s, rt.y * s, rt.z * s, -cx * s,
		u.x * s, u.y * s, u.z * s, -cy * s,
		f.x / range, f.y / range, f.z / range, -near / range,
		0, 0, 0, 1,
	}

	// Depth pass.
	saved := bind
	raster_lost()
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, shadow.fbo)
	gl.Viewport(0, 0, SHADOW_SIZE, SHADOW_SIZE)
	gl.DepthRangef(0, 1)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.STENCIL_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.BLEND)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.DepthMask(true)
	gl.Enable(gl.POLYGON_OFFSET_FILL)
	gl.PolygonOffset(1.5, 2)
	one: f32 = 1
	gl.ClearNamedFramebufferfv(shadow.fbo, gl.DEPTH, 0, &one)
	misc: Misc // pos_fix 0: no half-pixel shift in the map
	gl.NamedBufferSubData(dg.misc_ubo, 0, size_of(Misc), &misc)
	gl.UseProgramStages(dg.pipe, gl.FRAGMENT_SHADER_BIT, shadow.depth_fs)
	for i in 0 ..< shadow.n {
		k := &shadow.casters[i]
		m := mat_f32(light * k.world)
		s := &shaders[k.vs - 1]
		c := shadow.consts[k.cs[0]:k.cs[1]]
		for r in 0 ..< 4 {
			if j, ok := const_slot(s, r); ok {c[j] = {m[r, 0], m[r, 1], m[r, 2], m[r, 3]}}
		}
		if j, ok := const_slot(s, 13); ok {c[j].yzw = 0} // no extrusion
		if const_aligned() + u32(len(c) * 16) + dg.const_align > CONST_RING {const_wrap()}
		const_write(0, c)
		bind.streams, bind.indices, bind.decl, bind.vs = k.streams, k.indices, k.decl, k.vs
		gl.UseProgramStages(dg.pipe, gl.VERTEX_SHADER_BIT, shader_program(k.vs - 1, k.ckey))
		apply_attribs(k.decl - 1, k.vs - 1)
		apply_streams(0, 0)
		if k.indices != 0 {
			ty, sz := index_type(res_of(k.indices).format)
			gl.VertexArrayElementBuffer(dg.vao, res_of(k.indices).gl)
			gl.DrawElementsBaseVertex(PRIM_GL[k.prim], i32(k.n), ty, rawptr(uintptr(k.first * sz)), k.base)
		} else {
			gl.DrawArrays(PRIM_GL[k.prim], i32(k.first), i32(k.n))
		}
	}
	bind = saved
	consts_dirty[0] = true

	// Mask pass into the bound target; the scene depth is the game's copy,
	// the bound depth surface.
	mask := res_of(bind.rt[0])
	mk := res_scale(mask)
	vb := bind.streams[0]
	color := [4]f32{0, 0, 0, 1}
	if r := res_of(vb.vb); r.shadow != 0 && vb.offset + first * vb.stride + 16 <= r.w {
		color = argb_vec(x86.rd32(r.shadow + vb.offset + first * vb.stride + 12))
	}
	attach(shadow.mask_fbo, gl.COLOR_ATTACHMENT0, bind.rt[0])
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, shadow.mask_fbo)
	gl.Viewport(0, 0, i32(mask.w * mk), i32(mask.h * mk))
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.POLYGON_OFFSET_FILL)
	gl.ColorMaski(0, true, true, true, true)
	inv_cam := mat_f32(linalg.inverse(shadow.cam))
	lm := mat_f32(light)
	t := 1 / f64(SHADOW_SIZE)
	p := shadow.fs
	gl.ProgramUniformMatrix4fv(p, 0, 1, false, &inv_cam[0, 0])
	gl.ProgramUniformMatrix4fv(p, 4, 1, false, &lm[0, 0])
	gl.ProgramUniform4f(p, 8, f32(t), f32(SHADOW_SEARCH / side), f32(SHADOW_SOFT * range / side), f32(1.5 * texel / range))
	gl.ProgramUniform4f(p, 9, f32(SHADOW_MIN_PEN * t), f32(SHADOW_MAX_PEN / side), f32(texel * 1.5), 0)
	gl.ProgramUniform4f(p, 10, color[0], color[1], color[2], color[3])
	gl.BindTextureUnit(0, res_of(bind.depth).gl)
	gl.BindTextureUnit(1, shadow.map_tex)
	gl.BindTextureUnit(2, shadow.map_tex)
	gl.BindSampler(0, shadow.near_smp)
	gl.BindSampler(1, shadow.near_smp)
	gl.BindSampler(2, shadow.cmp_smp)
	gl.BindVertexArray(shadow.vao)
	gl.BindProgramPipeline(shadow.pipe)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	attach(shadow.mask_fbo, gl.COLOR_ATTACHMENT0, 0)
	for i in 0 ..< u32(3) {gl.BindSampler(i, dg.samplers[i])}
	gl.BindVertexArray(dg.vao)
	gl.BindProgramPipeline(dg.pipe)
}
