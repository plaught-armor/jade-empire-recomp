// Fixed-function vertex stage, used when no vertex shader is bound or the
// declaration has a POSITIONT element (FVF XYZRHW). Both feed the shared
// vertex interface (d3d9_glsl.odin). Absent inputs take the D3D defaults:
// diffuse white, specular black, texcoords (0, 0, 0, 1), normal zero.
//
// Pretransformed: as on D3D9 (and Wine), a POSITIONT declaration bypasses any
// bound vertex shader. The shader turns screen-space (x, y, z, rhw) back into
// the D3D clip-space position the viewport transform would have produced,
// w = 1/rhw so interpolation stays perspective-correct.
//
// Transform and lighting: WORLD * VIEW * PROJECTION, lighting in view space
// with up to FFVS_LIGHTS enabled lights (directional, point, spot), material
// color sources, vertex fog and texture coordinate generation / transforms.
// The state travels in the FFVS block (binding 3); the program depends only
// on the declaration. Vertex blending, point scaling, per-vertex point size
// and sphere-map generation are fatal: none is observed in this game.
// WHY: docs/hle.md §6
package win32

import "core:fmt"
import "core:math"
import "core:strings"
import gl "vendor:OpenGL"
import "../x86"

// Attribute locations of the FF vertex inputs.
FFVS_LOC_POS :: 0 // POSITION or POSITIONT
FFVS_LOC_D0 :: 1
FFVS_LOC_D1 :: 2
FFVS_LOC_T0 :: 3 // TEXCOORD i at 3 + i
FFVS_TC :: 8
FFVS_LOC_NRM :: 11

// Program key: bit = location present; bits FFVS_KEY_DIM + 2i hold the
// component count - 1 of TEXCOORD i; FFVS_KEY_XYZRHW marks POSITIONT.
FFVS_KEY_DIM :: 12
FFVS_KEY_XYZRHW :: 31

FFVS_LIGHTS :: 8 // enabled lights a draw may use

// The vertex shader id standing for the FF vertex stage in attribute keys.
FFVS_ID :: 0xfffffffe

// D3DTRANSFORMSTATETYPE slots in ds.xf.
XF_VIEW :: 2
XF_PROJECTION :: 3
XF_TEXTURE0 :: 16
XF_WORLD :: 256

// std140 mirror of the GLSL FFVS block below.
Ffvs_Light :: struct {
	d, s, a:  [4]f32, // diffuse, specular, ambient
	pos, dir: [4]f32, // view space
	att:      [4]f32, // range, attenuation 0, 1, 2
	spot:     [4]f32, // falloff, cos(theta / 2), cos(phi / 2), D3DLIGHTTYPE
}

Ffvs :: struct {
	wvp, wv, nrm:               Mat, // nrm: inverse transpose of wv
	tex:                        [FFVS_TC]Mat, // per stage
	mat_d, mat_a, mat_s, mat_e: [4]f32,
	amb:                        [4]f32, // D3DRS_AMBIENT
	param:                      [4]f32, // material power, point size
	flags:                      [4]i32, // lighting, lights, local viewer, normalize normals
	src:                        [4]i32, // diffuse, ambient, specular, emissive: 0 material, 1 color0, 2 color1
	fog:                        [4]i32, // D3DRS_FOGVERTEXMODE, range fog, specular enable
	tc:                         [FFVS_TC][4]i32, // per stage: set (-1 untouched), TCI generation, TTFF count
	lights:                     [FFVS_LIGHTS]Ffvs_Light,
}

ffvs_programs: map[u32]u32 // ffvs_key -> program

decl_pretransformed :: proc(decl_id: u32) -> bool {
	for e in decls[decl_id].elems {
		if e.usage == .POSITIONT {return true}
	}
	return false
}

