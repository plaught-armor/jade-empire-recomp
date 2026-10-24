// Emitter_InterpColorSize (0x630fb0): a particle's color, alpha and two sizes
// at its age, interpolated over the emitter's three keys. WHY: docs/recompiler.md §8
package native

import "core:math"
import "../x86"

guest_emitter_interp: x86.Func

@(private = "file")
EM_ZERO :: 0x006e1848 // 0.0
@(private = "file")
EM_ONE :: 0x006e1910 // 1.0

// Emitter fields, from ecx: per key 0 1 2, alpha at 0x48, size a at 0x54,
// size b at 0x60, key time at 0x6c; colors at 0x78 (key 0), 0x90 (key 1) and
// 0x84 (key 2).
@(private = "file")
EM_LIFE :: 0xc0
@(private = "file")
EM_MODE :: 0x134 // 3: age is the frame argument over EM_FRAMES
@(private = "file")
EM_FRAMES :: 0x1c4

// thiscall(ecx emitter; p: particle, frame: i32, _, col: ^[3]f32, alpha, size_a,
// size_b: ^f32, end: u8), ret 0x20. Age t is frame / [ecx+0x1c4] in mode 3,
// else [p+0x6c] / life; life <= 0 means key 0. Below key time 0 the outputs
// are key 0, between keys 0-1 and 1-2 they are lerps, past key 2 key 2. Size b
// equal to 0 at the keys used means size b takes size a. Color and alpha are
// clamped to [0, 1]. A nonzero end replaces both sizes with key 0's or, when
// [p+0x68] is set, key 2's. An exact replay of the recompiled body: its f64
// operations under the precision control, each load and store in its order,
// so outputs overlapping each other, the emitter, the particle or the frame
// leave what the guest leaves. eax, ecx and edx are dead after the call; the
// recompiled body drops their writes.
Emitter_InterpColorSize_00630fb0 :: proc() {
	c := &x86.cpu
	if mode != .On {
		if mode == .Check {
			esp := c.esp
			// The frame too: the body saves registers below esp and stores a size
			// over the col argument.
			outs := [5]Region{{esp - 16, 13}, {ld(esp + 0x10), 3}, {ld(esp + 0x14), 1}, {ld(esp + 0x18), 1}, {ld(esp + 0x1c), 1}}
			check(0x00630fb0, Emitter_InterpColorSize_00630fb0, guest_emitter_interp, outs[:])
			return
		}
		guest_emitter_interp()
		return
	}
	emitter_interp()
}

// The pointers the body holds in registers, each loaded where the guest loads it.
@(private = "file")
Em_Regs :: struct {
	col, alpha, size_a, size_b: u32, // edx esi ebx edi
}

// A key's color and alpha, copied by mov: col and size a are loaded first,
// size b before the last color dword's store when early.
@(private = "file")
em_copy :: #force_inline proc "contextless" (sp, color, alpha: u32, early: bool) -> (r: Em_Regs) {
	r.size_a = ld(sp + 0x28)
	r.col = ld(sp + 0x20)
	st(r.col, ld(color))
	st(r.col + 4, ld(color + 4))
	z := ld(color + 8)
	if early {r.size_b = ld(sp + 0x2c)}
	st(r.col + 8, z)
	a := ld(alpha)
	r.alpha = ld(sp + 0x24)
	st(r.alpha, a)
	return
}

// fld zero; fld [a]; fucompp: whether [a] is 0, with the compare's bits.
@(private = "file")
em_zero :: #force_inline proc "contextless" (a: u32, cmp: ^u16) -> bool {
	cmp^ = fcom_bits(lx(a), lx(EM_ZERO))
	return cmp^ == C3
}

// A key's size a by fld, stored to size a, and size b: the same value when
// [b] is 0, else [b] by mov.
@(private = "file")
em_sizes :: #force_inline proc "contextless" (r: Em_Regs, a, b: u32, cmp: ^u16) {
	v := lx(a)
	sx(r.size_a, v)
	if em_zero(b, cmp) {
		sx(r.size_b, v)
	} else {
		st(r.size_b, ld(b))
	}
}

