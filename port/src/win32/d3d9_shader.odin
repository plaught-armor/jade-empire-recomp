// D3D9 shader bytecode (vs_1_1..vs_2_x, ps_1_1..ps_2_x): parsing into a flat
// instruction list, and the shader COM objects. GLSL generation lives in
// d3d9_glsl.odin. Token layouts follow the D3D9 DDK (d3d9types.h D3DSI_*).
package win32

import "../x86"

Sh_Op :: enum u16 {
	NOP = 0, MOV, ADD, SUB, MAD, MUL, RCP, RSQ, DP3, DP4, MIN, MAX, SLT, SGE, EXP, LOG, LIT, DST, LRP, FRC,
	M4x4, M4x3, M3x4, M3x3, M3x2, CALL, CALLNZ, LOOP, RET, ENDLOOP, LABEL, DCL, POW, CRS, SGN, ABS, NRM,
	SINCOS, REP, ENDREP, IF, IFC, ELSE, ENDIF, BREAK, BREAKC, MOVA, DEFB, DEFI,
	TEXCOORD = 64, TEXKILL, TEX, TEXBEM, TEXBEML, TEXREG2AR, TEXREG2GB, TEXM3x2PAD, TEXM3x2TEX,
	TEXM3x3PAD, TEXM3x3TEX, RESERVED0, TEXM3x3SPEC, TEXM3x3VSPEC, EXPP, LOGP, CND, DEF, TEXREG2RGB,
	TEXDP3TEX, TEXM3x2DEPTH, TEXDP3, TEXM3x3, TEXDEPTH, CMP, BEM, DP2ADD, DSX, DSY, TEXLDD, SETP,
	TEXLDL, BREAKP,
	PHASE = 0xfffd, COMMENT = 0xfffe, END = 0xffff,
}

// D3DSHADER_PARAM_REGISTER_TYPE.
Reg :: enum u8 {
	TEMP = 0, INPUT, CONST, ADDR, RASTOUT, ATTROUT, TEXCRDOUT, CONSTINT, COLOROUT, DEPTHOUT, SAMPLER,
	CONST2, CONST3, CONST4, CONSTBOOL, LOOP, TEMPFLOAT16, MISCTYPE, LABEL, PREDICATE,
}
REG_TEXTURE :: Reg.ADDR // ps: t#

// D3DSHADER_PARAM_SRCMOD_TYPE.
Src_Mod :: enum u8 {NONE, NEG, BIAS, BIASNEG, SIGN, SIGNNEG, COMP, X2, X2NEG, DZ, DW, ABS, ABSNEG, NOT}

Sh_Param :: struct {
	reg:   Reg,
	num:   u16,
	mask:  u8, // dst write mask (bit 0 = x)
	swz:   u8, // src swizzle, 2 bits per component, x in bits 0-1
	mod:   u8, // src: Src_Mod; dst: result modifier bits (1 = saturate)
	shift: i8, // dst result shift: scale by 2^shift
	rel:   bool,
	rel_c: u8, // relative addressing: a0 component
}

Sh_Insn :: struct {
	op:      Sh_Op,
	ctl:     u8, // instruction-specific control bits 16-23
	coissue: bool,
	has_dst: bool,
	nsrc:    u8,
	dst:     Sh_Param,
	src:     [4]Sh_Param,
	extra:   [4]u32, // DCL: usage token; DEF/DEFI/DEFB: the literal
}

Sh_Prog :: struct {
	ps:           bool,
	major, minor: u8,
	insns:        [dynamic]Sh_Insn,
	bytecode:     []u32,
}

SH_TOKENS_MAX :: 1 << 16

