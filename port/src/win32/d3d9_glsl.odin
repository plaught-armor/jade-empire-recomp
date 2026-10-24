// D3D9 shader bytecode -> GLSL 4.60 separable programs.
//
// Interface between stages (by location): 0 = oD0/v0, 1 = oD1/v1,
// 2 + n = oTn/tn, 10 = oFog. Vertex inputs sit at location = v# register.
// Constants live in std140 blocks: binding 0 vertex, 1 pixel, 2 the
// pipeline state D3D9 applies outside the shaders (Misc).
//
// Clip control is UPPER_LEFT / ZERO_TO_ONE, so D3D clip space is used as
// is; the vertex epilogue only applies D3D9's half-pixel offset (pixel
// centers at integers): x += w / vp_w, y -= w / vp_h.
//
// Pixel epilogue (shader models below 3 leave these to the pipeline): fog,
// then the alpha test at D3D's 8-bit precision.
package win32

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import gl "vendor:OpenGL"
import "../x86"

Samp_Type :: enum u8 {TEX2D, CUBE, VOLUME}

// ps_1_x variant key: bits 2s..2s+1 = Samp_Type of stage s, bits 8+2s..9+2s
// = projection divisor of stage s (0 none, 1 = z, 2 = w).
PS1_STAGES :: 4

Gen :: struct {
	sb:     strings.Builder,
	sh:     ^Sh_Prog,
	key:    u32,
	cregs:  []u8, // Shader.cregs: the packed constant block, unless cn
	cn:     u32, // relative constant reads: the block is c0 .. c(cn-1)
	defs:   [256]bool,
	lits:   [256][4]u32,
	samp:   [16]i8, // Samp_Type per sampler used, -1 unused
	ncolor: u32, // color outputs written (ps_2_x MRT)
	depth:  bool,
	pts:    bool,
	ppl:    ^Ppl, // per-pixel lighting split of this vertex shader (d3d9_ppl.odin)
	ppl_px: bool, // emitting its rerun part for the pixel stage, else the vertex stage
}

SWZ := "xyzw"

GLSL_COMMON :: `#version 460 core
layout(std140, binding = 2) uniform MISC {
	vec4 pos_fix;   // half-pixel offset per clip w: (1/vp_w, -1/vp_h) / scale
	vec4 fog_color;
	vec4 fog_param; // start, end, density, 1 = table fog on eye w
	ivec4 mode;     // fog kind (0 off, 1 vertex, 2 linear, 3 exp, 4 exp2), alpha func, alpha ref, coverage samples (0 = alpha test)
	vec4 tf;        // fixed-function pixel: TEXTUREFACTOR
	vec4 sc[8];     // per-stage D3DTSS_CONSTANT
	vec4 bump[8];   // per-stage BUMPENVMAT00, 01, 10, 11
	vec4 bump_l[8]; // per-stage BUMPENVLSCALE, BUMPENVLOFFSET
	vec4 vp;        // viewport x, y, 2/w, 2/h (pretransformed vertices)
	vec4 vp_z;      // viewport min_z, 1/(max_z - min_z); z: GL pixels per D3D pixel
	vec4 soft;      // soft particles: A, B of z_ndc = A + B / w, 1 / fade range
};
vec4 d3d_lit(vec4 s) {
	vec4 d = vec4(1.0, 0.0, 0.0, 1.0);
	if (s.x > 0.0) {
		d.y = s.x;
		if (s.y > 0.0) d.z = pow(s.y, clamp(s.w, -128.0, 128.0));
	}
	return d;
}
vec4 d3d_nrm(vec4 s) { return s * inversesqrt(dot(s.xyz, s.xyz)); }
`