// One lerp segment from key time [k] to [k + 4]: the colors at ca and cb, the
// alpha at al (and al + 4), the size a at sa (and sa + 4), size b at sa + 0xc
// (and sa + 0x10).
@(private = "file")
em_lerp :: #force_inline proc "contextless" (s: bool, sp, m: u32, t: f64, k, ca, cb, al, sa: u32, cmp: ^u16) -> (r: Em_Regs) {
	a := round_pc(s, t - lx(m + k))
	r.col = ld(sp + 0x20)
	b := lx(m + k + 4)
	r.alpha = ld(sp + 0x24)
	b = round_pc(s, b - lx(m + k))
	r.size_a = ld(sp + 0x28)
	u := round_pc(s, a / b)
	w := round_pc(s, lx(EM_ONE) - u)
	L :: #force_inline proc "contextless" (s: bool, w, u: f64, x, y: u32) -> f64 {
		p := round_pc(s, w * lx(x))
		return round_pc(s, p + round_pc(s, u * lx(y)))
	}
	sx(r.col, L(s, w, u, m + ca, m + cb))
	sx(r.col + 4, L(s, w, u, m + ca + 4, m + cb + 4))
	sx(r.col + 8, L(s, w, u, m + ca + 8, m + cb + 8))
	sx(r.alpha, L(s, w, u, m + al, m + al + 4))
	v := L(s, w, u, m + sa, m + sa + 4)
	sx(sp + 0x20, v)
	sx(r.size_a, v)
	if em_zero(m + sa + 0xc, cmp) && em_zero(m + sa + 0x10, cmp) {
		r.size_b = ld(sp + 0x2c)
		sx(r.size_b, lx(sp + 0x20))
		return
	}
	r.size_b = ld(sp + 0x2c)
	hi := round_pc(s, u * lx(m + sa + 0x10))
	sx(r.size_b, round_pc(s, hi + round_pc(s, w * lx(m + sa + 0xc))))
	return
}

// fld [a]; below 0 gives 0, above 1 gives 1, else [a] reloaded.
@(private = "file")
em_clamp :: #force_inline proc "contextless" (a: u32, cmp: ^u16) -> f64 {
	cmp^ = fcom_bits(lx(a), lx(EM_ZERO))
	if cmp^ == C0 {return lx(EM_ZERO)}
	cmp^ = fcom_bits(lx(a), lx(EM_ONE))
	return cmp^ == 0 ? lx(EM_ONE) : lx(a)
}

@(private = "file")
emitter_interp :: proc "contextless" () {
	c := &x86.cpu
	e, m := c.esp, c.ecx
	s := c.fpu.cw & x86.PC_MASK == 0
	sp := e - 16 // esp after the four pushes
	cmp := fcom_bits(lx(m + EM_LIFE), lx(EM_ZERO))
	st(e - 4, c.ebx)
	st(e - 8, c.ebp)
	p := ld(e + 4)
	st(e - 12, c.esi)
	st(e - 16, c.edi)
	depth := u32(1) // the deepest the x87 stack goes, for the tags the pops leave
	r: Em_Regs
	if cmp != 0 { 	// life <= 0 or unordered: key 0
		r = em_copy(sp, m + 0x78, m + 0x48, false)
		st(sp + 0x20, ld(m + 0x54))
		sx(r.size_a, lx(sp + 0x20))
		depth = 2
		if em_zero(m + 0x60, &cmp) && em_zero(m + 0x64, &cmp) && em_zero(m + 0x68, &cmp) {
			v := lx(sp + 0x20)
			r.size_b = ld(sp + 0x2c)
			sx(r.size_b, v)
		} else {
			r.size_b = ld(sp + 0x2c)
			st(r.size_b, ld(m + 0x60))
		}
	} else {
		t: f64
		if ld(m + EM_MODE) == 3 {
			t = round_pc(s, f64(i32(ld(sp + 0x18))) / f64(i32(ld(m + EM_FRAMES))))
			depth = 2
		} else {
			t = round_pc(s, lx(p + 0x6c) / lx(m + EM_LIFE))
		}
		if cmp = fcom_bits(t, lx(m + 0x6c)); cmp == C0 { 	// before key 0
			r = em_copy(sp, m + 0x78, m + 0x48, true)
			em_sizes(r, m + 0x54, m + 0x60, &cmp)
			depth = 3
		} else if cmp = fcom_bits(t, lx(m + 0x70)); cmp == C0 { 	// keys 0-1
			r = em_lerp(s, sp, m, t, 0x6c, 0x78, 0x90, 0x48, 0x54, &cmp)
			depth = 4
		} else if cmp = fcom_bits(t, lx(m + 0x74)); cmp == C0 { 	// keys 1-2
			r = em_lerp(s, sp, m, t, 0x70, 0x90, 0x84, 0x4c, 0x58, &cmp)
			depth = 4
		} else { 	// past key 2
			r = em_copy(sp, m + 0x84, m + 0x50, true)
			em_sizes(r, m + 0x5c, m + 0x68, &cmp)
			depth = 3
		}
	}
	sx(r.col, em_clamp(r.col, &cmp))
	sx(r.col + 4, em_clamp(r.col + 4, &cmp))
	sx(r.col + 8, em_clamp(r.col + 8, &cmp))
	v := em_clamp(r.alpha, &cmp)
	end := ld(sp + 0x30) & 0xff
	sx(r.alpha, v)
	if end != 0 {
		k: u32 = ld(p + 0x68) & 0xff != 0 ? 0x5c : 0x54 // key 2 or key 0
		em_sizes(r, m + k, m + k + 0xc, &cmp)
		depth = max(depth, 3)
	}
	c.edi = ld(e - 16)
	c.esi = ld(e - 12)
	c.ebp = ld(e - 8)
	c.ebx = ld(e - 4)
	c.esp = e + 0x24
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | cmp
	c.fpu.tag |= rot8(u8(0xff << (8 - depth)), c.fpu.top)
}