// FF vertex input location of a declaration element.
ffvs_loc :: proc(e: Decl_Elem) -> (loc: u32, ok: bool) {
	#partial switch e.usage {
	case .POSITION, .POSITIONT: if e.index == 0 {return FFVS_LOC_POS, true}
	case .NORMAL: if e.index == 0 {return FFVS_LOC_NRM, true}
	case .COLOR: if e.index < 2 {return FFVS_LOC_D0 + u32(e.index), true}
	case .TEXCOORD: if e.index < FFVS_TC {return FFVS_LOC_T0 + u32(e.index), true}
	}
	return 0, false
}

ffvs_key :: proc(decl_id: u32) -> (k: u32) {
	for e in decls[decl_id].elems {
		loc, ok := ffvs_loc(e)
		if !ok {continue}
		k |= 1 << loc
		if loc >= FFVS_LOC_T0 && loc < FFVS_LOC_T0 + FFVS_TC {
			n := ATTR_FMT[e.type].size
			dim := n == gl.BGRA ? 4 : clamp(n, 1, 4)
			k |= u32(dim - 1) << (FFVS_KEY_DIM + 2 * (loc - FFVS_LOC_T0))
		}
	}
	if decl_pretransformed(decl_id) {k |= 1 << FFVS_KEY_XYZRHW}
	return
}

ffvs_program :: proc(decl_id: u32) -> u32 {
	k := ffvs_key(decl_id)
	if p, ok := ffvs_programs[k]; ok {return p}
	p := glsl_compile(glsl_ffvs(k), false)
	ffvs_programs[k] = p
	return p
}

// Fills and uploads the FFVS block for a transformed FF draw.
ffvs_upload :: proc(decl_id: u32) {
	@(static) u: Ffvs
	rs := &ds.rs
	if rs[151] != 0 {x86.fatal("d3d9: fixed-function vertex blending not implemented (VERTEXBLEND %d)", rs[151])}
	if rs[157] != 0 {x86.fatal("d3d9: fixed-function point scaling not implemented")}
	for e in decls[decl_id].elems {
		if e.usage == .PSIZE {x86.fatal("d3d9: fixed-function per-vertex point size not implemented")}
	}
	wv := mat_mul(ds.xf[XF_WORLD], ds.xf[XF_VIEW])
	u.wv, u.wvp = wv, mat_mul(wv, ds.xf[XF_PROJECTION])
	// a singular world-view leaves normals zero: no diffuse or specular term
	inv, _, ok := mat_inverse(wv)
	u.nrm = ok ? mat_transpose(inv) : {}
	mt := transmute([17]f32)ds.material
	u.mat_d, u.mat_a = {mt[0], mt[1], mt[2], mt[3]}, {mt[4], mt[5], mt[6], mt[7]}
	u.mat_s, u.mat_e = {mt[8], mt[9], mt[10], mt[11]}, {mt[12], mt[13], mt[14], mt[15]}
	u.amb = argb_vec(rs[139])
	u.param = {mt[16], transmute(f32)rs[154], 0, 0}
	k := ffvs_key(decl_id)
	// D3DMCS_COLOR1/2 apply only with COLORVERTEX and the color present
	color_src :: proc(cv: bool, k, s: u32) -> i32 {
		if !cv || s == 0 || s > 2 || k & (1 << (FFVS_LOC_D0 + s - 1)) == 0 {return 0}
		return i32(s)
	}
	cv := rs[141] != 0
	u.src = {color_src(cv, k, rs[145]), color_src(cv, k, rs[147]), color_src(cv, k, rs[146]), color_src(cv, k, rs[148])}
	u.fog = {i32(min(rs[140], 3)), i32(rs[48] != 0), i32(rs[29] != 0), 0}
	u.flags = {i32(rs[137] != 0), ffvs_lights(&u), i32(rs[142] != 0), i32(rs[143] != 0)}
	ffvs_texcoords(&u)
	gl.NamedBufferSubData(dg.ffvs_ubo, 0, size_of(Ffvs), &u)
}