reg_name :: proc(g: ^Gen, p: Sh_Param) -> string {
	n := u32(p.num)
	ps := g.sh.ps
	#partial switch p.reg {
	case .TEMP: return fmt.tprintf("r%d", n)
	case .INPUT: return fmt.tprintf("v%d", n)
	case .CONST:
		bank := ps ? "pc" : "vc"
		if p.rel {
			return fmt.tprintf("%s_rel(a0.%s + %d)", bank, SWZ[p.rel_c:p.rel_c + 1], n)
		}
		if n < 256 && g.defs[n] {
			l := g.lits[n]
			v := fmt.tprintf("vec4(uintBitsToFloat(uvec4(%du, %du, %du, %du)))", l[0], l[1], l[2], l[3])
			// ps_1_x constants are clamped to [-1, 1]
			return ps && g.sh.major == 1 ? fmt.tprintf("clamp(%s, -1.0, 1.0)", v) : v
		}
		if g.cn == 0 {n = u32(slice.binary_search(g.cregs, u8(n)) or_else 0)}
		return fmt.tprintf("%s[%d]", bank, n)
	case .ADDR: return ps ? fmt.tprintf("t%d", n) : "vec4(a0)"
	case .RASTOUT:
		RAST := [3]string{"opos", "ofog", "opts"}
		if n < 3 {return RAST[n]}
	case .ATTROUT: return fmt.tprintf("od%d", n)
	case .TEXCRDOUT: return fmt.tprintf("ot%d", n)
	case .COLOROUT: return fmt.tprintf("oc%d", n)
	case .DEPTHOUT: return "odepth"
	case .SAMPLER: return fmt.tprintf("s%d", n)
	}
	x86.fatal("d3d9 glsl: unsupported register %v%d", p.reg, n)
}

src :: proc(g: ^Gen, p: Sh_Param) -> string {
	b := reg_name(g, p)
	if p.swz != 0xe4 {
		s := p.swz
		b = fmt.tprintf("%s.%s%s%s%s", b, SWZ[s & 3:][:1], SWZ[s >> 2 & 3:][:1], SWZ[s >> 4 & 3:][:1], SWZ[s >> 6:][:1])
	}
	#partial switch Src_Mod(p.mod) {
	case .NONE: return b
	case .NEG: return fmt.tprintf("(-%s)", b)
	case .BIAS: return fmt.tprintf("(%s - 0.5)", b)
	case .BIASNEG: return fmt.tprintf("(0.5 - %s)", b)
	case .SIGN: return fmt.tprintf("(2.0 * %s - 1.0)", b)
	case .SIGNNEG: return fmt.tprintf("(1.0 - 2.0 * %s)", b)
	case .COMP: return fmt.tprintf("(1.0 - %s)", b)
	case .X2: return fmt.tprintf("(2.0 * %s)", b)
	case .X2NEG: return fmt.tprintf("(-2.0 * %s)", b)
	case .DZ: return fmt.tprintf("(%s / %s.z)", b, b)
	case .DW: return fmt.tprintf("(%s / %s.w)", b, b)
	case .ABS: return fmt.tprintf("abs(%s)", b)
	case .ABSNEG: return fmt.tprintf("(-abs(%s))", b)
	}
	x86.fatal("d3d9 glsl: unsupported source modifier %d", p.mod)
}

mask_str :: proc(m: u8) -> string {
	if m == 0xf || m == 0 {return ""}
	s := "."
	for c in u8(0) ..< 4 {
		if m & (1 << c) != 0 {s = fmt.tprintf("%s%s", s, SWZ[c:c + 1])}
	}
	return s
}

// Writes e to the destination through its shift, saturate and write mask.
assign :: proc(g: ^Gen, d: Sh_Param, e: string) {
	v := e
	SCALE := [16]string{"", "2.0", "4.0", "8.0", "", "", "", "", "", "", "", "", "", "0.125", "0.25", "0.5"}
	if d.shift != 0 {
		v = fmt.tprintf("(%s) * %s", v, SCALE[u8(d.shift) & 0xf])
	}
	if d.mod & 1 != 0 {
		v = fmt.tprintf("clamp(%s, 0.0, 1.0)", v)
	}
	m := mask_str(d.mask)
	if d.reg == .ADDR && !g.sh.ps {
		fmt.sbprintf(&g.sb, "\ta0%s = ivec4(%s)%s;\n", m, v, m)
		return
	}
	if d.reg == .COLOROUT {g.ncolor = max(g.ncolor, u32(d.num) + 1)}
	if d.reg == .DEPTHOUT {g.depth = true}
	if d.reg == .RASTOUT && d.num == 2 {g.pts = true}
	fmt.sbprintf(&g.sb, "\t%s%s = (%s)%s;\n", reg_name(g, d), m, v, m)
}

