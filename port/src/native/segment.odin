// Segment_SphereTest (0x5c2690): whether segment a-b, with unit direction d,
// passes within r1 + r2 of point c. WHY: docs/recompiler.md §8
package native

import "../x86"

guest_segment_sphere: x86.Func

// The t compared against before the closest point leaves a (0.0).
SEG_T_MIN :: 0x006e1848

// cdecl(a, b, d: ^[3]f32, r1: f32, c: ^[3]f32, r2: f32) -> eax 0 or 1. The
// closest point to c is a when t = (c - a)·d is below SEG_T_MIN, b when the
// projection t d is longer than b - a, else a + t d; eax = 1 unless (r1 + r2)²
// is less than its squared distance to c. edx keeps one dword of the guest's
// copy of that point: a.x for a, z otherwise. The recompiled body drops the
// ecx write. With finite inputs the f32 rule (native.odin) runs first; else,
// or when it fails, every operation is the recompiled body's (f64, rounded
// under single precision control as round_pc rounds, in its operand order,
// the projection and the closest point passing through their f32 frame
// slots), so any precision control and value give its bits. The six registers the last
// stretch used are left empty holding its values; the frame is dead.
Segment_SphereTest_005c2690 :: proc() {
	c := &x86.cpu
	if mode != .On {
		if mode == .Check {
			check(0x005c2690, Segment_SphereTest_005c2690, guest_segment_sphere, {})
			return
		}
		guest_segment_sphere()
		return
	}
	e := c.esp
	a, b, d, ce := ld(e + 0x4), ld(e + 0x8), ld(e + 0xc), ld(e + 0x14)
	csr := csr_get()
	r: Sphere_Out
	ok := false
	if f32_state(csr) && finite(a, 3) && finite(b, 3) && finite(d, 3) && finite(e + 0x10, 1) && finite(ce, 3) && finite(e + 0x18, 1) {
		f32_begin(csr)
		r = segment_sphere_test(e, f32)
		ok = f32_end(csr)
	}
	if !ok {
		r = segment_sphere_test(e, f64)
	}
	segment_sphere_exit(r)
	c.esp = e + 4
}

@(private = "file")
Sphere_Out :: struct {
	hit, edx: u32,
	cmp:      u16, // the status bits of the last compare
	st:       [6]f64, // physical registers top + 2 to top + 7
}

@(private = "file")
segment_sphere_exit :: #force_inline proc "contextless" (r: Sphere_Out) #no_bounds_check {
	c := &x86.cpu
	f := &c.fpu
	tp := f.top
	for v, i in r.st {set_st_phys(tp + 2 + u32(i), v)}
	f.tag |= rot8(0xfc, tp)
	f.sw = f.sw &~ (C0 | C2 | C3) | r.cmp
	c.eax = r.hit
	c.edx = r.edx
}

// The f32 rule's f32 operations under the MXCSR bracket, or the recompiled
// body's f64 ones under the control word's precision.
@(private = "file")
segment_sphere_test :: #force_no_inline proc "contextless" (e: u32, $T: typeid) -> Sphere_Out {
	s := T == f32 || x86.cpu.fpu.cw & x86.PC_MASK == 0
	ce := ld(e + 0x14)
	return segment_sphere_body(s, ld(e + 0x4), ld(e + 0x8), ld(e + 0xc), xl(e + 0x10, T), {xl(ce, T), xl(ce + 4, T), xl(ce + 8, T)}, xl(e + 0x18, T))
}

// Shared with Segment_SphereHit, which passes its midpoint as c.
@(private = "file")
segment_sphere_body :: #force_inline proc "contextless" (s: bool, a, b, d: u32, r1: $T, ce: [3]T, r2: T) -> (r: Sphere_Out) {
	A := [3]T{xl(a, T), xl(a + 4, T), xl(a + 8, T)}
	ab := [3]T{xsub(s, xl(b, T), A.x), xsub(s, xl(b + 4, T), A.y), xsub(s, xl(b + 8, T), A.z)}
	ac := [3]T{xsub(s, ce.x, A.x), xsub(s, ce.y, A.y), xsub(s, ce.z, A.z)}
	D := [3]T{xl(d, T), xl(d + 4, T), xl(d + 8, T)}
	t := xadd(s, xadd(s, xmul(s, ac.z, D.z), xmul(s, ac.y, D.y)), xmul(s, ac.x, D.x))
	p := [3]T{xspill(xmul(s, t, D.x)), xspill(xmul(s, t, D.y)), xspill(xmul(s, t, D.z))}
	k: [3]T
	if fcom_bits(t, xl(SEG_T_MIN, T)) == C0 {
		k = A
		r.edx = ld(a)
	} else {
		l := xadd(s, xadd(s, xmul(s, p.z, p.z), xmul(s, p.y, p.y)), xmul(s, p.x, p.x))
		ab2 := xadd(s, xadd(s, xmul(s, ab.z, ab.z), xmul(s, ab.y, ab.y)), xmul(s, ab.x, ab.x))
		if fcom_bits(ab2, l) == C0 {
			k = {xl(b, T), xl(b + 4, T), xl(b + 8, T)}
			r.edx = ld(b + 8)
		} else {
			k = {xspill(xadd(s, p.x, A.x)), xspill(xadd(s, p.y, A.y)), xspill(xadd(s, p.z, A.z))}
			r.edx = transmute(u32)f32(k.z)
		}
	}
	q := [3]T{xsub(s, k.x, ce.x), xsub(s, k.y, ce.y), xsub(s, k.z, ce.z)}
	rr := xadd(s, r1, r2)
	dist := xadd(s, xadd(s, xmul(s, q.z, q.z), xmul(s, q.y, q.y)), xmul(s, q.x, q.x))
	r2 := xmul(s, rr, rr)
	r.cmp = fcom_bits(r2, dist)
	r.hit = r.cmp == C0 ? 0 : 1
	r.st = {f64(r2), f64(dist), f64(rr), f64(q.z), f64(q.y), f64(q.x)}
	return
}