// Emitter_ParticleBasis (0x631670): a particle's two basis vectors. The
// recompiled body leaves fsin and fcos to f64 math.sin and math.cos, rounded
// like any other result, and so does this proc.

guest_emitter_basis: x86.Func

@(private = "file")
EM_KIND :: 0x130 // at ecx: 5 = the particle's own rotation, 4 = facing
EM_CROSS :: 0x005c0c00 // cdecl(out, a, b) -> eax out: a x b
EM_NORMALIZE :: 0x005c0b50 // cdecl(out, v) -> eax out
EM_IS_ZERO :: 0x00402c70 // thiscall(ecx v) -> eax 1 when v is (0, 0, 0)
EM_UP :: 0x0075d0cc // the vector a zero right becomes
EM_RET_CROSS :: 0x0063177c // return addresses of the three calls
EM_RET_NORMALIZE :: 0x00631787
EM_RET_IS_ZERO :: 0x006317a5

// thiscall(ecx emitter; right, up: ^[3]f32, p: particle, dir: ^[3]f32, axis:
// ^[3]f32, rot: ^quat), ret 0x18. Kind 5: the first two columns of the 3x3
// matrix of the particle's quaternion at [p+0x34]. Kind 4: up = dir, right =
// normalize(up x axis), or the vector at EM_UP when that is zero. Otherwise:
// rot's matrix (the particle's quaternion and its axis at [p+0x44] instead when
// [p+0x68] and bit 9 of [[ecx+4]+0x1e4] are set) rotated by the particle's
// angle [p+0x20] about axis, then up = right x axis. Each an exact replay
// (native.odin): f64 operations rounded to the control word's precision, every
// frame and argument slot the recompiled body writes written, in its order.
// Only esp and esi are written back by the recompiled body, and esi is not
// changed.
Emitter_ParticleBasis_00631670 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			outs := [3]Region{{ld(e + 0x4), 3}, {ld(e + 0x8), 3}, {e - 0x20, 15}}
			check(0x00631670, Emitter_ParticleBasis_00631670, guest_emitter_basis, outs[:])
			return
		}
		guest_emitter_basis()
		return
	}
	switch ld(c.ecx + EM_KIND) {
	case 5: basis_quat(e)
	case 4: basis_facing(e)
	case: basis_rotated(e, c.ecx)
	}
}