// Enabled lights in index order, moved to view space; returns the count.
ffvs_lights :: proc(u: ^Ffvs) -> (n: i32) {
	v := ds.xf[XF_VIEW]
	for &l, i in ds.lights {
		if !l.enabled {continue}
		if n == FFVS_LIGHTS {x86.fatal("d3d9: more than %d lights enabled (light %d)", FFVS_LIGHTS, i)}
		r := transmute([26]f32)l.raw
		t := l.raw[0]
		if t < 1 || t > 3 {x86.fatal("d3d9: light %d has type %d", i, t)}
		o := &u.lights[n]
		o.d, o.s, o.a = {r[1], r[2], r[3], r[4]}, {r[5], r[6], r[7], r[8]}, {r[9], r[10], r[11], r[12]}
		o.pos = vec_mat({r[13], r[14], r[15], 1}, v)
		o.dir = vec_mat({r[16], r[17], r[18], 0}, v)
		o.att = {r[19], r[21], r[22], r[23]}
		o.spot = {r[20], math.cos(r[24] / 2), math.cos(r[25] / 2), f32(t)}
		n += 1
	}
	return
}

// Stages that generate or transform coordinates. The FF pixel stage reads
// oT[TEXCOORDINDEX], so stage s writes its result to that set; two stages
// must not claim one set, and a pixel shader (which reads oT[s]) needs the
// set to be s.
ffvs_texcoords :: proc(u: ^Ffvs) {
	claimed: u32
	for s in 0 ..< FFVS_TC {
		u.tc[s] = {-1, 0, 0, 0}
	}
	for s in 0 ..< u32(FFVS_TC) {
		t := &ds.tss[s]
		if bind.ps == 0 && t[1] == TOP_DISABLE {break}
		gen, count, set := t[11] >> 16, t[24] & 0xff, t[11] & 7
		if gen == 0 && count == 0 {continue}
		if gen > 3 {x86.fatal("d3d9: texture coordinate generation %x not implemented (stage %d)", t[11], s)}
		if count > 4 {x86.fatal("d3d9: TEXTURETRANSFORMFLAGS %x (stage %d)", t[24], s)}
		if claimed & (1 << set) != 0 {x86.fatal("d3d9: two stages generate texture coordinate set %d", set)}
		if bind.ps != 0 && set != s {x86.fatal("d3d9: stage %d generates set %d under a pixel shader", s, set)}
		claimed |= 1 << set
		u.tc[s] = {i32(set), i32(gen), i32(count), 0}
		u.tex[s] = ds.xf[XF_TEXTURE0 + s]
	}
}

// Row vector times a D3D matrix.
vec_mat :: proc(v: [4]f32, m: Mat) -> (o: [4]f32) {
	for c in 0 ..< 4 {
		o[c] = v[0] * m[0][c] + v[1] * m[1][c] + v[2] * m[2][c] + v[3] * m[3][c]
	}
	return
}

glsl_ffvs :: proc(key: u32) -> string {
	h := strings.builder_make(context.temp_allocator)
	strings.write_string(&h, GLSL_COMMON)
	strings.write_string(&h, "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n")
	inp :: proc(h: ^strings.Builder, key, loc: u32, name, def: string) {
		if key & (1 << loc) != 0 {
			fmt.sbprintf(h, "layout(location = %d) in vec4 %s;\n", loc, name)
		} else {
			fmt.sbprintf(h, "const vec4 %s = %s;\n", name, def)
		}
	}
	inp(&h, key, FFVS_LOC_POS, "v_pos", "vec4(0.0, 0.0, 0.0, 1.0)")
	inp(&h, key, FFVS_LOC_D0, "v_d0", "vec4(1.0)")
	inp(&h, key, FFVS_LOC_D1, "v_d1", "vec4(0.0)")
	inp(&h, key, FFVS_LOC_NRM, "v_nrm", "vec4(0.0)")
	for i in 0 ..< u32(FFVS_TC) {
		inp(&h, key, FFVS_LOC_T0 + i, fmt.tprintf("v_t%d", i), "vec4(0.0, 0.0, 0.0, 1.0)")
	}
	strings.write_string(&h, "layout(location = 0) out vec4 o_d0;\nlayout(location = 1) out vec4 o_d1;\n")
	for i in 0 ..< 8 {fmt.sbprintf(&h, "layout(location = %d) out vec4 o_t%d;\n", 2 + i, i)}
	strings.write_string(&h, "layout(location = 10) out vec4 o_fog;\n")
	if key & (1 << FFVS_KEY_XYZRHW) != 0 {
		glsl_ffvs_xyzrhw(&h)
	} else {
		glsl_ffvs_tl(&h, key)
	}
	return strings.to_string(h)
}