// Arithmetic instructions as one vec4 expression; "" for anything else.
expr :: proc(g: ^Gen, ins: ^Sh_Insn) -> string {
	s: [4]string
	for i in 0 ..< ins.nsrc {s[i] = src(g, ins.src[i])}
	t := fmt.tprintf
	#partial switch ins.op {
	case .MOV: return s[0]
	case .ADD: return t("%s + %s", s[0], s[1])
	case .SUB: return t("%s - %s", s[0], s[1])
	case .MUL: return t("%s * %s", s[0], s[1])
	case .MAD: return t("%s * %s + %s", s[0], s[1], s[2])
	case .RCP: return t("vec4(1.0 / %s.w)", s[0])
	case .RSQ: return t("vec4(inversesqrt(abs(%s.w)))", s[0])
	case .DP3: return t("vec4(dot(%s.xyz, %s.xyz))", s[0], s[1])
	case .DP4: return t("vec4(dot(%s, %s))", s[0], s[1])
	case .MIN: return t("min(%s, %s)", s[0], s[1])
	case .MAX: return t("max(%s, %s)", s[0], s[1])
	case .SLT: return t("vec4(lessThan(%s, %s))", s[0], s[1])
	case .SGE: return t("vec4(greaterThanEqual(%s, %s))", s[0], s[1])
	case .EXP: return t("vec4(exp2(%s.w))", s[0])
	case .LOG: return t("vec4(log2(abs(%s.w)))", s[0])
	case .LIT: return t("d3d_lit(%s)", s[0])
	case .DST: return t("vec4(1.0, %s.y * %s.y, %s.z, %s.w)", s[0], s[1], s[0], s[1])
	case .LRP: return t("mix(%s, %s, %s)", s[2], s[1], s[0])
	case .FRC: return t("fract(%s)", s[0])
	case .POW: return t("vec4(pow(abs(%s.w), %s.w))", s[0], s[1])
	case .CRS: return t("vec4(cross(%s.xyz, %s.xyz), 0.0)", s[0], s[1])
	case .ABS: return t("abs(%s)", s[0])
	case .NRM: return t("d3d_nrm(%s)", s[0])
	case .SGN: return t("sign(%s)", s[0])
	case .SINCOS: return t("vec4(cos(%s.w), sin(%s.w), 0.0, 0.0)", s[0], s[0])
	case .CMP: return t("mix(%s, %s, greaterThanEqual(%s, vec4(0.0)))", s[2], s[1], s[0])
	case .CND: return t("mix(%s, %s, greaterThan(%s, vec4(0.5)))", s[2], s[1], s[0])
	case .DP2ADD: return t("vec4(dot(%s.xy, %s.xy) + %s.x)", s[0], s[1], s[2])
	}
	return ""
}

// Sampling call for sampler n at coordinates c (a vec4 expression).
sample :: proc(g: ^Gen, n: u32, c: string, proj: u32 = 0, bias := false) -> string {
	ty := Samp_Type(g.samp[n])
	if g.sh.major == 1 {
		ty = Samp_Type((g.key >> (2 * n)) & 3)
		g.samp[n] = i8(ty)
	} else if n >= 16 || g.samp[n] < 0 {
		x86.fatal("d3d9 glsl: sampler s%d used without dcl", n)
	}
	dim := ty == .TEX2D ? "xy" : "xyz"
	switch {
	case proj == 1 && ty == .TEX2D: return fmt.tprintf("texture(s%d, (%s).xy / (%s).z)", n, c, c)
	case proj != 0: return fmt.tprintf("texture(s%d, (%s).%s / (%s).w)", n, c, dim, c)
	case bias: return fmt.tprintf("texture(s%d, (%s).%s, (%s).w)", n, c, dim, c)
	}
	return fmt.tprintf("texture(s%d, (%s).%s)", n, c, dim)
}