guest_segment_aabb_clip: x86.Func

// The 1.0 the clip parameter is subtracted from.
SEG_ONE :: 0x006e1910

// cdecl(a, b, lo, hi: ^[3]f32) -> eax: the face of box lo-hi where segment
// a-b enters it, 1-6 for x min, x max, y min, y max, z min, z max; 0 when it
// misses, -1 when a is inside. Built on Aabb_Outcode, which leaves edx at its
// out byte and ecx at its point, then ecx's low byte becomes a's outcode.
// Per axis pair, the face a is outside of is tried: its plane's t along a-b
// and the other two coordinates there, (1 - t) a + t b, which must lie in
// [lo, hi]. Every operation is the recompiled body's, as in
// Segment_SphereTest; the frame is dead.
Segment_AabbClip_005c2320 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005c2320, Segment_AabbClip_005c2320, guest_segment_aabb_clip, {})
			return
		}
		guest_segment_aabb_clip()
		return
	}
	r := segment_aabb_clip(c.fpu.cw & x86.PC_MASK == 0, e)
	c.fpu.sw = c.fpu.sw &~ (C0 | C2 | C3) | r.cmp
	c.eax, c.ecx, c.edx = r.eax, r.ecx, r.edx
	c.esp = e + 4
}

@(private = "file")
Clip_Out :: struct {
	eax, ecx, edx: u32,
	cmp:           u16,
}

// A face: the axis its plane is across, that plane's address, and the two
// other coordinates in the order computed. x and y faces store both and
// compare the stored u then v; z faces (late) store u only and compare the
// unstored v first.
@(private = "file")
Clip_Face :: struct {
	axis, plane: u32,
	u, v:        u32,
	late:        bool,
}

@(private = "file")
segment_aabb_clip :: proc "contextless" (s: bool, e: u32) -> (r: Clip_Out) #no_bounds_check {
	a, b, lo, hi := ld(e + 0x4), ld(e + 0x8), ld(e + 0xc), ld(e + 0x10)
	f := &x86.cpu.fpu
	tp := f.top
	// Each Aabb_Outcode leaves its fld's register empty, holding the point's z.
	ca, cmp_a, _ := outcode(a, lo, hi)
	set_st_phys(tp + 7, lx(a + 8))
	f.tag |= rot8(0x80, tp)
	if ca == 0 {
		return {0xffffffff, a, e - 0xa, cmp_a}
	}
	cb, cmp_b, _ := outcode(b, lo, hi)
	set_st_phys(tp + 7, lx(b + 8))
	r = {0, b &~ 0xff | u32(ca), e - 0x9, cmp_b}
	if ca & cb != 0 {return}
	faces := [6]Clip_Face{
		{0, lo, 1, 2, false}, {0, hi, 1, 2, false},
		{1, lo + 4, 0, 2, false}, {1, hi + 4, 0, 2, false},
		{2, lo + 8, 0, 1, true}, {2, hi + 8, 0, 1, true},
	}
	for pair in u32(0) ..< 3 {
		i := pair * 2
		if ca & OUTCODE_BITS[pair][0] == 0 {
			if ca & OUTCODE_BITS[pair][1] == 0 {continue}
			i += 1
		}
		hit: bool
		hit, r.cmp = clip_face(s, a, b, lo, hi, faces[i], tp)
		if hit {
			r.eax = i + 1
			return
		}
	}
	return
}

