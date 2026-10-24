// Quat_ToMatrix3 (0x40eba0): the 3x3 rotation matrix of a unit quaternion.
// WHY: docs/recompiler.md §8
package native

import "core:math"
import "../x86"

guest_quat_matrix: x86.Func

// __thiscall(q = ecx: ^[4]f32 (w x y z), m: ^[9]f32), ret 4. The guest loads
// m[1]'s bits into ecx, but the recompiled body drops that write as dead
// (docs/recompiler.md §2, liveness-narrowed syncs), so ecx stays q. With m
// apart from q the f32 rule (native.odin) runs first; else, or when it fails,
// every operation is the recompiled body's: f64, rounded under single
// precision control as round_pc rounds, in its operand order, each product
// through its f32 stack temporary where the guest reloads it, so any
// precision control, register state and value give its bits. The eight registers end empty and
// are not written (cpu_matches), nor are the dead temporaries below esp.
Quat_ToMatrix3_0040eba0 :: proc() {
	c := &x86.cpu
	q := c.ecx
	m := ld(c.esp + 4)
	if mode != .On {
		if mode == .Check {
			check(0x0040eba0, Quat_ToMatrix3_0040eba0, guest_quat_matrix, {{m, 9}})
			return
		}
		guest_quat_matrix()
		return
	}
	csr := csr_get()
	ok := false
	if f32_state(csr) && apart(q, 16, m, 36) {
		f32_begin(csr)
		quat_matrix(true, q, m, f32)
		ok = f32_end(csr) && finite(m, 9)
	}
	if !ok {
		quat_matrix(c.fpu.cw & x86.PC_MASK == 0, q, m, f64)
	}
	c.fpu.tag |= rot8(0xff, c.fpu.top)
	c.eax = m
	c.esp += 8
}

// The guest's matrix in its order, as the f32 rule's f32 operations (an f32
// span's MXCSR bracket around the caller) or the recompiled body's f64 ones
// under precision control s. All of q is read before m is written.
@(private)
quat_matrix :: #force_no_inline proc "contextless" (s: bool, q, m: u32, $T: typeid) {
	w, x, y, z := xl(q, T), xl(q + 4, T), xl(q + 8, T), xl(q + 12, T)
	one := xl(QUAT_ONE, T)
	yy := xspill(xmul(s, y, y))
	xx := xspill(xmul(s, x, x))
	a := xsub(s, one, xdbl(s, xadd(s, xx, yy)))
	zy := xspill(xmul(s, z, y))
	wx := xspill(xmul(s, w, x))
	b := xdbl(s, xsub(s, zy, wx))
	zx := xspill(xmul(s, z, x))
	// The guest adds w y before its stored copy is reloaded.
	wy_full := xmul(s, w, y)
	wy := xspill(wy_full)
	cc := xdbl(s, xadd(s, wy_full, zx))
	d := xdbl(s, xadd(s, wx, zy))
	zz := xspill(xmul(s, z, z))
	e := xsub(s, one, xdbl(s, xadd(s, zz, xx)))
	yx := xspill(xmul(s, y, x))
	wz := xspill(xmul(s, w, z))
	f := xdbl(s, xsub(s, yx, wz))
	g := xdbl(s, xsub(s, zx, wy))
	h := xdbl(s, xadd(s, wz, yx))
	i := xsub(s, one, xdbl(s, xadd(s, zz, yy)))
	sf(m, f32(i))
	sf(m + 4, f32(h))
	sf(m + 8, f32(g))
	sf(m + 12, f32(f))
	sf(m + 16, f32(e))
	sf(m + 20, f32(d))
	sf(m + 24, f32(cc))
	sf(m + 28, f32(b))
	sf(m + 32, f32(a))
}

guest_quat_slerp: x86.Func

// The dot product at or above which Quat_Slerp lerps (f64 1.0), the zero it
// tests the dot's sign against and the one of 1 - t (f32s), and the CRT acos
// it calls otherwise (_CIacos: st(0) in, st(0) out, under its own
// double-precision control word).
SLERP_LERP_DOT :: 0x006e3568
SLERP_ZERO :: 0x006e1848
SLERP_ONE :: 0x006e1910
SLERP_ACOS :: 0x006b34d0
SLERP_ACOS_RET :: 0x005c12b3
SLERP_NORM_RET :: 0x005c12a0

