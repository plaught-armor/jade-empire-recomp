// Fixed-function pixel pipeline: the texture stage cascade (D3DTSS_*) as
// generated GLSL, keyed by the state that changes the program. Values that
// only feed it (TFACTOR, per-stage CONSTANT, bump matrices) travel in the
// MISC block. Fed by the same vertex interface as shaders (d3d9_glsl.odin).
//
// Stage s samples sampler s at oT[TEXCOORDINDEX & 7]. A stage reading an
// unbound texture gets (0,0,0,1), the D3D9 value for an empty sampler.
// Every stage result saturates, as on D3D9 fixed-function hardware.
package win32

import "core:fmt"
import "core:strings"

FF_STAGES :: TSS_STAGES

// D3DTEXTUREOP values the generator names.
TOP_DISABLE :: 1
TOP_BUMPENVMAP :: 22
TOP_BUMPENVMAPLUMINANCE :: 23

// D3DTA_*.
TA_SELECT_MASK :: 0xf
TA_COMPLEMENT :: 0x10
TA_ALPHAREPLICATE :: 0x20

Ff_Stage :: struct {
	cop, ca1, ca2, ca0: u8,
	aop, aa1, aa2, aa0: u8,
	res:                u8, // RESULTARG: 1 current, 5 temp
	tci:                u8, // texture coordinate set
	tex:                u8, // 0 unbound, else Samp_Type + 1
	proj:               u8, // projected divide component + 1, 0 none
}

Ff_Key :: struct {
	stage:  [FF_STAGES]Ff_Stage,
	spec:   bool, // SPECULARENABLE: add v1.rgb after the cascade
	soft:   u8, // SOFT_* fade (d3d9_soft.odin)
	pv:     u32, // vertex shader id + 1 whose lighting is rerun per pixel, 0 none (d3d9_ppl.odin)
	pv_key: u32, // its variant key
}

ff_programs: map[Ff_Key]u32

// The key for the current state; stages after the first DISABLE are zero.
ff_key :: proc() -> (k: Ff_Key) {
	k.spec = ds.rs[29] != 0
	k.soft = soft.kind
	for s in 0 ..< u32(FF_STAGES) {
		t := &ds.tss[s]
		if t[1] == TOP_DISABLE {break}
		st := &k.stage[s]
		st.cop, st.ca1, st.ca2, st.ca0 = u8(t[1]), u8(t[2]), u8(t[3]), u8(t[26])
		st.aop, st.aa1, st.aa2, st.aa0 = u8(t[4]), u8(t[5]), u8(t[6]), u8(t[27])
		st.res, st.tci = u8(t[28]), u8(t[11] & 7)
		if obj := bind.tex[s]; obj != 0 {
			st.tex = res_of(obj).kind == .Cube ? u8(Samp_Type.CUBE) + 1 : u8(Samp_Type.TEX2D) + 1
		}
		// D3DTTFF_PROJECTED divides by the last of COUNT coordinates
		if f := t[24]; f & 0x100 != 0 && f & 0xff >= 2 && f & 0xff <= 4 {st.proj = u8(f & 0xff)}
	}
	return
}

ff_program :: proc(pv, pv_key: u32) -> u32 {
	k := ff_key()
	k.pv, k.pv_key = pv, pv != 0 ? pv_key : 0
	if p, ok := ff_programs[k]; ok {return p}
	p := glsl_compile(glsl_ff(&k), true)
	ff_programs[k] = p
	return p
}

// GLSL value of a D3DTA argument at stage s.
ff_arg :: proc(a: u8, s: int) -> string {
	SEL := [7]string{"v0", "cur", "", "tf", "v1", "tmp", ""}
	base: string
	switch a & TA_SELECT_MASK {
	case 2: base = fmt.tprintf("tex%d", s)
	case 6: base = fmt.tprintf("sc[%d]", s)
	case 0 ..= 5: base = SEL[a & TA_SELECT_MASK]
	case: base = "vec4(0.0)"
	}
	if a & TA_ALPHAREPLICATE != 0 {base = fmt.tprintf("%s.aaaa", base)}
	if a & TA_COMPLEMENT != 0 {base = fmt.tprintf("(1.0 - %s)", base)}
	return base
}

// GLSL expression of D3DTEXTUREOP op over arguments a1, a2, a0 at stage s.
ff_op :: proc(op: u8, a1, a2, a0: string, s: int) -> string {
	switch op {
	case 2: return a1
	case 3: return a2
	case 4: return fmt.tprintf("%s * %s", a1, a2)
	case 5: return fmt.tprintf("2.0 * %s * %s", a1, a2)
	case 6: return fmt.tprintf("4.0 * %s * %s", a1, a2)
	case 7: return fmt.tprintf("%s + %s", a1, a2)
	case 8: return fmt.tprintf("%s + %s - 0.5", a1, a2)
	case 9: return fmt.tprintf("2.0 * (%s + %s - 0.5)", a1, a2)
	case 10: return fmt.tprintf("%s - %s", a1, a2)
	case 11: return fmt.tprintf("%s + %s - %s * %s", a1, a2, a1, a2)
	case 12: return fmt.tprintf("mix(%s, %s, v0.a)", a2, a1)
	case 13: return fmt.tprintf("mix(%s, %s, tex%d.a)", a2, a1, s)
	case 14: return fmt.tprintf("mix(%s, %s, tf.a)", a2, a1)
	case 15: return fmt.tprintf("%s + %s * (1.0 - tex%d.a)", a1, a2, s)
	case 16: return fmt.tprintf("mix(%s, %s, cur.a)", a2, a1)
	case 18: return fmt.tprintf("vec4(%s.rgb + %s.a * %s.rgb, 1.0)", a1, a1, a2)
	case 19: return fmt.tprintf("vec4(%s.rgb * %s.rgb + %s.a, 1.0)", a1, a2, a1)
	case 20: return fmt.tprintf("vec4((1.0 - %s.a) * %s.rgb + %s.rgb, 1.0)", a1, a2, a1)
	case 21: return fmt.tprintf("vec4((1.0 - %s.rgb) * %s.rgb + %s.a, 1.0)", a1, a2, a1)
	case 24: return fmt.tprintf("vec4(4.0 * dot(%s.rgb - 0.5, %s.rgb - 0.5))", a1, a2)
	case 25: return fmt.tprintf("%s + %s * %s", a0, a1, a2)
	case 26: return fmt.tprintf("mix(%s, %s, %s)", a2, a1, a0)
	}
	return "cur" // PREMODULATE, bump ops, unknown: pass the current color
}