// The face's four registers are left empty: t b_u, w_u, t b_v and the last
// value compared.
@(private = "file")
clip_face :: #force_inline proc "contextless" (s: bool, a, b, lo, hi: u32, f: Clip_Face, tp: u32) -> (hit: bool, cmp: u16) #no_bounds_check {
	ak := lx(a + f.axis * 4)
	t := round_pc(s, xsub(s, lx(f.plane), ak) / xsub(s, lx(b + f.axis * 4), ak))
	k := xsub(s, lx(SEG_ONE), t)
	qu := xmul(s, t, lx(b + f.u * 4))
	wu := xadd(s, xmul(s, k, lx(a + f.u * 4)), qu)
	qv := xmul(s, t, lx(b + f.v * 4))
	wv := xadd(s, xmul(s, k, lx(a + f.v * 4)), qv)
	set_st_phys(tp + 4, qu)
	set_st_phys(tp + 5, wu)
	set_st_phys(tp + 6, qv)
	x86.cpu.fpu.tag |= rot8(0xf0, tp)
	vals := f.late ? [2]f64{wv, xspill(wu)} : [2]f64{xspill(wu), xspill(wv)}
	axes := f.late ? [2]u32{f.v, f.u} : [2]u32{f.u, f.v}
	for j in 0 ..< 2 {
		w := vals[j]
		set_st_phys(tp + 7, w)
		cmp = fcom_bits(w, lx(lo + axes[j] * 4))
		if cmp & C0 != 0 {return}
		cmp = fcom_bits(w, lx(hi + axes[j] * 4))
		if cmp != C0 && cmp != C3 {return}
	}
	return true, cmp
}

guest_segment_sphere_hit: x86.Func

// The 0.5 the length is scaled by.
SEG_HALF :: 0x006e1914

// cdecl(a, b, d: ^[3]f32, r1: f32, p, q: ^[3]f32) -> eax 0 or 1:
// Segment_SphereTest(a, b, d, r1, (p + q) / 2, |q - p| / 2). |q - p| comes
// from Math_SqrtNewton of the squared length ((z² + x²) + y²), the midpoint
// from the guest's Vec3 divide by 2.0 (0x4185c0: a multiply by 1 / 2.0). The
// radius is stored over q's argument slot. ecx is left at the stack buffer
// holding the midpoint, edx as Segment_SphereTest leaves it, and the x87
// stack empty with Segment_SphereTest's registers and compare bits. The f32
// rule and the exact path are Segment_SphereTest's (Math_SqrtNewton's steps
// f64 in both, as its own native runs them); the frame below the arguments
// is dead.
Segment_SphereHit_005c55c0 :: proc() {
	c := &x86.cpu
	e := c.esp
	if mode != .On {
		if mode == .Check {
			check(0x005c55c0, Segment_SphereHit_005c55c0, guest_segment_sphere_hit, {{e + 0x18, 1}})
			return
		}
		guest_segment_sphere_hit()
		return
	}
	csr := csr_get()
	r: Sphere_Out
	rad: f32
	ok := false
	if f32_state(csr) && finite(ld(e + 0x4), 3) && finite(ld(e + 0x8), 3) && finite(ld(e + 0xc), 3) &&
	   finite(e + 0x10, 1) && finite(ld(e + 0x14), 3) && finite(ld(e + 0x18), 3) {
		f32_begin(csr)
		r, rad = segment_sphere_hit(e, f32)
		ok = f32_end(csr)
	}
	if !ok {
		r, rad = segment_sphere_hit(e, f64)
	}
	sf(e + 0x18, rad)
	segment_sphere_exit(r)
	c.ecx = e - 0xc
	c.esp = e + 4
}

@(private = "file")
segment_sphere_hit :: #force_no_inline proc "contextless" (e: u32, $T: typeid) -> (r: Sphere_Out, radius: f32) {
	s := T == f32 || x86.cpu.fpu.cw & x86.PC_MASK == 0
	p, q := ld(e + 0x14), ld(e + 0x18)
	d := [3]T{xsub(s, xl(q, T), xl(p, T)), xsub(s, xl(q + 4, T), xl(p + 4, T)), xsub(s, xl(q + 8, T), xl(p + 8, T))}
	l2 := f64(xadd(s, xadd(s, xmul(s, d.z, d.z), xmul(s, d.x, d.x)), xmul(s, d.y, d.y)))
	x := transmute(u64)l2
	yhi := (SQRT_MAGIC - u32(x >> 32)) >> 1
	_, _, _, l := sqrt_newton(s, l2, transmute(f64)(u64(yhi) << 32 | x & 0xffffffff))
	rad := xspill(xmul(s, T(l), xl(SEG_HALF, T)))
	sum := [3]T{xspill(xadd(s, xl(p, T), xl(q, T))), xspill(xadd(s, xl(q + 4, T), xl(p + 4, T))), xspill(xadd(s, xl(p + 8, T), xl(q + 8, T)))}
	inv: T
	when T == f32 {inv = xl(SEG_ONE, T) / 2} else {inv = round_pc(s, lx(SEG_ONE) / 2)}
	m := [3]T{xspill(xmul(s, xspill(inv), sum.x)), xspill(xmul(s, xspill(inv), sum.y)), xspill(xmul(s, inv, sum.z))}
	r = segment_sphere_body(s, ld(e + 0x4), ld(e + 0x8), ld(e + 0xc), xl(e + 0x10, T), m, rad)
	return r, f32(rad)
}