// cdecl(out: ^[4]f32, a: [4]f32 by value, b: ^[4]f32, t: f32) -> eax out.
// dot = ((a0 b0 + a1 b1) + a3 b3) + a2 b2 over b's pointer; a dot below 0.0
// negates a and dot in their argument slots. A dot at or above 1.0 lerps:
// Q = a (1 - t) + t b over a's slots, then Quat_Normalize(out, Q), whose ecx
// and edx stand. Otherwise θ = acos(dot) by the guest's CRT, r = 1 / sqrt(1 -
// dot²), sa = sin((1 - t) θ) r over the dot's slot, sb = r sin(θ t), out = sa
// a + sb b; ecx and edx as acos leaves them. Every operation is the recompiled
// body's: f64, rounded under single precision control as round_pc rounds, in
// its operand order, through an f32 wherever the guest spills, fsin as
// math.sin, so any precision control, register state and value give its bits.
// The registers it uses end empty and are not written (cpu_matches), nor are
// the dead stack temporaries below esp.
Quat_Slerp_005c1180 :: proc() #no_bounds_check {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005c1180, Quat_Slerp_005c1180, guest_quat_slerp, {{e + 0x8, 6}, {ld(e + 0x4), 4}})
			return
		}
		guest_quat_slerp()
		return
	}
	f := &c.fpu
	s := f.cw & x86.PC_MASK == 0
	t := f.top
	b := ld(e + 0x18)
	d := round_pc(s, lx(e + 0x8) * lx(b))
	d = round_pc(s, d + round_pc(s, lx(e + 0xc) * lx(b + 4)))
	d = round_pc(s, d + round_pc(s, lx(e + 0x14) * lx(b + 0xc)))
	d = round_pc(s, d + round_pc(s, lx(e + 0x10) * lx(b + 8)))
	neg := fcom_bits(d, lx(SLERP_ZERO)) == C0
	sx(e + 0x18, d)
	if neg {
		for o in ([4]u32{0xc, 0x10, 0x14, 0x8}) {sx(e + o, round_pc(s, -lx(e + o)))}
		d = round_pc(s, -d)
		sx(e + 0x18, d)
	}
	cmp := fcom_bits(d, lf64(SLERP_LERP_DOT))
	f.sw = f.sw &~ (C0 | C2 | C3) | cmp
	f.tag |= rot8(0xc0, t)
	if cmp & C0 == 0 {
		slerp_lerp(e, b, s)
		return
	}
	// The dot reloaded for acos; it pops it and pushes θ.
	set_st_phys(t + 7, lx(e + 0x18))
	f.tag &~= rot8(0x80, t)
	f.top = (t + 7) & 7
	esi := c.esi
	c.esi = b
	c.esp = e - 0x28
	st(c.esp, SLERP_ACOS_RET)
	call_guest(SLERP_ACOS)
	tt := f.top
	theta := st_phys(tt)
	s = f.cw & x86.PC_MASK == 0
	one := lx(SLERP_ONE)
	x := round_pc(s, lx(e + 0x18) * lx(e + 0x18))
	o := ld(e + 0x4)
	x = round_pc(s, math.sqrt(round_pc(s, one - x)))
	r := round_pc(s, one / x)
	sa := round_pc(s, round_pc(s, one - lx(e + 0x1c)) * theta)
	sa = round_pc(s, round_pc(s, x86.sin(sa)) * r)
	sx(e + 0x18, sa)
	x = round_pc(s, x86.sin(round_pc(s, theta * lx(e + 0x1c))))
	sb := round_pc(s, r * x)
	pb: [4]f64
	for i in u32(0) ..< 4 {pb[i] = round_pc(s, sb * lx(b + i * 4))}
	pa: [4]f64
	for i in u32(0) ..< 4 {pa[i] = round_pc(s, lx(e + 0x18) * lx(e + 0x8 + i * 4))}
	// The guest keeps sa a0 and sb b0 in registers and spills the rest.
	sx(o, round_pc(s, pa[0] + pb[0]))
	for i in u32(1) ..< 4 {sx(o + i * 4, round_pc(s, f64(f32(pa[i])) + f64(f32(pb[i]))))}
	f.tag |= rot8(0xc1, tt)
	f.top = (tt + 1) & 7
	c.eax = o
	c.esi = esi
	c.esp = e + 4
}