// Operand shape (has destination, source count) for SM1-style parsing,
// where instruction tokens carry no length.
op_shape :: proc(op: Sh_Op, ps: bool, major, minor: u8) -> (bool, u8) {
	#partial switch op {
	case .NOP, .RET, .ENDLOOP, .ENDREP, .ELSE, .ENDIF, .BREAK, .PHASE: return false, 0
	case .MOV, .RCP, .RSQ, .EXP, .LOG, .LIT, .FRC, .ABS, .NRM, .MOVA, .EXPP, .LOGP, .TEXBEM, .TEXBEML,
	     .TEXREG2AR, .TEXREG2GB, .TEXREG2RGB, .TEXM3x2PAD, .TEXM3x2TEX, .TEXM3x3PAD, .TEXM3x3TEX,
	     .TEXM3x3VSPEC, .TEXDP3TEX, .TEXM3x2DEPTH, .TEXDP3, .TEXM3x3, .DSX, .DSY:
		return true, 1
	case .ADD, .SUB, .MUL, .DP3, .DP4, .MIN, .MAX, .SLT, .SGE, .DST, .M4x4, .M4x3, .M3x4, .M3x3, .M3x2,
	     .POW, .CRS, .TEXM3x3SPEC, .BEM, .SETP:
		return true, 2
	case .MAD, .LRP, .CND, .CMP, .DP2ADD, .SGN:
		return true, 3
	case .SINCOS:
		return true, major >= 3 ? 1 : 3
	case .TEXCOORD:
		return true, major == 1 && minor >= 4 ? 1 : 0
	case .TEX:
		if major >= 2 {return true, 2}
		return true, minor >= 4 ? 1 : 0
	case .TEXKILL, .TEXDEPTH:
		return true, 0
	}
	x86.fatal("d3d9 shader: no operand shape for opcode %d", u16(op))
}

rd_dst :: proc(t: u32) -> Sh_Param {
	return {
		reg = Reg(((t >> 28) & 7) | ((t >> 8) & 0x18)),
		num = u16(t & 0x7ff),
		mask = u8((t >> 16) & 0xf),
		mod = u8((t >> 20) & 0xf),
		shift = i8(u8((t >> 24) & 0xf) << 4) >> 4,
		rel = t & (1 << 13) != 0,
	}
}

rd_src :: proc(t: u32) -> Sh_Param {
	return {
		reg = Reg(((t >> 28) & 7) | ((t >> 8) & 0x18)),
		num = u16(t & 0x7ff),
		swz = u8((t >> 16) & 0xff),
		mod = u8((t >> 24) & 0xf),
		rel = t & (1 << 13) != 0,
	}
}

// Parses the token stream at guest p; returns false on a malformed stream.
sh_parse :: proc(p: u32) -> (sh: Sh_Prog, ok: bool) {
	ver := x86.rd32(p)
	kind := ver >> 16
	if kind != 0xfffe && kind != 0xffff {
		return
	}
	sh.ps, sh.major, sh.minor = kind == 0xffff, u8(ver >> 8), u8(ver)
	i: u32 = 1
	for i < SH_TOKENS_MAX {
		t := x86.rd32(p + i * 4)
		op := Sh_Op(t & 0xffff)
		if op == .END {
			sh.bytecode = make([]u32, i + 1)
			blob_in(p, raw_data(sh.bytecode), (i + 1) * 4)
			return sh, true
		}
		if op == .COMMENT {
			i += 1 + ((t >> 16) & 0x7fff)
			continue
		}
		n, good := sh_insn(&sh, p, i, t)
		if !good {
			return
		}
		i += n
	}
	return
}

// Decodes one instruction at token i; returns its length in tokens.
sh_insn :: proc(sh: ^Sh_Prog, p, i, t: u32) -> (u32, bool) {
	op := Sh_Op(t & 0xffff)
	ins := Sh_Insn{op = op, ctl = u8(t >> 16), coissue = t & (1 << 30) != 0}
	tok :: proc(p, k: u32) -> u32 {return x86.rd32(p + k * 4)}
	k := i + 1
	#partial switch op {
	case .DCL:
		ins.extra[0] = tok(p, k)
		ins.dst, ins.has_dst = rd_dst(tok(p, k + 1)), true
		k += 2
	case .DEF, .DEFI:
		ins.dst, ins.has_dst = rd_dst(tok(p, k)), true
		for j in 0 ..< u32(4) {ins.extra[j] = tok(p, k + 1 + j)}
		k += 5
	case .DEFB:
		ins.dst, ins.has_dst = rd_dst(tok(p, k)), true
		ins.extra[0] = tok(p, k + 1)
		k += 2
	case:
		has_dst, nsrc := op_shape(op, sh.ps, sh.major, sh.minor)
		if has_dst {
			ins.dst, ins.has_dst = rd_dst(tok(p, k)), true
			k += 1
		}
		ins.nsrc = nsrc
		for s in 0 ..< nsrc {
			ins.src[s] = rd_src(tok(p, k))
			k += 1
			if ins.src[s].rel && sh.major >= 2 {
				ins.src[s].rel_c = u8((tok(p, k) >> 16) & 3)
				k += 1
			}
		}
	}
	if sh.major >= 2 && op != .PHASE {
		n := (t >> 24) & 0xf
		if k != i + 1 + n {
			x86.fatal("d3d9 shader: opcode %v length %d, parsed %d", op, n, k - i - 1)
		}
	}
	append(&sh.insns, ins)
	return k - i, true
}

