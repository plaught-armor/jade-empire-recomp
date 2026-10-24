// SkinMesh_Render (0x62cb90), its bone loop (0x62d181 to 0x62d6aa) as a
// native span: each bone's skinning matrix rows into the shader-constant
// table. WHY: docs/recompiler.md §8
package native

import "../x86"

SKIN_QUATS :: 0x007ed7b8 // ^array object: [obj] -> bone rotations, 16 bytes each
SKIN_POSES :: 0x007ed7b4 // ^array object: [obj] -> bone positions, 12 bytes each
SKIN_ROWS :: 0x007ed7e0 // 3 rows of 4 f32 per slot
SKIN_WIDE :: 0x0075f421 // byte: 0x30 slots when set, else 0x11 (0x63e4d0)
SKIN_ROWS_MAX :: 0x30 * 3 * 4 // dwords
SKIN_FRAME :: 0x140 // bytes of the frame above esp the stretch writes
// Compared at the exit: ebx esp ebp esi edi; eax, ecx and edx are written
// before they are read after it.
SKIN_LIVE :: 0xf8

// Entered with esp at the frame base s (16-aligned, the prologue's pushes
// done), ebx the mesh and ebp the frame pointer. Inputs: the rotation Q
// (w x y z) at [s + 0x10] and the translation A at [s + 0x90] that the
// parent walk before the span leaves (conjugates composed). For each of
// the u32[mesh + 0x138] bones i with slot sx16[[mesh + 0x134] + 2i] not -1:
// q = rotation i, v = rotate(q, bind pose [[mesh + 0x148] + 12i]) + position
// i, P = rotate(Q, v) + A, r = inverse bind [[mesh + 0x13c] + 16i] times q,
// t = Q r, m = Quat_ToMatrix3(t), and the rows (m0 m3 m6 Px), (m1 m4 m7 Py),
// (m2 m5 m8 Pz) go to the slot 0x63e4d0 maps i to (clamped to [0, n - 1],
// times 3). A rotation copies when the rotation's w is exactly +-1. Every
// frame slot the guest writes is written with its value, Quat_ToMatrix3's
// thiscall and 0x63e4d0's cdecl (pushed below esp, dead) aside. Follows the
// f32 rule (native.odin) over the whole loop where it holds; elsewhere, or
// when a value is not finite, the exact path reruns the loop with the
// recompiled body's f64 operations, rewriting everything the f32 run wrote
// before reading it (the inputs Q and A lie below the rows' frame slots).
SkinMesh_Bones_0062d181_0062d6aa :: proc() -> bool {
	c := &x86.cpu
	s := c.esp
	if mode == .Check {
		return span_check(0x0062d6aa, SkinMesh_Bones_0062d181_0062d6aa, {{s, SKIN_FRAME / 4}, {SKIN_ROWS, SKIN_ROWS_MAX}}, SKIN_LIVE)
	}
	mesh := c.ebx
	n := ld(mesh + 0x138)
	st(s + 0x68, 0)
	c.eax, c.edi = 0, 0
	if i32(n) <= 0 {
		return true
	}
	csr := csr_get()
	r: Bones_Out
	ok := false
	if f32_state(csr) {
		f32_begin(csr)
		r = skin_bones(true, s, mesh, n, f32)
		ok = f32_end(csr) && r.finite
	}
	if !ok {
		r = skin_bones(c.fpu.cw & x86.PC_MASK == 0, s, mesh, n, f64)
	}
	st(s + 0xc, n * 16)
	st(s + 0x60, n * 12)
	st(s + 0x68, n)
	c.eax, c.edx = n, n * 12
	c.ecx = r.ecx
	if r.done {
		c.esi = ld(c.ebp + 8)
		c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | r.sw
		c.xmm[0].f = r.row2
		c.fpu.tag |= rot8(0xff, c.fpu.top) // Quat_ToMatrix3 empties all eight
	}
	return true
}

@(private = "file")
Bones_Out :: struct {
	finite: bool,
	done:   bool, // a bone was not skipped
	ecx:    u32, // the last bone's slot, or its first row's address
	sw:     u16, // the status bits of the last compare of Q's w
	row2:   [4]f32, // the last row stored, xmm0
}

@(private)
Rot_Temps :: struct {
	t38, t3c, t40, t6c: f32,
}