// The lerp: Q over a's slots and Quat_Normalize's arguments (out, Q) below
// them, as the guest pushes them, then the call. The guest spills t b2, t b3
// and (1 - t) a1..a3.
@(private = "file")
slerp_lerp :: proc(e, b: u32, s: bool) #no_bounds_check {
	c := &x86.cpu
	p: [4]f64
	for i in u32(0) ..< 4 {p[i] = round_pc(s, lx(e + 0x1c) * lx(b + i * 4))}
	p[2], p[3] = f64(f32(p[2])), f64(f32(p[3]))
	o := ld(e + 0x4)
	u := round_pc(s, lx(SLERP_ONE) - lx(e + 0x1c))
	a: [4]f64
	a[0] = round_pc(s, lx(e + 0x8) * u)
	for i in u32(1) ..< 4 {a[i] = f64(f32(round_pc(s, u * lx(e + 0x8 + i * 4))))}
	for i in u32(0) ..< 4 {
		sx(e + 0x8 + i * 4, round_pc(s, a[i] + p[i]))
		st(e - 0x34 + i * 4, ld(e + 0x8 + i * 4))
	}
	st(e - 0x38, o)
	st(e - 0x3c, SLERP_NORM_RET)
	c.fpu.tag |= rot8(0xf8, c.fpu.top)
	c.eax, c.ecx, c.edx, c.esp = e - 0x34, ld(e + 0x10), ld(e + 0x14), e - 0x3c
	if x86.probe_n > 0 {x86.call(0x005c10d0)} else {Quat_Normalize_005c10d0()}
	c.eax = o
	c.esp = e + 4
}

guest_quat_unpack: x86.Func

// The scales of the packed components: 21 bits, 21 bits and 22 bits.
QUAT_UNPACK_K21 :: 0x007074c8
QUAT_UNPACK_K22 :: 0x007074c4

// cdecl(out: ^[4]f32 (w x y z), lo: u32, hi: u32) -> eax out. x = (hi &
// 0x1fffff) K21 - 1, y = ((lo & 0x3ff) << 11 | hi >> 21) K21 - 1, z = (lo >>
// 10) K22 - 1, each through hi's argument slot, which keeps lo >> 10. With s
// = (z² + y²) + x² at most 1.0, w = sqrt(1 - s); above it or unordered, w = 0
// and x, y, z are scaled by 1 / sqrt(s). The recompiled body drops the ecx
// and edx writes. Every operation is the recompiled body's (quat_unpack_pack),
// so any precision control and value give its bits.
Quat_Unpack_005b6f50 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005b6f50, Quat_Unpack_005b6f50, guest_quat_unpack, {{ld(e + 0x4), 4}, {e + 0xc, 1}})
			return
		}
		guest_quat_unpack()
		return
	}
	lo, hi := ld(e + 0x8), ld(e + 0xc)
	st(e + 0xc, lo >> 10)
	k := lx(QUAT_UNPACK_K21)
	quat_unpack_pack(e, f64(hi & 0x1fffff) * k, f64((lo & 0x3ff) << 11 | hi >> 21) * k, f64(lo >> 10) * lx(QUAT_UNPACK_K22))
}

guest_quat_unpack32: x86.Func

// The scales of the 32-bit packing's components: 11 bits and 10 bits.
QUAT_UNPACK32_K11 :: 0x007074c0
QUAT_UNPACK32_K10 :: 0x007074bc

// cdecl(out: ^[4]f32 (w x y z), p: u32) -> eax out. x = (p & 0x7ff) K11 - 1,
// y = (p >> 11 & 0x7ff) K11 - 1, z = (p >> 22) K10 - 1, each through p's
// argument slot, which keeps p >> 22; w as for Quat_Unpack. The recompiled
// body drops the ecx and edx writes. Exact as Quat_Unpack.
Quat_Unpack32_005b6e60 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005b6e60, Quat_Unpack32_005b6e60, guest_quat_unpack32, {{ld(e + 0x4), 4}, {e + 0x8, 1}})
			return
		}
		guest_quat_unpack32()
		return
	}
	p := ld(e + 0x8)
	st(e + 0x8, p >> 22)
	k := lx(QUAT_UNPACK32_K11)
	quat_unpack_pack(e, f64(p & 0x7ff) * k, f64(p >> 11 & 0x7ff) * k, f64(p >> 22) * lx(QUAT_UNPACK32_K10))
}