// Kind 5. Leaves the last four values in physical registers t+4 to t+7,
// empty.
@(private = "file")
basis_quat :: proc "contextless" (e: u32) #no_bounds_check {
	c := &x86.cpu
	f, p, R := e - 0x20, ld(e + 0xc), ld(e + 0x4)
	s := c.fpu.cw & x86.PC_MASK == 0
	one := lx(EM_ONE)
	x7 := lx(p + 0x40)
	x6 := lx(p + 0x3c)
	x5 := round_pc(s, x6 * x6)
	x4 := round_pc(s, x7 * x7)
	x5 = round_pc(s, x5 + x4)
	x5 = round_pc(s, x5 + x5)
	sx(f + 0x8, round_pc(s, one - x5))
	r0 := ld(f + 0x8)
	x7 = round_pc(s, lx(p + 0x3c) * lx(p + 0x38))
	x6 = round_pc(s, lx(p + 0x40) * lx(p + 0x34))
	x7 = round_pc(s, x7 + x6)
	sx(f + 0xc, round_pc(s, x7 + x7))
	x7 = round_pc(s, lx(p + 0x40) * lx(p + 0x38))
	x6 = round_pc(s, lx(p + 0x3c) * lx(p + 0x34))
	st(R, r0)
	st(R + 0x4, ld(f + 0xc))
	x7 = round_pc(s, x7 - x6)
	sx(f + 0x10, round_pc(s, x7 + x7))
	st(R + 0x8, ld(f + 0x10))
	x7 = round_pc(s, lx(p + 0x34) * lx(p + 0x3c))
	x6 = round_pc(s, lx(p + 0x38) * lx(p + 0x40))
	x7 = round_pc(s, x7 + x6)
	sx(f + 0x8, round_pc(s, x7 + x7))
	u0 := ld(f + 0x8)
	x7 = round_pc(s, lx(p + 0x40) * lx(p + 0x3c))
	x6 = round_pc(s, lx(p + 0x38) * lx(p + 0x34))
	x7 = round_pc(s, x7 - x6)
	sx(f + 0xc, round_pc(s, x7 + x7))
	u1 := ld(f + 0xc)
	U := ld(e + 0x8)
	x7 = lx(p + 0x3c)
	x6 = lx(p + 0x38)
	st(U, u0)
	x5 = round_pc(s, x7 * x7)
	st(U + 0x4, u1)
	x4 = round_pc(s, x6 * x6)
	x5 = round_pc(s, x5 + x4)
	x5 = round_pc(s, x5 + x5)
	x5 = round_pc(s, one - x5)
	sx(f + 0x10, x5)
	st(U + 0x8, ld(f + 0x10))
	t := c.fpu.top
	set_st_phys(t + 4, x4)
	set_st_phys(t + 5, x5)
	set_st_phys(t + 6, x6)
	set_st_phys(t + 7, x7)
	c.fpu.tag |= rot8(0xf0, t)
	c.esp = e + 0x1c
}

// Kind 4, with the guest's pushes and the three calls through call_guest.
@(private = "file")
basis_facing :: proc(e: u32) #no_bounds_check {
	c := &x86.cpu
	f := e - 0x20
	up, dir := ld(f + 0x28), ld(f + 0x30)
	st(f - 0x4, c.esi)
	for i in u32(0) ..< 3 {st(up + i * 4, ld(dir + i * 4))}
	st(f - 0x8, ld(f + 0x34))
	st(f - 0xc, up)
	st(f - 0x10, f + 0x8)
	st(f - 0x14, EM_RET_CROSS)
	c.esp = f - 0x14
	call_guest(EM_CROSS)
	sp := c.esp - 0x4
	st(sp, c.eax)
	st(sp - 0x4, sp + 0x28)
	st(sp - 0x8, EM_RET_NORMALIZE)
	c.eax, c.esp = sp + 0x28, sp - 0x8
	call_guest(EM_NORMALIZE)
	v, sp2 := c.eax, c.esp
	right := ld(sp2 + 0x3c)
	st(right, ld(v))
	st(right + 0x4, ld(v + 0x4))
	z := ld(v + 0x8)
	sp2 += 0x14
	st(right + 0x8, z)
	st(sp2 - 0x4, EM_RET_IS_ZERO)
	c.eax, c.ecx, c.esp = z, right, sp2 - 0x4
	call_guest(EM_IS_ZERO)
	if c.eax != 0 {
		for i in u32(0) ..< 3 {st(right + i * 4, ld(EM_UP + i * 4))}
	}
	c.esi = ld(c.esp)
	c.esp += 0x4 + 0x20 + 0x1c
}