// ps_1_x texture-addressing instructions; dst is always t#.
gen_tex1 :: proc(g: ^Gen, ins: ^Sh_Insn) {
	n := u32(ins.dst.num)
	b := &g.sb
	s0 := ins.nsrc > 0 ? src(g, ins.src[0]) : ""
	#partial switch ins.op {
	case .TEX:
		fmt.sbprintf(b, "\tt%d = %s;\n", n, sample(g, n, fmt.tprintf("i_t%d", n), (g.key >> (8 + 2 * n)) & 3))
	case .TEXCOORD: fmt.sbprintf(b, "\tt%d = vec4(clamp(i_t%d.xyz, 0.0, 1.0), 1.0);\n", n, n)
	case .TEXKILL: fmt.sbprintf(b, "\tif (any(lessThan(i_t%d.xyz, vec3(0.0)))) discard;\n", n)
	case .TEXREG2AR: fmt.sbprintf(b, "\tt%d = %s;\n", n, sample(g, n, fmt.tprintf("%s.wxzz", s0)))
	case .TEXREG2GB: fmt.sbprintf(b, "\tt%d = %s;\n", n, sample(g, n, fmt.tprintf("%s.yzzz", s0)))
	case .TEXM3x2PAD, .TEXM3x3PAD: fmt.sbprintf(b, "\tfloat m%d = dot(i_t%d.xyz, %s.xyz);\n", n, n, s0)
	case .TEXM3x2TEX:
		c := fmt.tprintf("vec4(m%d, dot(i_t%d.xyz, %s.xyz), 0.0, 1.0)", n - 1, n, s0)
		fmt.sbprintf(b, "\tt%d = %s;\n", n, sample(g, n, c))
	case .TEXM3x3TEX:
		c := fmt.tprintf("vec4(m%d, m%d, dot(i_t%d.xyz, %s.xyz), 1.0)", n - 2, n - 1, n, s0)
		fmt.sbprintf(b, "\tt%d = %s;\n", n, sample(g, n, c))
	case .TEXM3x3VSPEC, .TEXM3x3SPEC:
		fmt.sbprintf(b, "\t{{ vec3 n = vec3(m%d, m%d, dot(i_t%d.xyz, %s.xyz));\n", n - 2, n - 1, n, s0)
		if ins.op == .TEXM3x3VSPEC {
			fmt.sbprintf(b, "\tvec3 e = vec3(i_t%d.w, i_t%d.w, i_t%d.w);\n", n - 2, n - 1, n)
		} else {
			fmt.sbprintf(b, "\tvec3 e = %s.xyz;\n", src(g, ins.src[1]))
		}
		c := "vec4(2.0 * dot(n, e) / dot(n, n) * n - e, 1.0)"
		fmt.sbprintf(b, "\tt%d = %s; }}\n", n, sample(g, n, c))
	case: x86.fatal("d3d9 glsl: unsupported ps_1 instruction %v", ins.op)
	}
}

gen_insn :: proc(g: ^Gen, ins: ^Sh_Insn) {
	#partial switch ins.op {
	case .DCL, .DEF, .DEFI, .DEFB, .NOP: return
	case .MOV, .MOVA:
		if ins.dst.reg == .ADDR && !g.sh.ps {
			// vs_1_1 mov to a0 rounds down; mova rounds to nearest
			f := ins.op == .MOVA ? "floor(%s + 0.5)" : "floor(%s)"
			assign(g, ins.dst, fmt.tprintf(f, src(g, ins.src[0])))
			return
		}
	case .TEX:
		if g.sh.major >= 2 {
			c, n := src(g, ins.src[0]), u32(ins.src[1].num)
			assign(g, ins.dst, sample(g, n, c, ins.ctl & 1 != 0 ? 2 : 0, ins.ctl & 2 != 0))
			return
		}
		gen_tex1(g, ins)
		return
	case .TEXKILL:
		if g.sh.major >= 2 {
			fmt.sbprintf(&g.sb, "\tif (any(lessThan(%s.xyz, vec3(0.0)))) discard;\n", reg_name(g, ins.dst))
			return
		}
		gen_tex1(g, ins)
		return
	case .TEXCOORD, .TEXREG2AR, .TEXREG2GB, .TEXM3x2PAD, .TEXM3x2TEX, .TEXM3x3PAD, .TEXM3x3TEX,
	     .TEXM3x3SPEC, .TEXM3x3VSPEC:
		gen_tex1(g, ins)
		return
	}
	e := expr(g, ins)
	if e == "" {
		x86.fatal("d3d9 glsl: unsupported instruction %v (%s %d.%d)", ins.op, g.sh.ps ? "ps" : "vs", g.sh.major, g.sh.minor)
	}
	assign(g, ins.dst, e)
}