// Both unpacks after their scaled integers (each product exact in f64, below
// 2^22 times an f32, but rounded under precision control as the guest's
// fmul): each component less 1.0 through its f32 frame slot, s against 1.0,
// and w. The x87 ends as it began, with the two registers it used empty (not
// written, cpu_matches), as is the frame below esp.
@(private = "file")
quat_unpack_pack :: proc(e: u32, kx, ky, kz: f64) {
	c := &x86.cpu
	s := c.fpu.cw & x86.PC_MASK == 0
	one := lx(QUAT_ONE)
	x := xspill(round_pc(s, round_pc(s, kx) - one))
	y := xspill(round_pc(s, round_pc(s, ky) - one))
	zf := round_pc(s, round_pc(s, kz) - one)
	z := xspill(zf)
	n := round_pc(s, round_pc(s, round_pc(s, zf * z) + round_pc(s, y * y)) + round_pc(s, x * x))
	cmp := fcom_bits(n, one)
	w: f64
	if cmp == C0 || cmp == C3 {
		w = round_pc(s, math.sqrt(round_pc(s, one - n)))
	} else {
		r := round_pc(s, one / round_pc(s, math.sqrt(n)))
		x, y, z = round_pc(s, x * r), round_pc(s, y * r), round_pc(s, r * z)
	}
	o := ld(e + 0x4)
	sx(o, w)
	sx(o + 4, x)
	sx(o + 8, y)
	sx(o + 12, z)
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | cmp
	c.fpu.tag |= rot8(0xc0, c.fpu.top)
	c.eax = o
	c.esp = e + 4
}

guest_quat_normalize: x86.Func

// The norm below which Quat_Normalize returns the identity (f64 1e-9), and
// the one it divides (f32).
QUAT_NORM_EPS :: 0x00708b68
QUAT_ONE :: 0x006e1910

// cdecl(out: ^[4]f32, q: [4]f32 by value) -> eax out. n = sqrt(((q3² + q2²)
// + q1²) + q0²); n below 1e-9, compared widened as the guest compares it with
// a double, stores the identity (1, 0, 0, 0) through q's argument slots to
// out, leaving ecx = out and edx = 0. Else r = 1 / n and out = (q0 r, q1 r,
// q2 r, r q3), ecx and edx kept. Every operation is the recompiled body's:
// f64, rounded under single precision control as round_pc rounds, in its
// operand order, each store after the loads before it, so any precision
// control, register state, value and overlap of out with q give its bits. The
// two registers it uses are left empty holding their last values.
Quat_Normalize_005c10d0 :: proc() #no_bounds_check {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005c10d0, Quat_Normalize_005c10d0, guest_quat_normalize, {{ld(e + 0x4), 4}, {e + 0x8, 4}})
			return
		}
		guest_quat_normalize()
		return
	}
	f := &c.fpu
	s := f.cw & x86.PC_MASK == 0
	t := f.top
	sq :: #force_inline proc "contextless" (s: bool, a: u32) -> f64 {v := lx(a); return round_pc(s, v * v)}
	n := round_pc(s, sq(s, e + 0x14) + sq(s, e + 0x10))
	n = round_pc(s, n + sq(s, e + 0xc))
	q0 := sq(s, e + 0x8)
	n = round_pc(s, math.sqrt(round_pc(s, n + q0)))
	cmp := fcom_bits(n, lf64(QUAT_NORM_EPS))
	f.sw = f.sw &~ (C0 | C2 | C3) | cmp
	f.tag |= rot8(0xc0, t)
	o := ld(e + 0x4)
	c.eax = o
	c.esp = e + 4
	if cmp == C0 {
		set_st_phys(t + 6, q0)
		set_st_phys(t + 7, n)
		for i in u32(0) ..< 4 {
			st(e + 0x8 + i * 4, i == 0 ? 0x3f800000 : 0)
			st(o + i * 4, ld(e + 0x8 + i * 4))
		}
		c.ecx, c.edx = o, 0
		return
	}
	r := round_pc(s, lx(QUAT_ONE) / n)
	v: f64
	for i in u32(0) ..< 3 {
		v = round_pc(s, lx(e + 0x8 + i * 4) * r)
		sx(o + i * 4, v)
	}
	r = round_pc(s, r * lx(e + 0x14))
	sx(o + 0xc, r)
	set_st_phys(t + 6, v)
	set_st_phys(t + 7, r)
}