glsl_ffvs_xyzrhw :: proc(h: ^strings.Builder) {
	strings.write_string(h, "void main() {\n")
	// vp = (x, y, 2/w, 2/h), vp_z = (min_z, 1/(max_z - min_z), scale)
	strings.write_string(h, "\tvec3 c = vec3((v_pos.x - vp.x) * vp.z - 1.0, 1.0 - (v_pos.y - vp.y) * vp.w, (v_pos.z - vp_z.x) * vp_z.y);\n")
	strings.write_string(h, "\tfloat w = v_pos.w != 0.0 ? 1.0 / v_pos.w : 1.0;\n")
	strings.write_string(h, "\tvec4 opos = vec4(c, 1.0) * w;\n")
	strings.write_string(h, "\tgl_Position = vec4(opos.xy + opos.w * pos_fix.xy, opos.zw);\n\tgl_PointSize = 1.0;\n")
	// vertex fog for transformed vertices is the specular alpha
	strings.write_string(h, "\to_d0 = v_d0; o_d1 = v_d1; o_fog = vec4(v_d1.a);\n")
	for i in 0 ..< 8 {fmt.sbprintf(h, "\to_t%d = v_t%d;\n", i, i)}
	strings.write_string(h, "}\n")
}

// Matrices are uploaded as stored (D3D row-major), so GLSL `m * v` is the
// D3D row-vector product v * M.
GLSL_FFVS_TL :: `struct Light { vec4 d, s, a, pos, dir, att, spot; };
layout(std140, binding = 3) uniform FFVS {
	mat4 wvp, wv, nrm;
	mat4 tex[8];
	vec4 mat_d, mat_a, mat_s, mat_e, amb, param;
	ivec4 flags, src, fog;
	ivec4 tc[8];
	Light lights[8];
};
vec4 ff_src(int s, vec4 m) { return s == 1 ? v_d0 : s == 2 ? v_d1 : m; }
void ff_light(vec3 e, vec3 n, vec3 v, out vec4 d0, out vec4 d1) {
	vec4 md = ff_src(src.x, mat_d), ma = ff_src(src.y, mat_a), ms = ff_src(src.z, mat_s), me = ff_src(src.w, mat_e);
	vec3 dif = vec3(0.0), al = vec3(0.0), sp = vec3(0.0);
	for (int i = 0; i < flags.y; i++) {
		Light l = lights[i];
		vec3 ld = -normalize(l.dir.xyz);
		float att = 1.0;
		if (l.spot.w != 3.0) {
			vec3 dv = l.pos.xyz - e;
			float dist = length(dv);
			ld = dist > 0.0 ? dv / dist : vec3(0.0, 0.0, -1.0);
			att = dist > l.att.x ? 0.0 : 1.0 / (l.att.y + l.att.z * dist + l.att.w * dist * dist);
			if (l.spot.w == 2.0) {
				float rho = dot(-ld, normalize(l.dir.xyz));
				att *= rho > l.spot.y ? 1.0 : rho <= l.spot.z ? 0.0 : pow((rho - l.spot.z) / (l.spot.y - l.spot.z), l.spot.x);
			}
		}
		float nl = max(dot(n, ld), 0.0);
		dif += att * nl * l.d.rgb;
		al += att * l.a.rgb;
		if (fog.z != 0 && nl > 0.0) {
			float nh = max(dot(n, normalize(v + ld)), 0.0);
			sp += att * (param.x > 0.0 ? pow(nh, param.x) : 1.0) * l.s.rgb;
		}
	}
	d0 = vec4(clamp(me.rgb + ma.rgb * (amb.rgb + al) + md.rgb * dif, 0.0, 1.0), md.a);
	d1 = vec4(clamp(ms.rgb * sp, 0.0, 1.0), ms.a);
}
void main() {
	vec4 p = vec4(v_pos.xyz, 1.0);
	vec4 opos = wvp * p;
	gl_Position = vec4(opos.xy + opos.w * pos_fix.xy, opos.zw);
	gl_PointSize = param.y * vp_z.z;
	vec3 e = (wv * p).xyz;
	vec3 n = (nrm * vec4(v_nrm.xyz, 0.0)).xyz;
	if (flags.w != 0 && dot(n, n) > 0.0) n = normalize(n);
	vec3 v = flags.z != 0 && dot(e, e) > 0.0 ? -normalize(e) : vec3(0.0, 0.0, -1.0);
	vec4 d0 = v_d0, d1 = v_d1;
	if (flags.x != 0) ff_light(e, n, v, d0, d1);
	o_d0 = d0; o_d1 = d1;
	float fd = fog.y != 0 ? length(e) : e.z, fe = fog_param.z * fd;
	o_fog = vec4(fog.x == 0 ? d1.a : fog.x == 1 ? exp(-fe) : fog.x == 2 ? exp(-fe * fe) : (fog_param.y - fd) / (fog_param.y - fog_param.x));
	vec4 tout[8] = vec4[8](v_t0, v_t1, v_t2, v_t3, v_t4, v_t5, v_t6, v_t7);
	for (int s = 0; s < 8; s++) {
		ivec4 c = tc[s];
		if (c.x < 0) continue;
		vec4 t = c.y == 1 ? vec4(n, 1.0) : c.y == 2 ? vec4(e, 1.0) : c.y == 3 ? vec4(reflect(-v, n), 1.0) : tin[c.x];
		if (c.z != 0) t = tex[s] * t;
		tout[c.x] = t;
	}
	o_t0 = tout[0]; o_t1 = tout[1]; o_t2 = tout[2]; o_t3 = tout[3];
	o_t4 = tout[4]; o_t5 = tout[5]; o_t6 = tout[6]; o_t7 = tout[7];
}
`