// Literal constants and sampler declarations, gathered before the body.
gen_scan :: proc(g: ^Gen) {
	for &s in g.samp {s = -1}
	for &ins in g.sh.insns {
		#partial switch ins.op {
		case .DEF:
			if n := u32(ins.dst.num); n < 256 {
				g.defs[n] = true
				g.lits[n] = {ins.extra[0], ins.extra[1], ins.extra[2], ins.extra[3]}
			}
		case .DEFI, .DEFB: x86.fatal("d3d9 glsl: integer/bool constants unsupported")
		case .DCL:
			if ins.dst.reg == .SAMPLER {
				// D3DSAMPLER_TEXTURE_TYPE: 2 = 2D, 3 = cube, 4 = volume
				ty := (ins.extra[0] >> 27) & 0xf
				if ty < 2 || ty > 4 || ins.dst.num >= 16 {x86.fatal("d3d9 glsl: bad sampler dcl %08x", ins.extra[0])}
				g.samp[ins.dst.num] = i8(ty - 2)
			}
		}
	}
}

gen_body :: proc(g: ^Gen) {
	insns := g.sh.insns[:]
	for i := 0; i < len(insns); i += 1 {
		ins := &insns[i]
		if g.ppl != nil {
			if g.ppl_px && !g.ppl.run[i] {continue}
			ppl_cut_code(g, i)
		}
		if i + 1 < len(insns) && insns[i + 1].coissue {
			// co-issued pair: both read their sources before either writes
			nx := &insns[i + 1]
			e0, e1 := expr(g, ins), expr(g, nx)
			if e0 == "" || e1 == "" {x86.fatal("d3d9 glsl: bad co-issue %v + %v", ins.op, nx.op)}
			fmt.sbprintf(&g.sb, "\tq0 = %s;\n\tq1 = %s;\n", e0, e1)
			assign(g, ins.dst, "q0")
			assign(g, nx.dst, "q1")
			i += 1
			continue
		}
		gen_insn(g, ins)
	}
}

// The packed constant block (vertex vc, binding 0; pixel pc, binding 1): the
// shader's cregs in order, or with relative reads the prefix c0 .. c(cn-1)
// and vc_rel/pc_rel, which reads 0 past it as D3D does past every register
// written (const_hw). None when the shader reads no constant register.
// WHY: docs/rendering.md §7
const_block :: proc(h: ^strings.Builder, g: ^Gen) {
	ps := g.sh.ps
	bank := ps ? "pc" : "vc"
	n := g.cn != 0 ? g.cn : u32(len(g.cregs))
	if n == 0 {return}
	fmt.sbprintf(h, "layout(std140, binding = %d) uniform %s {{ vec4 %s[%d]; }};\n", int(ps), ps ? "PSC" : "VSC", bank, n)
	if g.cn != 0 {
		top := ps ? PS_F_MAX - 1 : VS_F_MAX - 1
		fmt.sbprintf(h, "vec4 %s_rel(int i) {{ i = clamp(i, 0, %d); return i < %d ? %s[i] : vec4(0.0); }}\n", bank, top, n, bank)
	}
}