// The other kinds. The guest pushes four values and pops them at the end, so
// relative to t = top + 4 it leaves the last seven in physical registers t to
// t+3 and t+5 to t+7, empty.
@(private = "file")
basis_rotated :: proc "contextless" (e, em: u32) #no_bounds_check {
	c := &x86.cpu
	f, p := e - 0x20, ld(e + 0xc)
	s := c.fpu.cw & x86.PC_MASK == 0
	one := lx(EM_ONE)
	q, ax := ld(f + 0x38), u32(0)
	own := (^u8)(rawptr(x86.MEM_BASE + uintptr(p + 0x68)))^ != 0 && ld(ld(em + 0x4) + 0x1e4) >> 9 & 1 != 0
	if own {
		q, ax = p + 0x34, p + 0x44
	}
	x7 := lx(q + 0xc)
	x6 := lx(q + 0x8)
	x5 := round_pc(s, x6 * x6)
	x4 := round_pc(s, x7 * x7)
	x5 = round_pc(s, x5 + x4)
	x5 = round_pc(s, x5 + x5)
	x3 := round_pc(s, one - x5)
	x6 = round_pc(s, lx(q + 0x8) * lx(q + 0x4))
	x5 = round_pc(s, lx(q + 0xc) * lx(q))
	x6 = round_pc(s, x6 + x5)
	x2 := round_pc(s, x6 + x6)
	x5 = round_pc(s, lx(q + 0xc) * lx(q + 0x4))
	x4 = round_pc(s, lx(q + 0x8) * lx(q))
	if !own {
		ax = ld(f + 0x34)
	}
	x1 := round_pc(s, x5 - x4)
	st(f + 0x34, ld(ax))
	R := ld(f + 0x24)
	x1 = round_pc(s, x1 + x1)
	x0 := round_pc(s, math.sin(lx(p + 0x20)))
	x7 = round_pc(s, math.cos(lx(p + 0x20)))
	sx(f + 0x2c, round_pc(s, one - x7))
	x7 = round_pc(s, lx(ax) * lx(ax + 0x4))
	x7 = round_pc(s, x7 * lx(f + 0x2c))
	x6 = round_pc(s, lx(f + 0x2c) * lx(ax))
	sx(f + 0x30, round_pc(s, x6 * lx(ax + 0x8)))
	x6 = round_pc(s, lx(f + 0x2c) * lx(ax + 0x4))
	sx(f + 0x4, round_pc(s, x6 * lx(ax + 0x8)))
	sx(f, round_pc(s, x0 * lx(ax)))
	sx(f + 0x38, round_pc(s, x0 * lx(ax + 0x4)))
	x7, x0 = x0, x7
	x7 = round_pc(s, x7 * lx(ax + 0x8))
	x6 = round_pc(s, lx(f + 0x34) * lx(f + 0x34))
	x6 = round_pc(s, x6 - one)
	x6 = round_pc(s, x6 * lx(f + 0x2c))
	x6 = round_pc(s, x6 + one)
	x6 = round_pc(s, x6 * x3)
	x5 = round_pc(s, x0 - x7)
	x5 = round_pc(s, x5 * x2)
	x6 = round_pc(s, x6 + x5)
	x5 = round_pc(s, lx(f + 0x38) + lx(f + 0x30))
	x5 = round_pc(s, x5 * x1)
	sx(R, round_pc(s, x6 + x5))
	st(f + 0x24, ld(ax + 0x4))
	x6 = round_pc(s, lx(f + 0x24) * lx(f + 0x24))
	x6 = round_pc(s, x6 - one)
	x6 = round_pc(s, x6 * lx(f + 0x2c))
	x6 = round_pc(s, x6 + one)
	x6 = round_pc(s, x6 * x2)
	x5 = round_pc(s, lx(f + 0x4) - lx(f))
	x5 = round_pc(s, x5 * x1)
	x6, x7 = x7, round_pc(s, x6 + x5)
	x6 = round_pc(s, x6 + x0)
	x6 = round_pc(s, x6 * x3)
	x7 = round_pc(s, x7 + x6)
	sx(R + 0x4, x7)
	x0 = lx(ax + 0x8)
	x7 = round_pc(s, x0 * x0)
	x7 = round_pc(s, x7 - one)
	x7 = round_pc(s, x7 * lx(f + 0x2c))
	x7 = round_pc(s, x7 + one)
	x7 = round_pc(s, x7 * x1)
	x6 = lx(f + 0x30)
	U := ld(f + 0x28)
	x6 = round_pc(s, x6 - lx(f + 0x38))
	x6 = round_pc(s, x6 * x3)
	x7 = round_pc(s, x7 + x6)
	x6 = round_pc(s, lx(f) + lx(f + 0x4))
	x6 = round_pc(s, x6 * x2)
	x7 = round_pc(s, x7 + x6)
	x3 = x7
	sx(R + 0x8, x3)
	x3 = round_pc(s, x3 * lx(ax + 0x4))
	x2 = round_pc(s, lx(R + 0x4) * lx(ax + 0x8))
	sx(U, round_pc(s, x3 - x2))
	x3 = round_pc(s, lx(R) * lx(ax + 0x8))
	x2 = round_pc(s, lx(ax) * lx(R + 0x8))
	sx(U + 0x4, round_pc(s, x3 - x2))
	x3 = round_pc(s, lx(ax) * lx(R + 0x4))
	x2 = round_pc(s, lx(R) * lx(ax + 0x4))
	x3 = round_pc(s, x3 - x2)
	sx(U + 0x8, x3)
	t := c.fpu.top + 4
	set_st_phys(t, x0)
	set_st_phys(t + 1, x1)
	set_st_phys(t + 2, x2)
	set_st_phys(t + 3, x3)
	set_st_phys(t + 5, x5)
	set_st_phys(t + 6, x6)
	set_st_phys(t + 7, x7)
	c.fpu.tag |= rot8(0xef, t)
	c.esp = e + 0x1c
}