// Texture transforms see the coordinate padded as D3D does: the first
// missing component 1, the rest 0, so (u, v) is (u, v, 1, 0) and a 2D
// translation sits in the matrix's third row.
glsl_ffvs_tl :: proc(h: ^strings.Builder, key: u32) {
	PAD := [4]string{"vec4(%s.x, 1.0, 0.0, 0.0)", "vec4(%s.xy, 1.0, 0.0)", "vec4(%s.xyz, 1.0)", "%s"}
	strings.write_string(h, "vec4 tin[8];\n")
	// global initializers cannot read inputs, so main fills tin first
	body := GLSL_FFVS_TL
	cut := strings.index(body, "void main() {\n")
	assert(cut > 0)
	strings.write_string(h, body[:cut + len("void main() {\n")])
	for i in 0 ..< u32(FFVS_TC) {
		// an absent set keeps the (0, 0, 0, 1) default
		dim := key & (1 << (FFVS_LOC_T0 + i)) != 0 ? (key >> (FFVS_KEY_DIM + 2 * i)) & 3 : 3
		fmt.sbprintf(h, "\ttin[%d] = ", i)
		fmt.sbprintf(h, PAD[dim], fmt.tprintf("v_t%d", i))
		strings.write_string(h, ";\n")
	}
	strings.write_string(h, body[cut + len("void main() {\n"):])
}