// Vertex variant key: const_key bits, and bit 0 = copy out the per-pixel
// lighting cut values.
glsl_vs :: proc(s: ^Shader, key: u32) -> string {
	sh := &s.prog
	g := Gen{sh = sh, key = key, cregs = s.cregs, cn = key >> 16}
	if key & 1 != 0 {g.ppl = &s.ppl}
	gen_scan(&g)
	strings.builder_init(&g.sb, context.temp_allocator)
	gen_body(&g)
	body := strings.to_string(g.sb)
	h := strings.builder_make(context.temp_allocator)
	strings.write_string(&h, GLSL_COMMON)
	const_block(&h, &g)
	strings.write_string(&h, "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n")
	for ins in sh.insns {
		if ins.op == .DCL && ins.dst.reg == .INPUT {
			fmt.sbprintf(&h, "layout(location = %d) in vec4 v%d;\n", ins.dst.num, ins.dst.num)
		}
	}
	strings.write_string(&h, "layout(location = 0) out vec4 o_d0;\nlayout(location = 1) out vec4 o_d1;\n")
	for i in 0 ..< 8 {fmt.sbprintf(&h, "layout(location = %d) out vec4 o_t%d;\n", 2 + i, i)}
	strings.write_string(&h, "layout(location = 10) out vec4 o_fog;\n")
	if g.ppl != nil {ppl_vs_decl(&h, g.ppl)}
	strings.write_string(&h, "void main() {\n")
	strings.write_string(&h, "\tvec4 r0 = vec4(0.0), r1 = r0, r2 = r0, r3 = r0, r4 = r0, r5 = r0, r6 = r0, r7 = r0, r8 = r0, r9 = r0, r10 = r0, r11 = r0, q0, q1;\n")
	strings.write_string(&h, "\tivec4 a0 = ivec4(0);\n\tvec4 opos = vec4(0.0), ofog = vec4(0.0), opts = vec4(1.0), od0 = vec4(0.0), od1 = vec4(0.0);\n")
	strings.write_string(&h, "\tvec4 ot0 = vec4(0.0), ot1 = ot0, ot2 = ot0, ot3 = ot0, ot4 = ot0, ot5 = ot0, ot6 = ot0, ot7 = ot0;\n")
	strings.write_string(&h, body)
	strings.write_string(&h, "\tgl_Position = vec4(opos.xy + opos.w * pos_fix.xy, opos.zw);\n")
	strings.write_string(&h, g.pts ? "\tgl_PointSize = opts.x * vp_z.z;\n" : "\tgl_PointSize = 1.0;\n")
	strings.write_string(&h, "\to_d0 = od0; o_d1 = od1; o_fog = ofog;\n")
	strings.write_string(&h, "\to_t0 = ot0; o_t1 = ot1; o_t2 = ot2; o_t3 = ot3; o_t4 = ot4; o_t5 = ot5; o_t6 = ot6; o_t7 = ot7;\n}\n")
	return strings.to_string(h)
}

GLSL_PS_EPILOGUE :: `	if (mode.x != 0) {
		float f, z = fog_param.w != 0.0 ? 1.0 / gl_FragCoord.w : gl_FragCoord.z;
		if (mode.x == 1) f = i_fog.x;
		else if (mode.x == 2) f = (fog_param.y - z) / (fog_param.y - fog_param.x);
		else if (mode.x == 3) f = exp(-fog_param.z * z);
		else f = exp(-(fog_param.z * z) * (fog_param.z * z));
		col.rgb = mix(fog_color.rgb, col.rgb, clamp(f, 0.0, 1.0));
	}
	gl_SampleMask[0] = -1;
	float aw = fwidth(col.a) * 255.0;
	if (mode.w != 0) {
		// Alpha to coverage: the test's edge, half a step past ref, spread over
		// the samples one pixel of alpha change wide; at least one step wide,
		// so alpha the test fails everywhere still covers nothing.
		float e = float(mode.z) + (mode.y == 5 ? 0.5 : -0.5);
		float c = clamp((clamp(col.a, 0.0, 1.0) * 255.0 - e) / max(aw, 1.0) + 0.5, 0.0, 1.0);
		int k = int(c * float(mode.w) + 0.5);
		if (k == 0) discard;
		gl_SampleMask[0] = (1 << k) - 1;
	} else if (mode.y != 8) {
		int a = int(clamp(col.a, 0.0, 1.0) * 255.0 + 0.5), r = mode.z;
		bool pass = mode.y == 2 ? a < r : mode.y == 3 ? a == r : mode.y == 4 ? a <= r :
			mode.y == 5 ? a > r : mode.y == 6 ? a != r : mode.y == 7 ? a >= r : false;
		if (!pass) discard;
	}
`

