// Per-pixel lighting (JE_PPL): the game lights in its vertex shaders and
// interpolates the result as oD0. For a lit vertex shader, the instructions
// only oD0 depends on are run again in the pixel stage, on interpolated copies
// of the values they read from the rest of the shader, so the result matches
// the vertex shader at every vertex and is evaluated per pixel between them.
// WHY: docs/rendering.md §18
package win32

import "core:fmt"
import "core:slice"
import "core:strings"

ppl_on := true // JE_PPL; 0 = off

PPL_LOC :: 11 // first varying location of the cut values
PPL_SLOTS :: 12

// One cut value: register (reg, num) as it stands before instruction at.
Ppl_Cut :: struct {
	reg: Reg,
	num: u16,
	at:  i32, // first instruction that reads it: the vertex stage copies it out there
}

// A point where the pixel stage reloads the components mask of cut slot from
// its varying: those defined outside the rerun part.
Ppl_Load :: struct {
	at:   i32,
	slot: u8,
	mask: u8,
}

Ppl :: struct {
	done:  bool, // analysed
	ok:    bool, // per-pixel lighting applies
	run:   []bool, // per instruction: rerun in the pixel stage
	cuts:  []Ppl_Cut,
	loads: []Ppl_Load,
}

PPL_REGS :: 32

// Components of src k of ins read for destination mask m, as a mask over the
// source register's own components (after the swizzle).
ppl_reads :: proc(ins: ^Sh_Insn, k: int, m: u8) -> (r: u8) {
	sw := ins.src[k].swz
	use: u8
	#partial switch ins.op {
	case .MOV, .ADD, .SUB, .MUL, .MAD, .MIN, .MAX, .SLT, .SGE, .FRC, .ABS, .LRP, .CMP, .CND, .SGN, .MOVA:
		use = m == 0 ? 0xf : m
	case .DP3, .CRS: use = 0x7
	case .RCP, .RSQ, .EXP, .LOG, .POW, .SINCOS: use = 0x8
	case: use = 0xf
	}
	for c in u8(0) ..< 4 {
		if use & (1 << c) != 0 {r |= 1 << ((sw >> (2 * c)) & 3)}
	}
	return
}

// Registers tracked by the slices: everything but constants and samplers.
ppl_tracked :: proc(p: Sh_Param) -> bool {
	return p.reg != .CONST && p.reg != .SAMPLER && int(p.num) < PPL_REGS
}

// Marks in `in` the instructions the needed register components depend on.
ppl_slice :: proc(insns: []Sh_Insn, need: ^[Reg][PPL_REGS]u8, in_slice: []bool) {
	for i := len(insns) - 1; i >= 0; i -= 1 {
		ins := &insns[i]
		d := ins.dst
		if !ins.has_dst || ins.op == .DCL || ins.op == .DEF || !ppl_tracked(d) {continue}
		m := d.mask == 0 ? 0xf : d.mask
		if need[d.reg][d.num] & m == 0 {continue}
		in_slice[i] = true
		need[d.reg][d.num] &~= m
		for k in 0 ..< int(ins.nsrc) {
			s := ins.src[k]
			if s.rel {need[.ADDR][0] |= 1 << s.rel_c}
			if ppl_tracked(s) {need[s.reg][s.num] |= ppl_reads(ins, k, m)}
		}
	}
}

// The split of vertex shader s, or ok false when it has nothing to gain or
// cannot be split: no lighting math, relative addressing or a0 in the part to
// rerun, or more cut values than varyings.
ppl_analyse :: proc(s: ^Shader) -> (p: Ppl) {
	p.done = true
	insns := s.prog.insns[:]
	n := len(insns)
	S, O := make([]bool, n, context.temp_allocator), make([]bool, n, context.temp_allocator)
	need: [Reg][PPL_REGS]u8
	need[.ATTROUT][0] = 0xf
	ppl_slice(insns, &need, S)
	need = {}
	for i in 0 ..< 3 {need[.RASTOUT][i] = 0xf}
	need[.ATTROUT][1] = 0xf
	for i in 0 ..< 8 {need[.TEXCRDOUT][i] = 0xf}
	ppl_slice(insns, &need, O)
	lit := false
	for i in 0 ..< n {
		S[i] = S[i] && !O[i]
		if !S[i] {continue}
		ins := &insns[i]
		#partial switch ins.op {
		case .LIT, .RSQ, .NRM, .POW, .RCP: lit = true
		}
		if ins.dst.reg == .ADDR {return}
		for k in 0 ..< int(ins.nsrc) {
			if ins.src[k].rel || ins.src[k].reg == .ADDR {return}
		}
	}
	if !lit {return}
	// Forward: each read in the rerun part whose reaching definition lies
	// outside it is a cut, keyed by the register and the definitions of all
	// four components, so one varying serves every read of the same value.
	Key :: struct {
		reg:  Reg,
		num:  u16,
		defs: [4]i32,
	}
	def: [Reg][PPL_REGS][4]i32
	for &r in def {for &x in r {x = {-1, -1, -1, -1}}}
	slots := make(map[Key]u8, context.temp_allocator)
	cuts := make([dynamic]Ppl_Cut)
	loads := make([dynamic]Ppl_Load)
	for i in 0 ..< n {
		ins := &insns[i]
		if S[i] {
			m := ins.dst.mask == 0 ? 0xf : ins.dst.mask
			for k in 0 ..< int(ins.nsrc) {
				sp := ins.src[k]
				if !ppl_tracked(sp) {continue}
				rd := ppl_reads(ins, k, m)
				d := def[sp.reg][sp.num]
				outside: u8
				for c in 0 ..< 4 {
					if d[c] < 0 || !S[d[c]] {outside |= 1 << u8(c)}
				}
				if rd & outside == 0 {continue}
				key := Key{sp.reg, sp.num, d}
				slot, seen := slots[key]
				if !seen {
					if len(cuts) == PPL_SLOTS {
						delete(cuts)
						delete(loads)
						return
					}
					slot = u8(len(cuts))
					slots[key] = slot
					append(&cuts, Ppl_Cut{sp.reg, sp.num, i32(i)})
				}
				append(&loads, Ppl_Load{i32(i), slot, outside})
			}
		}
		if ins.has_dst && ins.op != .DCL && ins.op != .DEF && ppl_tracked(ins.dst) {
			m := ins.dst.mask == 0 ? 0xf : ins.dst.mask
			for c in 0 ..< 4 {
				if m & (1 << u8(c)) != 0 {def[ins.dst.reg][ins.dst.num][c] = i32(i)}
			}
		}
	}
	p.ok, p.run, p.cuts, p.loads = true, slice.clone(S), cuts[:], loads[:]
	return
}