// Samples stage s into tex<s>, offset by the previous stage's bump output.
ff_sample :: proc(h: ^strings.Builder, k: ^Ff_Key, s: int) {
	st := &k.stage[s]
	if st.tex == 0 {
		fmt.sbprintf(h, "\tvec4 tex%d = vec4(0.0, 0.0, 0.0, 1.0);\n", s)
		return
	}
	c := fmt.tprintf("i_t%d", st.tci)
	if st.proj != 0 {c = fmt.tprintf("(%s / %s.%c)", c, c, SWZ[st.proj - 1])}
	if s > 0 && (k.stage[s - 1].cop == TOP_BUMPENVMAP || k.stage[s - 1].cop == TOP_BUMPENVMAPLUMINANCE) {
		// D3D: (u, v) += [M00 M10; M01 M11] (du, dv) of the bump stage
		b := s - 1
		c = fmt.tprintf("(%s.xy + mat2(bump[%d].xy, bump[%d].zw) * tex%d.xy)", c, b, b, b)
	}
	if Samp_Type(st.tex - 1) == .CUBE {
		fmt.sbprintf(h, "\tvec4 tex%d = texture(s%d, vec4(%s).xyz);\n", s, s, c)
	} else {
		fmt.sbprintf(h, "\tvec4 tex%d = texture(s%d, vec4(%s).xy);\n", s, s, c)
	}
	if s > 0 && k.stage[s - 1].cop == TOP_BUMPENVMAPLUMINANCE {
		b := s - 1
		fmt.sbprintf(h, "\ttex%d.rgb *= clamp(tex%d.z * bump_l[%d].x + bump_l[%d].y, 0.0, 1.0);\n", s, b, b, b)
	}
}

glsl_ff :: proc(k: ^Ff_Key) -> string {
	h := strings.builder_make(context.temp_allocator)
	strings.write_string(&h, GLSL_COMMON)
	STYPE := [Samp_Type]string{.TEX2D = "sampler2D", .CUBE = "samplerCube", .VOLUME = "sampler3D"}
	for st, s in k.stage {
		if st.tex != 0 {fmt.sbprintf(&h, "layout(binding = %d) uniform %s s%d;\n", s, STYPE[Samp_Type(st.tex - 1)], s)}
	}
	if k.soft != SOFT_NONE {fmt.sbprintf(&h, "layout(binding = %d) uniform sampler2D soft_depth;\n", SOFT_UNIT)}
	strings.write_string(&h, "layout(location = 0) in vec4 i_d0;\nlayout(location = 1) in vec4 i_d1;\n")
	for i in 0 ..< 8 {fmt.sbprintf(&h, "layout(location = %d) in vec4 i_t%d;\n", 2 + i, i)}
	strings.write_string(&h, "layout(location = 10) in vec4 i_fog;\nlayout(location = 0) out vec4 frag0;\n")
	if k.pv != 0 {ppl_ps_decl(&h, k.pv - 1, k.pv_key)}
	fmt.sbprintf(&h, "void main() {{\n\tvec4 v0 = clamp(%s, 0.0, 1.0), v1 = clamp(i_d1, 0.0, 1.0);\n", k.pv != 0 ? "ppl_d0()" : "i_d0")
	strings.write_string(&h, "\tvec4 cur = v0, tmp = vec4(0.0), r;\n")
	for s in 0 ..< FF_STAGES {
		st := &k.stage[s]
		if st.cop == 0 {break}
		ff_sample(&h, k, s)
		if st.cop == TOP_BUMPENVMAP || st.cop == TOP_BUMPENVMAPLUMINANCE {continue}
		col := ff_op(st.cop, ff_arg(st.ca1, s), ff_arg(st.ca2, s), ff_arg(st.ca0, s), s)
		alp := ff_op(st.aop, ff_arg(st.aa1, s), ff_arg(st.aa2, s), ff_arg(st.aa0, s), s)
		dst := st.res == 5 ? "tmp" : "cur"
		fmt.sbprintf(&h, "\tr.rgb = (%s).rgb;\n\tr.a = (%s).a;\n\t%s = clamp(r, 0.0, 1.0);\n", col, alp, dst)
	}
	strings.write_string(&h, "\tvec4 col = cur;\n")
	if k.spec {strings.write_string(&h, "\tcol.rgb = clamp(col.rgb + v1.rgb, 0.0, 1.0);\n")}
	strings.write_string(&h, GLSL_PS_EPILOGUE)
	if k.soft != SOFT_NONE {
		strings.write_string(&h, GLSL_SOFT)
		strings.write_string(&h, k.soft == SOFT_ALPHA ? "\t\tcol.a *= k;\n\t}\n" : "\t\tcol *= k;\n\t}\n")
	}
	strings.write_string(&h, "\tfrag0 = col;\n}\n")
	return strings.to_string(h)
}