// Shader objects: host id indexes `shaders`; bound by id + 1 (0 = none).
Shader :: struct {
	prog:     Sh_Prog,
	variants: map[u64]u32, // GL separable program per variant key (shader_program)
	cregs:    []u8, // constant registers read by static index, ascending, DEF'd ones excluded: its packed block
	crel:     bool, // reads constants relatively: its block is the prefix c0 .. c(n-1) instead (const_key)
	ppl:      Ppl, // vertex shader: its per-pixel lighting split (d3d9_ppl.odin)
}

shaders: [dynamic]Shader

SHADER_OWN := [?]Com_Method {
	{"QueryInterface", com_query}, {"AddRef", com_addref}, {"Release", com_release},
	{"GetDevice", Res_GetDevice}, {"GetFunction", Shader_GetFunction},
}

shader_create :: proc(ps: bool) {
	sh, ok := sh_parse(arg(1))
	if !ok || sh.ps != ps {
		x86.wr32(arg(2), 0)
		ret(3, D3DERR_INVALIDCALL)
		return
	}
	id := u32(len(shaders))
	cregs, crel := const_layout(&sh)
	append(&shaders, Shader{prog = sh, cregs = cregs, crel = crel})
	vt := com_vtable("d3d9.dll", ps ? "IDirect3DPixelShader9" : "IDirect3DVertexShader9", SHADER_OWN[:])
	x86.wr32(arg(2), com_new(vt, id))
	ret(3, D3D_OK)
}

// The constant registers sh reads by static index, ascending, without the
// DEF'd ones (GLSL literals), and whether it reads any relatively.
// WHY: docs/rendering.md §7
const_layout :: proc(sh: ^Sh_Prog) -> (regs: []u8, rel: bool) {
	bank := sh.ps ? PS_F_MAX : VS_F_MAX
	def, used: [VS_F_MAX]bool
	for &ins in sh.insns {
		if ins.op == .DEF && int(ins.dst.num) < bank {def[ins.dst.num] = true}
		for p in ins.src[:ins.nsrc] {
			if p.reg != .CONST {continue}
			if int(p.num) >= bank {x86.fatal("d3d9: shader reads c%d, past the %d-register bank", p.num, bank)}
			if p.rel {rel = true} else {used[p.num] = true}
		}
	}
	n := 0
	for r in 0 ..< bank {n += int(used[r] && !def[r])}
	regs = make([]u8, n)
	n = 0
	for r in 0 ..< bank {
		if used[r] && !def[r] {
			regs[n] = u8(r)
			n += 1
		}
	}
	return
}

Dev_CreateVertexShader :: proc() {shader_create(false)}
Dev_CreatePixelShader :: proc() {shader_create(true)}

// (this, pData, pSizeOfData): pData 0 queries the size.
Shader_GetFunction :: proc() {
	bc := shaders[com_id(arg(0))].prog.bytecode
	n := u32(len(bc)) * 4
	if arg(1) != 0 {
		if x86.rd32(arg(2)) < n {
			ret(3, D3DERR_INVALIDCALL)
			return
		}
		blob_out(arg(1), raw_data(bc), n)
	}
	x86.wr32(arg(2), n)
	ret(3, D3D_OK)
}

shader_id :: proc(obj: u32) -> u32 {return obj == 0 ? 0 : com_id(obj) + 1}

Dev_SetVertexShader :: proc() {
	bind.vs, bind.vs_obj = shader_id(arg(1)), arg(1)
	ret(2, D3D_OK)
}

Dev_GetVertexShader :: proc() {
	_ = addref_out(arg(1), bind.vs_obj)
	ret(2, D3D_OK)
}

Dev_SetPixelShader :: proc() {
	bind.ps, bind.ps_obj = shader_id(arg(1)), arg(1)
	ret(2, D3D_OK)
}

Dev_GetPixelShader :: proc() {
	_ = addref_out(arg(1), bind.ps_obj)
	ret(2, D3D_OK)
}