// The split of vertex shader id, analysed on first use.
ppl_of :: proc(id: u32) -> ^Ppl {
	s := &shaders[id]
	if !s.ppl.done {s.ppl = ppl_analyse(s)}
	return &s.ppl
}

// Copies (vertex stage) or reloads (pixel stage) the cut values due before
// instruction i.
ppl_cut_code :: proc(g: ^Gen, i: int) {
	p := g.ppl
	if g.ppl_px {
		for l in p.loads {
			if int(l.at) != i {continue}
			c := p.cuts[l.slot]
			m := mask_str(l.mask)
			fmt.sbprintf(&g.sb, "\t%s%s = i_p%d%s;\n", reg_name(g, {reg = c.reg, num = c.num}), m, l.slot, m)
		}
		return
	}
	for c, k in p.cuts {
		if int(c.at) == i {fmt.sbprintf(&g.sb, "\to_p%d = %s;\n", k, reg_name(g, {reg = c.reg, num = c.num}))}
	}
}

// Vertex stage outputs of the cut values of p.
ppl_vs_decl :: proc(h: ^strings.Builder, p: ^Ppl) {
	for _, k in p.cuts {fmt.sbprintf(h, "layout(location = %d) out vec4 o_p%d;\n", PPL_LOC + k, k)}
}

// Pixel stage declarations for rerunning vertex shader vs (under its variant
// key vs_key): the vertex constant block, the cut inputs and ppl_d0(), which
// returns oD0 as the vertex shader computes it.
ppl_ps_decl :: proc(h: ^strings.Builder, vs_id, vs_key: u32) {
	s := &shaders[vs_id]
	p := ppl_of(vs_id)
	g := Gen{sh = &s.prog, key = vs_key, cregs = s.cregs, cn = vs_key >> 16, ppl = p, ppl_px = true}
	gen_scan(&g)
	strings.builder_init(&g.sb, context.temp_allocator)
	gen_body(&g)
	const_block(h, &g)
	for _, k in p.cuts {fmt.sbprintf(h, "layout(location = %d) in vec4 i_p%d;\n", PPL_LOC + k, k)}
	strings.write_string(h, "vec4 ppl_d0() {\n")
	strings.write_string(h, "\tvec4 r0 = vec4(0.0), r1 = r0, r2 = r0, r3 = r0, r4 = r0, r5 = r0, r6 = r0, r7 = r0, r8 = r0, r9 = r0, r10 = r0, r11 = r0, q0, q1;\n")
	strings.write_string(h, "\tvec4 v0 = r0, v1 = r0, v2 = r0, v3 = r0, v4 = r0, v5 = r0, v6 = r0, v7 = r0, v8 = r0, v9 = r0, v10 = r0, v11 = r0, v12 = r0, v13 = r0, v14 = r0, v15 = r0;\n")
	strings.write_string(h, "\tivec4 a0 = ivec4(0);\n\tvec4 opos = vec4(0.0), ofog = vec4(0.0), opts = vec4(1.0), od0 = vec4(0.0), od1 = vec4(0.0);\n")
	strings.write_string(h, "\tvec4 ot0 = vec4(0.0), ot1 = ot0, ot2 = ot0, ot3 = ot0, ot4 = ot0, ot5 = ot0, ot6 = ot0, ot7 = ot0;\n")
	strings.write_string(h, strings.to_string(g.sb))
	strings.write_string(h, "\treturn od0;\n}\n")
}

// The vertex shader id + 1 whose lighting the pixel stage of this draw reruns,
// 0 for none: vs_id is a programmable vertex shader (not fixed function).
ppl_draw :: proc(vs_id: u32) -> u32 {
	if !ppl_on {return 0}
	return ppl_of(vs_id).ok ? vs_id + 1 : 0
}