// rotate(q, v) = v + 2 (cross terms), in the guest's order. The bone
// rotation's x sum adds its third term before subtracting the second; Q's
// (late) subtracts first. The temporaries are the four products the guest
// spills, in its slots for each. Under f64 (an exact path, s the precision
// control) the spilled products pass through an f32 and the result is not
// narrowed: the guest stores x and y, and z where its caller does.
@(private)
skin_rot :: #force_inline proc "contextless" (s: bool, q: [4]$T, v: [3]T, late: bool) -> (r: [3]T, t: Rot_Temps) {
	w, x, y, z := q[0], q[1], q[2], q[3]
	xx, yy, zz := xmul(s, x, x), xmul(s, y, y), xmul(s, z, z)
	yx, zw := xmul(s, y, x), xmul(s, z, w)
	zx, xw := xspill(xmul(s, z, x)), xspill(xmul(s, x, w))
	zy, yw := xspill(xmul(s, z, y)), xspill(xmul(s, y, w))
	a: T
	if late {
		a = xsub(s, xmul(s, xsub(s, yx, zw), v[1]), xmul(s, xadd(s, zz, yy), v[0]))
		a = xadd(s, a, xmul(s, xadd(s, yw, zx), v[2]))
	} else {
		a = xadd(s, xmul(s, xsub(s, yx, zw), v[1]), xmul(s, xadd(s, yw, zx), v[2]))
		a = xsub(s, a, xmul(s, xadd(s, zz, yy), v[0]))
	}
	r[0] = xadd(s, xadd(s, a, a), v[0])
	b := xsub(s, xmul(s, xsub(s, zy, xw), v[2]), xmul(s, xadd(s, zz, xx), v[1]))
	b = xadd(s, b, xmul(s, xadd(s, zw, yx), v[0]))
	r[1] = xadd(s, xadd(s, b, b), v[1])
	d := xsub(s, xmul(s, xadd(s, zy, xw), v[1]), xmul(s, xadd(s, yy, xx), v[2]))
	d = xadd(s, d, xmul(s, xsub(s, zx, yw), v[0]))
	r[2] = xadd(s, xadd(s, d, d), v[2])
	t = late ? {t38 = f32(zx), t3c = f32(yw), t40 = f32(xw), t6c = f32(zy)} : {t38 = f32(xw), t3c = f32(zx), t40 = f32(zy), t6c = f32(yw)}
	return
}

@(private = "file")
skin_temps :: #force_inline proc "contextless" (s: u32, t: Rot_Temps) {
	sf(s + 0x38, t.t38)
	sf(s + 0x3c, t.t3c)
	sf(s + 0x40, t.t40)
	sf(s + 0x6c, t.t6c)
}

@(private)
lq :: #force_inline proc "contextless" (a: u32) -> [4]f32 {return {lf(a), lf(a + 4), lf(a + 8), lf(a + 12)}}

@(private)
lv :: #force_inline proc "contextless" (a: u32) -> [3]f32 {return {lf(a), lf(a + 4), lf(a + 8)}}

@(private)
// The separate-module build calls the runtime for every checked index, even
// a constant one, so the hot helpers drop the check where the index is bounded.
sv :: #force_inline proc "contextless" (a: u32, v: [$N]f32) #no_bounds_check {
	for i in 0 ..< N {sf(a + u32(i) * 4, v[i])}
}

@(private)
unit_w :: #force_inline proc "contextless" (w: u32) -> bool {return w == 0x3f800000 || w == 0xbf800000}