// pv: vertex shader id + 1 whose lighting this pixel shader reruns (under its
// variant key pv_key) in place of the interpolated oD0, 0 for none.
glsl_ps :: proc(s: ^Shader, key: u32, pv, pv_key: u32) -> string {
	sh := &s.prog
	g := Gen{sh = sh, key = key, cregs = s.cregs, cn = key >> 16}
	gen_scan(&g)
	strings.builder_init(&g.sb, context.temp_allocator)
	gen_body(&g)
	body := strings.to_string(g.sb)
	sm1 := sh.major == 1
	h := strings.builder_make(context.temp_allocator)
	strings.write_string(&h, GLSL_COMMON)
	const_block(&h, &g)
	STYPE := [Samp_Type]string{.TEX2D = "sampler2D", .CUBE = "samplerCube", .VOLUME = "sampler3D"}
	for ty, i in g.samp {
		if ty >= 0 {fmt.sbprintf(&h, "layout(binding = %d) uniform %s s%d;\n", i, STYPE[Samp_Type(ty)], i)}
	}
	strings.write_string(&h, "layout(location = 0) in vec4 i_d0;\nlayout(location = 1) in vec4 i_d1;\n")
	for i in 0 ..< 8 {fmt.sbprintf(&h, "layout(location = %d) in vec4 i_t%d;\n", 2 + i, i)}
	strings.write_string(&h, "layout(location = 10) in vec4 i_fog;\n")
	nc := sm1 ? 1 : max(g.ncolor, 1)
	for i in 0 ..< nc {fmt.sbprintf(&h, "layout(location = %d) out vec4 frag%d;\n", i, i)}
	if pv != 0 {ppl_ps_decl(&h, pv - 1, pv_key)}
	fmt.sbprintf(&h, "void main() {{\n\tvec4 v0 = clamp(%s, 0.0, 1.0), v1 = clamp(i_d1, 0.0, 1.0);\n", pv != 0 ? "ppl_d0()" : "i_d0")
	strings.write_string(&h, "\tvec4 r0 = vec4(0.0), r1 = r0, r2 = r0, r3 = r0, r4 = r0, r5 = r0, r6 = r0, r7 = r0, r8 = r0, r9 = r0, r10 = r0, r11 = r0, q0, q1;\n")
	strings.write_string(&h, "\tvec4 oc0 = vec4(0.0), oc1 = oc0, oc2 = oc0, oc3 = oc0, odepth = vec4(gl_FragCoord.z);\n")
	if sm1 {
		strings.write_string(&h, "\tvec4 t0 = vec4(0.0), t1 = t0, t2 = t0, t3 = t0;\n")
	} else {
		strings.write_string(&h, "\tvec4 t0 = i_t0, t1 = i_t1, t2 = i_t2, t3 = i_t3, t4 = i_t4, t5 = i_t5, t6 = i_t6, t7 = i_t7;\n")
	}
	strings.write_string(&h, body)
	strings.write_string(&h, sm1 ? "\tvec4 col = r0;\n" : "\tvec4 col = oc0;\n")
	strings.write_string(&h, GLSL_PS_EPILOGUE)
	strings.write_string(&h, "\tfrag0 = col;\n")
	for i in 1 ..< nc {fmt.sbprintf(&h, "\tfrag%d = oc%d;\n", i, i)}
	if g.depth {strings.write_string(&h, "\tgl_FragDepth = odepth.x;\n")}
	strings.write_string(&h, "}\n")
	return strings.to_string(h)
}

glsl_compile :: proc(text: string, ps: bool) -> u32 {
	cs := strings.clone_to_cstring(text, context.temp_allocator)
	prog := gl.CreateShaderProgramv(ps ? gl.FRAGMENT_SHADER : gl.VERTEX_SHADER, 1, &cs)
	ok: i32
	gl.GetProgramiv(prog, gl.LINK_STATUS, &ok)
	if ok == 0 {
		buf: [4096]u8
		n: i32
		gl.GetProgramInfoLog(prog, len(buf), &n, &buf[0])
		fmt.eprintln(text)
		x86.fatal("d3d9 glsl: compile failed: %s", string(buf[:n]))
	}
	return prog
}

shader_dump_dir: string // JE_SHADER_DUMP: write each generated GLSL program here

// The GL program for shader id (index into `shaders`) under variant key; a
// pixel shader reruns the lighting of vertex shader pv - 1 under its key
// pv_key, if pv is not 0 (glsl_ps).
shader_program :: proc(id: u32, key: u32, pv: u32 = 0, pv_key: u32 = 0) -> u32 {
	s := &shaders[id]
	vk := u64(key) | u64(pv) << 32 | u64(pv_key >> 16) << 52
	if p, ok := s.variants[vk]; ok {
		return p
	}
	text := s.prog.ps ? glsl_ps(s, key, pv, pv_key) : glsl_vs(s, key)
	if shader_dump_dir != "" {
		path := fmt.tprintf("%s/%s%03d_%08x_%d.glsl", shader_dump_dir, s.prog.ps ? "ps" : "vs", id, key, pv)
		if os.write_entire_file(path, transmute([]u8)text) != nil {x86.fatal("d3d9 glsl: cannot write %s", path)}
	}
	p := glsl_compile(text, s.prog.ps)
	s.variants[vk] = p
	return p
}