// The loop in the guest's order, as the f32 rule's f32 operations (out of
// line so none moves across the MXCSR accesses around it) or the recompiled
// body's f64 ones under precision control s: a rotated vector's x and y pass
// through their frame slots, its z stays in a register, and the guest's
// integer copies keep their bits.
@(private = "file")
skin_bones :: #force_no_inline proc "contextless" (s: bool, f, mesh, n: u32, $T: typeid) -> (out: Bones_Out) #no_bounds_check {
	lqt :: #force_inline proc "contextless" (a: u32, $T: typeid) -> [4]T {return {xl(a, T), xl(a + 4, T), xl(a + 8, T), xl(a + 12, T)}}
	lvt :: #force_inline proc "contextless" (a: u32, $T: typeid) -> [3]T {return {xl(a, T), xl(a + 4, T), xl(a + 8, T)}}
	svt :: #force_inline proc "contextless" (a: u32, v: [$N]$T) #no_bounds_check {
		for i in 0 ..< N {sf(a + u32(i) * 4, f32(v[i]))}
	}
	copy3 :: #force_inline proc "contextless" (to, from: u32) {
		for k in u32(0) ..< 3 {st(to + k * 4, ld(from + k * 4))}
	}
	quats, poses := ld(ld(SKIN_QUATS)), ld(ld(SKIN_POSES))
	slots, binds, invs := ld(mesh + 0x134), ld(mesh + 0x148), ld(mesh + 0x13c)
	nslot := u32((^u8)(rawptr(x86.MEM_BASE + uintptr(SKIN_WIDE)))^ != 0 ? 0x30 : 0x11)
	Q := lqt(f + 0x10, T)
	A := lvt(f + 0x90, T)
	q_unit := Q[0] == 1 || Q[0] == -1
	q_sw := fcom_bits(Q[0], T(1)) == C3 ? C3 : fcom_bits(Q[0], T(-1))
	bad := false
	for i in u32(0) ..< n {
		slot := u32(i32((^i16)(rawptr(x86.MEM_BASE + uintptr(slots + i * 2)))^))
		st(f + 0xac, slot)
		out.ecx = slot
		if slot == 0xffffffff {
			continue
		}
		qa, b := quats + i * 16, binds + i * 12
		q := lqt(qa, T)
		v: [3]T
		if unit_w(ld(qa)) {
			copy3(f + 0x50, b)
			v = lvt(f + 0x50, T)
		} else {
			t: Rot_Temps
			v, t = skin_rot(s, q, lvt(b, T), false)
			skin_temps(f, t)
			sf(f + 0x50, f32(v[0]))
			sf(f + 0x54, f32(v[1]))
			v[0], v[1] = xspill(v[0]), xspill(v[1])
		}
		p := lvt(poses + i * 12, T)
		v = {xspill(xadd(s, v[0], p[0])), xspill(xadd(s, v[1], p[1])), xspill(xadd(s, v[2], p[2]))}
		svt(f + 0x44, v)
		if q_unit {
			copy3(f + 0x2c, f + 0x44)
		} else {
			t: Rot_Temps
			v, t = skin_rot(s, Q, v, true)
			skin_temps(f, t)
			sf(f + 0x2c, f32(v[0]))
			sf(f + 0x30, f32(v[1]))
			v[0], v[1] = xspill(v[0]), xspill(v[1])
		}
		P := [3]T{xspill(xadd(s, v[0], A[0])), xspill(xadd(s, v[1], A[1])), xspill(xadd(s, v[2], A[2]))}
		svt(f + 0x70, P)
		iq := lqt(invs + i * 16, T)
		q = lqt(qa, T)
		r := [4]T {
			xsub(s, xsub(s, xsub(s, xmul(s, iq[0], q[0]), xmul(s, iq[1], q[1])), xmul(s, iq[2], q[2])), xmul(s, iq[3], q[3])),
			xsub(s, xadd(s, xadd(s, xmul(s, iq[0], q[1]), xmul(s, iq[3], q[2])), xmul(s, iq[1], q[0])), xmul(s, iq[2], q[3])),
			xadd(s, xadd(s, xsub(s, xmul(s, iq[2], q[0]), xmul(s, iq[3], q[1])), xmul(s, iq[0], q[2])), xmul(s, iq[1], q[3])),
			xadd(s, xsub(s, xadd(s, xmul(s, iq[2], q[1]), xmul(s, iq[3], q[0])), xmul(s, iq[1], q[2])), xmul(s, iq[0], q[3])),
		}
		tq := [4]T {
			xsub(s, xsub(s, xsub(s, xmul(s, r[0], Q[0]), xmul(s, r[1], Q[1])), xmul(s, r[2], Q[2])), xmul(s, r[3], Q[3])),
			xsub(s, xadd(s, xadd(s, xmul(s, r[0], Q[1]), xmul(s, Q[0], r[1])), xmul(s, r[3], Q[2])), xmul(s, r[2], Q[3])),
			xadd(s, xadd(s, xsub(s, xmul(s, Q[0], r[2]), xmul(s, r[3], Q[1])), xmul(s, r[0], Q[2])), xmul(s, r[1], Q[3])),
			xadd(s, xsub(s, xadd(s, xmul(s, Q[0], r[3]), xmul(s, r[2], Q[1])), xmul(s, r[1], Q[2])), xmul(s, r[0], Q[3])),
		}
		svt(f + 0xb0, tq)
		quat_matrix(s, f + 0xb0, f + 0x11c, T)
		m: [9]f32
		for k in u32(0) ..< 9 {
			m[k] = lf(f + 0x11c + k * 4)
			sf(f + 0xe8 + k * 4, m[k])
		}
		row := min(i32(slot), i32(nslot) - 1)
		row = max(row, 0) * 3
		Pf := [3]f32{lf(f + 0x70), lf(f + 0x74), lf(f + 0x78)}
		rows := [3][4]f32{{m[0], m[3], m[6], Pf[0]}, {m[1], m[4], m[7], Pf[1]}, {m[2], m[5], m[8], Pf[2]}}
		sv(f + 0xc0, rows[0])
		sv(f + 0xd0, rows[1])
		sv(f + 0x80, rows[2])
		at := SKIN_ROWS + u32(row) * 16
		for k in u32(0) ..< 3 {
			sv(at + k * 16, rows[k])
			for e in rows[k] {bad |= transmute(u32)e & F32_EXP == F32_EXP}
		}
		out.ecx = at
		out.done = true
		out.row2 = rows[2]
	}
	out.finite = !bad
	out.sw = q_sw
	return
}
